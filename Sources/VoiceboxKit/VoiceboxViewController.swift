import AVFoundation
import SystemConfiguration
import UIKit
import WebKit

/// UIKit view controller that hosts the Voicebox WebView.
///
/// Handles WebView lifecycle, close button, microphone permissions,
/// and offline fallback.
public final class VoiceboxViewController: UIViewController {

    private let voiceboxView: VoiceboxView
    private var webView: WKWebView!
    private var navigationDelegate: VoiceboxNavigationDelegate!
    private var closeButton: UIButton?
    /// Floating-card only: the transparent nav bar that hosts the close × as a real
    /// bar-button item, so the SYSTEM positions it at the app's standard trailing
    /// slot (see `installCloseButtonInNavBar`).
    private var closeNavBar: UINavigationBar?
    /// Floating-card only: the native view that holds the voicebox's background (colour
    /// and/or image) behind the WebView. The page's own background is stripped, so this
    /// is the ONLY background — it always covers during a keyboard resize (issue #246).
    private var backgroundRevealView: UIImageView?
    /// The WebView's bottom constraint, held so floating-card keyboard avoidance
    /// can shrink the card's viewport from the bottom (see `keyboardWillChangeFrame`).
    private var webViewBottomConstraint: NSLayoutConstraint?
    private var offlineView: VoiceboxOfflineView?
    private var skeletonView: VoiceboxSkeletonView!
    /// In `.floatingCard` mode the sheet shimmer (full-width bars + mic circle)
    /// reads as broken — its bars float over the transparent, centered card with
    /// the real content bleeding through. There we show a card-shaped skeleton
    /// (avatar badge + card placeholder) instead, matching where the card appears.
    private var cardSkeletonView: VoiceboxCardSkeletonView?
    private var isFloatingCard: Bool {
        if case .floatingCard = voiceboxView.presentationMode { return true }
        return false
    }
    /// The floating card's dim, so the skeleton's backdrop can match it.
    private var floatingCardDim: CGFloat {
        if case .floatingCard(let dim) = voiceboxView.presentationMode { return CGFloat(dim) }
        return 0
    }
    private var usedPreloadedWebView = false
    /// Adopted a warm that was still in flight for this exact URL, so `loadVoicebox()` must
    /// NOT issue a request — the one already running is the one we're waiting on.
    private var joinedInFlightWarm = false
    private var hasAppeared = false
    /// One-shot latch for `revealContent(documentURL:)` — DOM-ready and `didFinish` both call it.
    private var didReveal = false
    private var registeredContentHeightHandler = false
    /// Whether THIS controller currently holds a `VoiceboxScreenAwake` reference, so the
    /// acquire/release pair stays balanced across repeated appear/disappear cycles.
    private var isHoldingScreenAwake = false
    // Share the names with the baked-in user scripts (VoiceboxWebScripts) so a
    // warmed WebView's scripts post to the same handlers this controller registers.
    private static let contentHeightMessageName = VoiceboxWebScripts.contentHeightMessageName
    private static let voiceboxEventMessageName = VoiceboxWebScripts.eventMessageName
    private static let bgColorMessageName = VoiceboxWebScripts.bgColorMessageName
    private static let domReadyMessageName = VoiceboxWebScripts.domReadyMessageName

    /// Called on the main thread when JS detects the web page's background colour.
    /// The SwiftUI layer uses this to update `presentationBackground` dynamically
    /// so the home-indicator strip matches the page's actual colour.
    var onBackgroundColorDetected: ((UIColor) -> Void)?

    /// Fired once when this controller has finished disappearing (dismissed) —
    /// used by the SwiftUI `.floatingCard` presenter to sync its `isPresented`
    /// binding back to `false` when the card dismisses itself (tap-outside).
    var onDidDismissSelf: (() -> Void)?

    /// Creates a view controller for the given VoiceboxView.
    ///
    /// - Parameter voiceboxView: The configured VoiceboxView instance. Alternatively, use
    ///   ``VoiceboxView/presentAsSheet(from:)`` or ``VoiceboxView/presentFullScreen(from:)``
    ///   which create this controller automatically.
    public init(voiceboxView: VoiceboxView) {
        self.voiceboxView = voiceboxView
        super.init(nibName: nil, bundle: nil)
    }

    /// Convenience initializer using a VoiceboxView.
    ///
    /// - Parameter view: The configured VoiceboxView instance.
    public convenience init(view: VoiceboxView) {
        self.init(voiceboxView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VoiceboxViewController does not support Interface Builder.")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Start with systemBackground so the sheet looks clean before JS detection
        // fires. Once the page loads, applyWebBackgroundColor() overrides this
        // with the web page's actual background colour.
        // If the caller set an explicit backgroundColor, honour it.
        // Otherwise default to systemBackground — JS detection will override once the page loads.
        // Floating card: paint the dim NATIVELY behind the WebView (not via CSS,
        // which would overwrite the voicebox's configured background image). Where
        // the page has a background image, the opaque WebView covers this dim
        // (image shows full-brightness, matching Android); where the page is
        // transparent, this dim shows through. `dimOpacity: 0` ⇒ fully clear.
        if case .floatingCard = voiceboxView.presentationMode {
            view.backgroundColor = UIColor.black.withAlphaComponent(floatingCardDim)
        } else {
            view.backgroundColor = voiceboxView.theme.backgroundColor ?? .systemBackground
        }
        setupWebView()
        setupSkeletonView()
        // Close button last so it sits on top of the WebView and the loading
        // skeleton — in `.floatingCard` the skeleton covers the whole view, so a
        // close button added before it would be behind it (and untappable) while
        // the page loads.
        setupCloseButton()
        requestMicrophonePermission()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        // Keep the close control above the WebView no matter what — a floating card
        // over a full-screen background image must never bury its only dismiss
        // control behind late-added/re-ordered subviews.
        bringCloseControlToFront()
        acquireScreenAwakeIfNeeded()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Released here as well as in viewDidDisappear: this fires BEFORE the dismiss
        // animation, and is more dependable than viewDidDisappear when a
        // UIViewControllerRepresentable is torn down inside a SwiftUI .sheet. Guarded, so
        // whichever runs first wins and the rest are no-ops.
        releaseScreenAwakeIfNeeded()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        releaseScreenAwakeIfNeeded()
        if hasAppeared {
            voiceboxView.delegate?.voiceboxDidDismiss(voiceboxView)
            onDidDismissSelf?()
        }
    }

    // MARK: - Screen awake

    // Auto-lock on iOS is commonly shorter than the recorder's own two-minute limit, so a
    // long recording can be cut off by the device locking. See VoiceboxScreenAwake for
    // why this is the SDK's job and why it is ref-counted.
    //
    // Paired against the view lifecycle rather than the WebView's state: viewDidAppear /
    // viewDidDisappear are guaranteed to balance, and `isHoldingScreenAwake` makes a
    // repeated appear (e.g. returning from a nested presentation) a no-op rather than a
    // second, unmatched acquire.

    private func acquireScreenAwakeIfNeeded() {
        guard voiceboxView.effectiveKeepsScreenAwake, !isHoldingScreenAwake else { return }
        isHoldingScreenAwake = true
        VoiceboxScreenAwake.shared.acquire()
    }

    private func releaseScreenAwakeIfNeeded() {
        guard isHoldingScreenAwake else { return }
        isHoldingScreenAwake = false
        VoiceboxScreenAwake.shared.release()
    }

    // MARK: - Setup

    private func setupWebView() {
        // Try to reuse a preloaded WebView — only a hit if it was warmed with
        // this EXACT URL (same handle + params); otherwise a mismatched preload
        // (e.g. different email/prompt) would silently show stale content.
        let targetURL = voiceboxView.buildURL()
        switch VoiceboxCache.shared.consumePreloadedWebView(for: voiceboxView.handle, matching: targetURL) {
        case .ready(let preloaded):
            webView = preloaded
            usedPreloadedWebView = true
            // Apply visual settings that makeWebView() would normally set
            voiceboxView.applyWebViewSettings(webView)
            // The preloaded page is ALREADY loaded, so applyWebViewSettings'
            // WKUserScript (which only fires on the next navigation) won't run
            // on it. Inject the chrome CSS directly into the live DOM now, or
            // the footer/background hiding would only work on fresh loads —
            // the source of the "sometimes shows chrome, sometimes not" flakiness.
            voiceboxView.applyChromeCSSNow(to: webView)

        case .warming(let inFlight):
            // Same URL, load already running. Adopt it and wait: `loadVoicebox()` deliberately
            // issues no request, and the navigation delegate installed below picks up the
            // in-flight navigation's `didFinish`. The chrome CSS user script added by
            // `applyWebViewSettings` still applies, because that navigation has not committed
            // its document yet.
            webView = inFlight
            usedPreloadedWebView = false
            joinedInFlightWarm = true
            voiceboxView.applyWebViewSettings(webView)

        case .none:
            // Nothing warmed for this URL — the Directory's normal case, since the tapped
            // handle is unknowable in advance. Take the pre-built spare so this open at least
            // skips constructing a WKWebView and launching its WebContent process, which
            // measured as the single largest slice of an unpredicted open.
            if let spare = VoiceboxCache.shared.takeHotSpare() {
                webView = spare
                voiceboxView.applyWebViewSettings(webView)
            } else {
                webView = voiceboxView.makeWebView()
            }
            usedPreloadedWebView = false
        }

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        // Floating card: start hidden so a fresh (non-preloaded) load shows only
        // the card skeleton until the page is ready — `stopLoading()` reveals it.
        // The preloaded path calls stopLoading() immediately, so no visible delay.
        webView.alpha = isFloatingCard ? 0 : 1
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        // The WebView always fills the ENTIRE VC view — edge to edge, under the
        // status bar and home indicator. For .floatingCard this makes the voicebox's
        // background image/colour cover the WHOLE screen (no rounded-corner panel and
        // no safe-area top strip); the card is centered by the page's own CSS, and
        // the native dim sits behind the background — visible only where the page is
        // genuinely transparent.
        let bottom = webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        webViewBottomConstraint = bottom
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom,
        ])

        // Floating card only: own the keyboard avoidance ourselves. The recorder
        // page is a full-screen `100vh` layout with the card flex-centred; when a
        // field focuses, WKWebView's default behaviour scrolls the whole page up to
        // reveal the field, exposing the background above and the page chrome behind
        // the card (issue #246). Instead we (a) stop the scroll view adjusting its
        // own insets, and (b) shrink the WebView by the keyboard's height so `100vh`
        // recomputes and the card simply re-centres in the space above the keyboard —
        // the recorder background fills the rest, nothing scrolls into view. Scoped
        // to `.floatingCard` so sheet modes (with their own detent sizing) are untouched.
        if isFloatingCard {
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            registerKeyboardObservers()
        }

        navigationDelegate = VoiceboxNavigationDelegate(handle: voiceboxView.handle)
        navigationDelegate.onLoadingStateChanged = { [weak self] isLoading in
            self?.handleLoadingState(isLoading)
        }
        navigationDelegate.onError = { [weak self] error in
            self?.handleLoadError(error)
        }
        navigationDelegate.onHandleUnavailable = { [weak self] destination in
            self?.handleUnavailableHandle(redirectedTo: destination)
        }
        // Fallback: URL /sent/ pattern detection for message submission
        navigationDelegate.onMessageSubmitted = { [weak self] in
            guard let self else { return }
            self.voiceboxView.delegate?.voiceboxDidSubmitMessage(self.voiceboxView)
        }
        webView.navigationDelegate = navigationDelegate
        webView.uiDelegate = self

        // Register message handlers. The scripts that POST to them
        // (`VoiceboxWebScripts.eventUserScript`) are baked into the shared
        // configuration for both fresh and warmed WebViews, so — unlike before —
        // a reused preloaded WebView already has the recorder observers active
        // and just needs its handler registered here.
        webView.configuration.userContentController.add(self, name: Self.voiceboxEventMessageName)
        webView.configuration.userContentController.add(self, name: Self.bgColorMessageName)
        webView.configuration.userContentController.add(self, name: Self.domReadyMessageName)

        // For fitContent mode, register message handler to receive content height
        if voiceboxView.presentationMode == .fitContent {
            webView.configuration.userContentController.add(
                self,
                name: Self.contentHeightMessageName
            )
            registeredContentHeightHandler = true
        }
    }

    deinit {
        // Floating-card keyboard observers (no-op if never registered).
        NotificationCenter.default.removeObserver(self)
        // Safety net: if this controller is torn down without viewDidDisappear (never
        // presented, or dropped mid-transition) the held reference would otherwise leak
        // and the device would stop auto-locking for the rest of the session. Guarded, so
        // the normal path — released in viewDidDisappear — is a no-op here.
        if isHoldingScreenAwake {
            isHoldingScreenAwake = false
            VoiceboxScreenAwake.shared.release()
        }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.voiceboxEventMessageName)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bgColorMessageName)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.domReadyMessageName)
        if registeredContentHeightHandler {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.contentHeightMessageName)
        }
    }

    /// Trailing inset from the safe area for the close button in SHEET modes only.
    /// The floating card positions its × via a nav-bar item instead (see
    /// `installCloseButtonInNavBar`), so it lands at the host app's own standard
    /// bar-button slot with no hardcoded inset to keep in sync (issue #246).
    private static let closeButtonInset: CGFloat = 12

    private func setupCloseButton() {
        guard voiceboxView.showCloseButton else { return }

        let theme = voiceboxView.theme
        let buttonSize = theme.resolvedCloseButtonSize
        let iconColor = theme.resolvedCloseButtonIconColor
        let symbolName = theme.resolvedCloseButtonSymbolName

        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        // Icon — sized relative to button diameter so it scales cleanly
        let iconPointSize = max(12, buttonSize * 0.45)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: iconPointSize, weight: .semibold)
        let iconImage = UIImage(systemName: symbolName, withConfiguration: symbolConfig)?
            .withTintColor(iconColor, renderingMode: .alwaysOriginal)
        button.setImage(iconImage, for: .normal)

        // Background — a solid circular chip when the theme sets a colour, else
        // transparent (just the glyph). The floating card sets a filled circle
        // (e.g. white) matching the app's own icon buttons rather than relying on
        // translucent glass for contrast.
        if let bgColor = theme.closeButtonBackgroundColor {
            button.backgroundColor = bgColor
            button.layer.cornerRadius = buttonSize / 2
            if isFloatingCard {
                // The card floats over arbitrary voicebox backgrounds, including
                // LIGHT background images where a plain white circle blends in. A
                // soft drop shadow keeps it defined on ANY backdrop. clipsToBounds
                // must stay off or the shadow is clipped; the rounded background
                // colour still renders as a circle via cornerRadius.
                button.clipsToBounds = false
                button.layer.shadowColor = UIColor.black.cgColor
                button.layer.shadowOpacity = 0.3
                button.layer.shadowRadius = 5
                button.layer.shadowOffset = CGSize(width: 0, height: 2)
            } else {
                button.clipsToBounds = true
            }
        } else {
            button.backgroundColor = .clear
        }

        // Accessibility
        button.accessibilityLabel = "Close"
        button.accessibilityTraits = .button

        // The button owns its size in every mode — a bar-button customView needs an
        // explicit size to lay out.
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: buttonSize),
            button.heightAnchor.constraint(equalToConstant: buttonSize),
        ])
        self.closeButton = button

        if isFloatingCard {
            // Let the system place it at the app's standard bar-button slot.
            installCloseButtonInNavBar(button)
        } else {
            // Sheet modes: pin to the top-trailing safe area (the sheet's own chrome
            // owns the top, so a nav bar would be redundant here).
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Self.closeButtonInset),
                button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Self.closeButtonInset),
            ])
        }
    }

    /// Floating card: host the × as a real nav-bar item so the SYSTEM positions it
    /// at the same standard trailing slot the app's own nav-bar buttons use — the
    /// create-voicebox header ×, the Directory owner mark, etc. This lines the ×
    /// up with the app's chrome automatically, across devices and orientations, with
    /// no hardcoded inset to keep in sync (issue #246). The bar is fully transparent,
    /// so the recorder's full-bleed background shows straight through it — only the ×
    /// is drawn.
    private func installCloseButtonInNavBar(_ button: UIButton) {
        let navBar = UINavigationBar()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        let transparent = UINavigationBarAppearance()
        transparent.configureWithTransparentBackground()
        navBar.standardAppearance = transparent
        navBar.scrollEdgeAppearance = transparent
        navBar.compactAppearance = transparent
        // A transparent bar over a full-bleed background has no content of its own to
        // hit-test; only the × item is interactive.
        let closeItem = UIBarButtonItem(customView: button)
        // iOS 26 wraps bar-button items in a shared Liquid Glass background; our ×
        // already carries its own solid white disc, so suppress the system glass or
        // it paints a faint (sometimes colour-tinted) rounded-rect halo behind the
        // disc — visible in issue #246 verification over the Directory / a detail.
        if #available(iOS 26.0, *) {
            closeItem.hidesSharedBackground = true
        }
        let navItem = UINavigationItem()
        navItem.rightBarButtonItem = closeItem
        navBar.setItems([navItem], animated: false)

        view.addSubview(navBar)
        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.closeNavBar = navBar
    }

    /// Brings whichever dismiss control this mode uses to the front — the nav bar for
    /// the floating card, the bare button for sheet modes.
    private func bringCloseControlToFront() {
        if let navBar = closeNavBar {
            view.bringSubviewToFront(navBar)
        } else if let button = closeButton {
            view.bringSubviewToFront(button)
        }
    }

    private func setupSkeletonView() {
        // Always create the skeleton (keeps the `stopLoading()` calls safe), but
        // in floating-card mode it stays hidden/unused — a centered spinner is
        // shown instead (see `startLoading()`).
        skeletonView = VoiceboxSkeletonView()
        skeletonView.translatesAutoresizingMaskIntoConstraints = false
        skeletonView.isHidden = true
        skeletonView.backgroundColor = voiceboxView.theme.resolvedBackgroundColor
        view.addSubview(skeletonView)

        NSLayoutConstraint.activate([
            skeletonView.topAnchor.constraint(equalTo: view.topAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeletonView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        guard isFloatingCard else { return }
        let cardSkeleton = VoiceboxCardSkeletonView()
        // Dim is now painted natively on the container view, so the skeleton's own
        // backdrop stays clear (setting it here would double the dim during load).
        cardSkeleton.dimOpacity = 0
        cardSkeleton.translatesAutoresizingMaskIntoConstraints = false
        cardSkeleton.isHidden = true
        view.addSubview(cardSkeleton)
        NSLayoutConstraint.activate([
            cardSkeleton.topAnchor.constraint(equalTo: view.topAnchor),
            cardSkeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cardSkeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cardSkeleton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        cardSkeletonView = cardSkeleton
    }

    /// Routes the loading indicator to the presentation-appropriate skeleton: the
    /// card-shaped shimmer for `.floatingCard`, the full-width shimmer otherwise.
    ///
    /// For the floating card the skeleton's surround is transparent, so the real
    /// (differently-sized) WebView card would peek out behind it — a doubled-card
    /// look. Hide the WebView while the skeleton is up and reveal it as the
    /// skeleton fades, so the transition is skeleton → card, never both at once.
    private func startLoading() {
        if isFloatingCard {
            webView.alpha = 0
            cardSkeletonView?.startAnimating()
        } else {
            skeletonView.startAnimating()
        }
    }

    private func stopLoading() {
        if isFloatingCard {
            // Set up + start the background reveal while the WebView is still hidden,
            // then un-hide it in the completion so the first visible frame is the
            // START of the reveal — no flash of the un-animated background.
            playFloatingCardEntrance { [weak self] in
                guard let self else { return }
                self.webView.alpha = 1
                self.cardSkeletonView?.stopAnimating()
            }
        } else {
            skeletonView.stopAnimating()
        }
    }

    // MARK: - Entrance timing
    //
    // The entrance plays AFTER the content is ready, so its duration is added directly to
    // what the user experiences as "how long the recorder took to open" — on a warm preload
    // hit (~25 ms to ready) the animation WAS the entire perceived open.
    //
    // These were 1.2 s and 850 ms/180 ms. Measured against a ~1.1–1.7 s load that put roughly
    // a second of pure animation on top of every open, which read as lag. Retimed to the
    // range iOS itself uses for modal transitions (~0.3 s), which keeps the reveal and the
    // lift-in legible while removing the wait. Reduce Motion still skips both entirely.

    /// Background reveal: fade + settle from a slight scale-up.
    private static let backgroundRevealDuration: TimeInterval = 0.35
    /// Card lift-in, run by the page's own Web Animations API (milliseconds).
    private static let cardLiftInDurationMs = 300
    /// Delay before the card lift-in, so it reads as following the background (milliseconds).
    private static let cardLiftInDelayMs = 60

    /// Floating card only: the one-shot entrance, honouring `entranceAnimation`.
    /// With `.backgroundReveal`, the full-screen background scales down slightly and
    /// fades in; with `.cardLiftIn`, the card assembly (logo + card) lifts up and
    /// scales into place a beat later. Either can be omitted, or both (`.none`).
    ///
    /// The background is painted by the web page, so `.backgroundReveal` lifts it
    /// onto a fixed layer *behind* the page content and animates that; the card
    /// (`#main`) is animated separately on top. Respects Reduce Motion. `completion`
    /// always runs (even with `.none`) so the caller can un-hide the WebView.
    private func playFloatingCardEntrance(completion: @escaping () -> Void) {
        let anim = voiceboxView.entranceAnimation
        let revealBg = anim.contains(.backgroundReveal)
        let liftCard = anim.contains(.cardLiftIn)
        // Capture the page's background (colour + image), then STRIP it from the page so
        // the WebView is fully transparent and the NATIVE layer behind it is the ONLY
        // background. This removes the position:fixed reveal layer that WKWebView
        // mis-covers when the keyboard opens (issue #246) — the background can no longer
        // fall through to the dim. The card lift-in stays web-side; the background reveal
        // is animated natively (see installNativeBackground).
        let js = """
        (function() {
            var liftCard = \(liftCard);
            var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
            var canAnimate = !reduce && typeof document.body.animate === 'function';
            function real(v) { return v && v !== 'none' && v !== 'rgba(0, 0, 0, 0)' && v !== 'transparent'; }
            var revealed = { color: null, image: null };

            var host = document.getElementById('main') || document.body;
            var cs = getComputedStyle(host);
            var bodyCs = getComputedStyle(document.body);
            var image = real(cs.backgroundImage) ? cs.backgroundImage : bodyCs.backgroundImage;
            var color = real(cs.backgroundColor) ? cs.backgroundColor : bodyCs.backgroundColor;
            if (real(color)) { revealed.color = color; }
            if (real(image)) { revealed.image = image; }

            // Strip the page background so only the native layer paints it.
            var old = document.getElementById('vbx-bg-reveal'); if (old) { old.remove(); }
            host.style.setProperty('background', 'transparent', 'important');
            document.body.style.setProperty('background', 'transparent', 'important');
            document.documentElement.style.setProperty('background', 'transparent', 'important');

            if (liftCard && canAnimate) {
                // A beat after the background, the card assembly (logo + card) lifts up
                // and scales into place — a layered, premium-feeling entrance.
                var main = document.getElementById('main');
                if (main && typeof main.animate === 'function') {
                    main.animate(
                        [ { opacity: 0, transform: 'translateY(26px) scale(0.96)' },
                          { opacity: 1, transform: 'translateY(0) scale(1)' } ],
                        { duration: \(Self.cardLiftInDurationMs), delay: \(Self.cardLiftInDelayMs), easing: 'cubic-bezier(0.16, 1, 0.3, 1)', fill: 'both' }
                    );
                }
            }
            return revealed;
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self else { completion(); return }
                if let dict = result as? [String: Any] {
                    let color = (dict["color"] as? String)
                        .flatMap { UIColor(cssString: $0) }
                        .flatMap { $0.cgColor.alpha > 0.01 ? $0 : nil }
                    let imageURL = (dict["image"] as? String)
                        .flatMap { Self.backgroundImageURL(fromCSS: $0) }
                    self.installNativeBackground(color: color, imageURL: imageURL, animated: revealBg)
                }
                completion()
            }
        }
    }

    /// Extracts the first URL from a CSS `background-image` value such as
    /// `url("https://…")` (also handles single-quoted / un-quoted forms).
    private static func backgroundImageURL(fromCSS css: String) -> URL? {
        guard let open = css.range(of: "url("),
              let close = css.range(of: ")", range: open.upperBound..<css.endIndex) else { return nil }
        let inner = css[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard inner.hasPrefix("http") else { return nil }   // skip data:/gradients/etc.
        return URL(string: inner)
    }

    /// Floating card: the voicebox's background lives ENTIRELY on this native view behind
    /// the (background-stripped) WebView, so it always covers during a keyboard resize —
    /// no position:fixed web layer to mis-cover (issue #246). Holds the solid colour
    /// and/or the image (aspect-fill). When `animated`, it fades + scales in to reproduce
    /// the old web "background reveal" entrance.
    private func installNativeBackground(color: UIColor?, imageURL: URL?, animated: Bool) {
        guard isFloatingCard, backgroundRevealView == nil,
              color != nil || imageURL != nil else { return }
        let bg = UIImageView()
        bg.contentMode = .scaleAspectFill
        bg.clipsToBounds = true
        bg.backgroundColor = color
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(bg, at: 0)   // behind the WebView, over the native dim
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        backgroundRevealView = bg
        if let color { onBackgroundColorDetected?(color) }

        if let imageURL {
            // Served from the WebView's cache (it just loaded this asset).
            URLSession.shared.dataTask(with: imageURL) { [weak bg] data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { bg?.image = image }
            }.resume()
        }

        if animated && !UIAccessibility.isReduceMotionEnabled {
            bg.alpha = 0
            bg.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
            UIView.animate(withDuration: Self.backgroundRevealDuration, delay: 0, options: [.curveEaseOut]) {
                bg.alpha = 1
                bg.transform = .identity
            }
        }
    }

    // MARK: - Keyboard avoidance (floating card)

    private func registerKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        // How much of THIS view the keyboard covers, in local coordinates. An
        // off-screen end frame (keyboard dismissing) yields 0 and restores the card.
        let overlap = max(0, view.bounds.maxY - view.convert(end, from: nil).minY)
        setKeyboardInset(overlap, note: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        setKeyboardInset(0, note: note)
    }

    /// Shrinks (or restores) the WebView from the bottom by `inset`, animating in
    /// step with the keyboard. The `100vh` page re-centres its card in the reduced
    /// viewport, so the card stays fully visible above the keyboard and nothing
    /// scrolls the background/chrome into view.
    private func setKeyboardInset(_ inset: CGFloat, note: Notification) {
        guard let bottom = webViewBottomConstraint, bottom.constant != -inset else { return }
        bottom.constant = -inset
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
            ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
        UIView.animate(
            withDuration: duration, delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curveRaw) << 16),
            animations: { [weak self] in
                guard let self else { return }
                self.view.layoutIfNeeded()
                // Belt and braces: keep the (now content-sized) page pinned to the top
                // so no residual WebKit auto-scroll can re-expose the chrome behind the card.
                self.webView.scrollView.contentOffset.y = 0
            }
        )
    }

    // MARK: - Loading

    private func loadVoicebox() {
        if usedPreloadedWebView {
            // Reveal through the same one-shot path as every other route rather than logging
            // separately here — doing both produced two contradictory `open READY` lines for
            // one open, and short-circuiting the latch instead would skip `stopLoading()` and
            // leave the WebView at alpha 0 forever.
            revealContent(documentURL: nil)
            // Safe to skip the reload entirely: `VoiceboxCache.consumePreloadedWebView`
            // only ever hands back a WebView whose background navigation already
            // finished SUCCESSFULLY at this exact URL (tracked via its own
            // temporary navigation delegate during warm-up) — a still-loading or
            // failed preload is never returned, so there's no blank-sheet risk
            // here. The content is already rendered; just clear the skeleton.
            handleLoadingState(false)
            return
        }

        if joinedInFlightWarm {
            // The request is already on the wire. Issuing another `load()` here would cancel
            // it and start over, throwing away however much of it had completed — exactly the
            // duplicated work this path exists to avoid. Just put the skeleton up and let the
            // navigation delegate's `didFinish` take it down.
            startLoading()
            return
        }

        let url = voiceboxView.buildURL()
        let cache = VoiceboxCache.shared

        // `dataStoreWarm` distinguishes the two slow paths: a handle never opened before on
        // a device whose asset cache IS populated should still be quick (document only),
        // while a genuinely cold data store re-downloads the whole bundle.
        // `afterOpen` is everything spent BEFORE the network is touched: creating the
        // WKWebView (which spins up a WebContent process), the skeleton and close button,
        // the mic-permission check, and the presentation animation. It is dead time that a
        // reusable already-live WebView would remove entirely, so it needs its own number —
        // subtracting `nav FINISH` from `open READY` only estimates it.

        if cache.hasCachedContent(for: voiceboxView.handle) {
            // Floating card hides the WebView until ready, so show the skeleton
            // even for a cached load or there'd be a blank frame before the
            // navigation delegate's isLoading callback arrives. (Sheets keep the
            // old behaviour: their skeleton stays hidden for a fast cached load.)
            if isFloatingCard { startLoading() }
            webView.load(URLRequest(url: url))
        } else if isNetworkAvailable() {
            startLoading()
            webView.load(URLRequest(url: url))
        } else {
            showOfflineView()
        }
    }

    /// Uncovers the WebView. Called from whichever comes FIRST: the page's own DOM-ready
    /// signal (`VoiceboxWebScripts.domReadyUserScript`, the normal case) or `didFinish` (the
    /// fallback, for a page whose JS never ran).
    ///
    /// Waiting for `didFinish` alone cost ~400 ms of staring at a skeleton while already-
    /// painted content sat hidden behind it — see the doc comment on `domReadyUserScript`.
    /// One-shot, because both callers can fire and `didFinish` also runs again after in-page
    /// navigations and web-content-process relaunches.
    private func revealContent(documentURL: URL?) {
        // Identity check, NOT a timing check. The hot spare arrives holding a blank document
        // that runs this same script, and an off-screen WebView never paints — so its queued
        // callback can fire moments AFTER adoption, once the view is finally in a hierarchy.
        // A flag saying "our load has started" does not catch that: the stale post lands
        // between `load()` and the new document committing, and we uncover an empty sheet
        // (observed: revealed at 85 ms, real content 2.6 s later). Only a signal from a
        // document that IS this handle's recorder counts.
        if let documentURL, !VoiceboxURLBuilder.isRecorderPath(documentURL, handle: voiceboxView.handle) {
            return
        }
        guard !didReveal else { return }
        didReveal = true

        if voiceboxView.theme.backgroundColor == nil {
            // Keep the skeleton visible while JS detects the page colour.
            // applyWebBackgroundColor() will stop it once the colour is set,
            // so there's no white-strip flash between skeleton fade-out and colour update.
            // Safety net: force-stop after 1 s in case detection never fires (JS error, etc.).
            detectWebBackgroundColor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.stopLoading()
            }
        } else {
            stopLoading()
        }
    }

    private func handleLoadingState(_ isLoading: Bool) {
        if isLoading {
            startLoading()
        } else {
            // Normally a no-op by now: the page's DOM-ready signal has already revealed it.
            // This is the fallback for a page whose scripts never ran.
            revealContent(documentURL: webView.url)
            if voiceboxView.presentationMode == .fitContent {
                measureContentHeight()
            }
            // Drop WKWebView's default keyboard accessory bar (the ‹ › / Done toolbar
            // it shows above the keyboard for web form fields) once the page is up —
            // the recorder's contact form doesn't need it, and it read as a coloured
            // strip above the keyboard (issue #246). Idempotent, so re-running on each
            // load (incl. a relaunched web content process) is safe.
            webView.removeInputAccessoryBar()
        }
    }

    private func detectWebBackgroundColor() {
        // Only auto-detect when the caller hasn't pinned an explicit background colour.
        // If theme.backgroundColor is set, the caller owns the colour — don't override it.
        guard voiceboxView.theme.backgroundColor == nil else { return }
        let js = """
        (function() {
            var bg = window.getComputedStyle(document.body).backgroundColor;
            if (!bg || bg === 'rgba(0, 0, 0, 0)' || bg === 'transparent') {
                bg = window.getComputedStyle(document.documentElement).backgroundColor;
            }
            window.webkit.messageHandlers.\(Self.bgColorMessageName).postMessage(bg);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func applyWebBackgroundColor(_ cssColor: String) {
        guard let color = UIColor(cssString: cssColor),
              color.cgColor.alpha > 0.01 else {
            // Detection fired but returned transparent/invalid — unblock the skeleton.
            stopLoading()
            return
        }
        view.backgroundColor = color
        // Notify the SwiftUI layer so it can update presentationBackground
        // to match — this closes the gap for the home-indicator strip at the bottom.
        onBackgroundColorDetected?(color)
        // Stop the skeleton now that the correct colour is in place.
        // The skeleton was kept visible in handleLoadingState to avoid a white-strip flash.
        stopLoading()
    }

    // MARK: - Content Height (fitContent)

    private func measureContentHeight() {
        let js = """
        (function() {
            // Make the recorder card hug its CONTENT. It's normally `h-100`, stretched
            // to the fixed-height (100vh) page, so its height tracks the viewport, not
            // its content — which means it can't reflect content changes AND would feed
            // back on our own sheet resize. height:auto makes it content-driven so the
            // live observer below is stable (resizing the sheet doesn't loop back here).
            if (!document.getElementById('vbx-fitcontent-style')) {
                var s = document.createElement('style');
                s.id = 'vbx-fitcontent-style';
                s.textContent = '#recorder-card{height:auto !important;} body.recorder.show > #main{min-height:0 !important;}';
                document.head.appendChild(s);
            }
            // Measure the rendered BOTTOM of the recorder card (plus the footer when
            // it's visible) rather than the document — the 100vh page always reports
            // ~one full screen, which .fitContent could never hug.
            function bottomOf(el) {
                // offsetParent === null ⇒ display:none (e.g. a chrome-hidden footer) — skip it.
                if (!el || el.offsetParent === null) return 0;
                var scroll = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
                return el.getBoundingClientRect().bottom + scroll;
            }
            function currentHeight() {
                var contentBottom = Math.max(
                    bottomOf(document.getElementById('recorder-card')),
                    bottomOf(document.getElementById('recorder-footer'))
                );
                // Fall back to the document height if the card isn't found (DOM changed).
                return contentBottom > 0 ? contentBottom : Math.max(
                    document.body.scrollHeight,
                    document.body.offsetHeight,
                    document.documentElement.scrollHeight,
                    document.documentElement.offsetHeight
                );
            }
            function post() {
                try {
                    var mh = window.webkit && window.webkit.messageHandlers
                        && window.webkit.messageHandlers.\(Self.contentHeightMessageName);
                    if (!mh) return;
                    var h = Math.ceil(currentHeight());
                    if (Math.abs(h - (window.__vbxLastHeight || 0)) < 2) return; // ignore churn
                    window.__vbxLastHeight = h;
                    mh.postMessage(h);
                } catch (e) {}
            }
            window.__vbxPostHeight = post; // keep the observer pointed at the latest closure
            post();
            setTimeout(post, 350); // re-fit after webfont / logo image settle

            // Live re-fit: follow the card as its content changes (recording UI, async
            // cards, contact form). Debounced so a burst of mutations animates once.
            var card = document.getElementById('recorder-card');
            if (card && !window.__vbxHeightObserver && typeof ResizeObserver !== 'undefined') {
                var t = null;
                window.__vbxHeightObserver = new ResizeObserver(function() {
                    if (t) { clearTimeout(t); }
                    t = setTimeout(function() { if (window.__vbxPostHeight) window.__vbxPostHeight(); }, 120);
                });
                window.__vbxHeightObserver.observe(card);
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func updateSheetHeight(_ contentHeight: CGFloat) {
        guard let sheet = sheetPresentationController else { return }

        let safeAreaTop = view.safeAreaInsets.top
        let totalHeight = contentHeight + safeAreaTop + 20

        // Remember this for next time so a future `.fitContent` open can start
        // at roughly the right size instead of always flashing full-screen.
        VoiceboxCache.shared.setCachedContentHeight(totalHeight, for: voiceboxView.handle)

        if #available(iOS 16.0, *) {
            let customDetent = UISheetPresentationController.Detent.custom { context in
                min(totalHeight, context.maximumDetentValue)
            }
            sheet.detents = [customDetent, .large()]
            sheet.animateChanges {
                sheet.selectedDetentIdentifier = customDetent.identifier
            }
        }
    }

    /// The handle doesn't resolve server-side, so the navigation was cancelled before the
    /// redirect target could render (see `VoiceboxNavigationDelegate`).
    ///
    /// Reported as a load failure rather than silently showing an empty sheet: the host app
    /// is the only thing that can act on it — typically by removing a stale entry from
    /// whatever list offered this handle. The sheet is left empty rather than showing the
    /// offline view, which would wrongly blame the network.
    private func handleUnavailableHandle(redirectedTo destination: URL) {
        stopLoading()
        let error = NSError(
            domain: "com.voiceboxkit",
            code: 404,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Voicebox @\(voiceboxView.handle) is not available. "
                    + "The server redirected to \(destination.absoluteString).",
                NSURLErrorFailingURLStringErrorKey: voiceboxView.buildURL().absoluteString
            ]
        )
        voiceboxView.delegate?.voiceboxDidFail(voiceboxView, error: error)
    }

    private func handleLoadError(_ error: Error) {
        stopLoading()
        let nsError = error as NSError

        // -999 is OUR OWN cancel from the unavailable-handle guard; `handleUnavailableHandle`
        // has already reported a far more useful error, so don't raise a second, vaguer one.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }

        voiceboxView.delegate?.voiceboxDidFail(voiceboxView, error: error)

        if nsError.domain == NSURLErrorDomain {
            let offlineCodes: Set<Int> = [
                NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
            ]
            if offlineCodes.contains(nsError.code) {
                showOfflineView()
            }
        }
    }

    private func showOfflineView() {
        guard offlineView == nil else { return }

        webView.isHidden = true
        let offline = VoiceboxOfflineView()
        offline.translatesAutoresizingMaskIntoConstraints = false
        offline.onRetry = { [weak self] in
            self?.retryLoading()
        }
        view.addSubview(offline)

        NSLayoutConstraint.activate([
            offline.topAnchor.constraint(equalTo: view.topAnchor),
            offline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            offline.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            offline.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        bringCloseControlToFront()

        self.offlineView = offline
    }

    private func retryLoading() {
        offlineView?.removeFromSuperview()
        offlineView = nil
        webView.isHidden = false
        loadVoicebox()
    }

    private func isNetworkAvailable() -> Bool {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)

        guard let reachability = withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                SCNetworkReachabilityCreateWithAddress(nil, ptr)
            }
        }) else { return true }

        var flags = SCNetworkReachabilityFlags()
        if !SCNetworkReachabilityGetFlags(reachability, &flags) {
            return true
        }

        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        return isReachable && !needsConnection
    }

    // MARK: - Microphone

    private func requestMicrophonePermission() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.loadVoicebox()
                }
            }
        case .denied, .granted:
            loadVoicebox()
        @unknown default:
            loadVoicebox()
        }
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

// MARK: - WKScriptMessageHandler

extension VoiceboxViewController: WKScriptMessageHandler {

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case Self.voiceboxEventMessageName:
            if let event = message.body as? String {
                switch event {
                case "recordingComplete":
                    voiceboxView.delegate?.voiceboxDidFinishRecording(voiceboxView)
                case "messageSubmitted":
                    voiceboxView.delegate?.voiceboxDidSubmitMessage(voiceboxView)
                case "dismiss":
                    // Tap-outside-the-card in `.floatingCard` mode (there's no
                    // native swipe-down here). Dismiss the presented controller.
                    dismiss(animated: true)
                default:
                    break
                }
            }

        case Self.contentHeightMessageName:
            if let height = message.body as? CGFloat {
                updateSheetHeight(height)
            }

        case Self.bgColorMessageName:
            if let css = message.body as? String {
                DispatchQueue.main.async { self.applyWebBackgroundColor(css) }
            }

        case Self.domReadyMessageName:
            // The recorder's DOM is parsed and styled. Everything still in flight (visualizer,
            // ActionCable, ahoy, Bugsnag) is background machinery that changes nothing on
            // screen, so the user should not be kept behind a skeleton waiting for it.
            // The body carries the document's own URL — `revealContent` uses it to reject a
            // signal from some other document this WebView previously held.
            revealContent(documentURL: (message.body as? String).flatMap(URL.init(string:)))

        default:
            break
        }
    }
}

// MARK: - WKUIDelegate (Mic Permission)

extension VoiceboxViewController: WKUIDelegate {

    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard voiceboxView.effectiveAutoGrantMicPermission else {
            decisionHandler(.prompt)
            return
        }

        if type == .microphone {
            let nativePermission = AVAudioSession.sharedInstance().recordPermission
            if nativePermission == .granted {
                decisionHandler(.grant)
            } else {
                decisionHandler(.prompt)
            }
        } else {
            decisionHandler(.prompt)
        }
    }
}

// MARK: - UIColor CSS parsing

private extension UIColor {

    /// Parses `rgb(r, g, b)` or `rgba(r, g, b, a)` returned by
    /// `window.getComputedStyle(...).backgroundColor` into a UIColor.
    convenience init?(cssString: String) {
        let s = cssString.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("rgb"),
              let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")")
        else { return nil }

        let inner = String(s[s.index(after: open)..<close])
        let parts = inner
            .components(separatedBy: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        guard parts.count >= 3 else { return nil }
        let alpha = parts.count == 4 ? parts[3] : 1.0
        self.init(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: alpha)
    }
}

// MARK: - Remove WKWebView keyboard accessory bar

/// Donor whose `inputAccessoryView` getter (returning nil) is grafted onto the
/// runtime subclass of `WKContentView` created below.
private final class VoiceboxNoInputAccessory: NSObject {
    @objc var inputAccessoryView: AnyObject? { nil }
}

private extension WKWebView {
    /// Removes the system "form assistant" accessory bar (the ‹ › / Done toolbar
    /// shown above the keyboard for web form fields). There is no public API for
    /// this: the real first responder is the private `WKContentView`, so we swap
    /// THAT view's class for a runtime subclass whose `inputAccessoryView` returns
    /// nil. Scoped to this web view's own content view (not a global swizzle), and
    /// idempotent — a second call just re-applies the cached subclass.
    func removeInputAccessoryBar() {
        guard let target = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }) else { return }

        let subclassName = "\(type(of: target))_VBXNoInputAccessory"
        if let cached = NSClassFromString(subclassName) {
            object_setClass(target, cached)
            return
        }
        guard let baseClass = object_getClass(target),
              let subclass = objc_allocateClassPair(baseClass, subclassName, 0),
              let donor = class_getInstanceMethod(
                VoiceboxNoInputAccessory.self,
                #selector(getter: VoiceboxNoInputAccessory.inputAccessoryView))
        else { return }

        class_addMethod(
            subclass,
            #selector(getter: UIResponder.inputAccessoryView),
            method_getImplementation(donor),
            method_getTypeEncoding(donor)
        )
        objc_registerClassPair(subclass)
        object_setClass(target, subclass)
    }
}
