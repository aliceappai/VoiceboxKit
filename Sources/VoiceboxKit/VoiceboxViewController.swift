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
    private var hasAppeared = false
    private var registeredContentHeightHandler = false
    /// Whether THIS controller currently holds a `VoiceboxScreenAwake` reference, so the
    /// acquire/release pair stays balanced across repeated appear/disappear cycles.
    private var isHoldingScreenAwake = false
    // Share the names with the baked-in user scripts (VoiceboxWebScripts) so a
    // warmed WebView's scripts post to the same handlers this controller registers.
    private static let contentHeightMessageName = VoiceboxWebScripts.contentHeightMessageName
    private static let voiceboxEventMessageName = VoiceboxWebScripts.eventMessageName
    private static let bgColorMessageName = VoiceboxWebScripts.bgColorMessageName

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
        // Keep the close button above the WebView no matter what — a floating card
        // over a full-screen background image must never bury its only dismiss
        // control behind late-added/re-ordered subviews.
        if let closeButton = closeButton { view.bringSubviewToFront(closeButton) }
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
        if let preloaded = VoiceboxCache.shared.consumePreloadedWebView(for: voiceboxView.handle, matching: targetURL) {
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
        } else {
            webView = voiceboxView.makeWebView()
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
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        navigationDelegate = VoiceboxNavigationDelegate(handle: voiceboxView.handle)
        navigationDelegate.onLoadingStateChanged = { [weak self] isLoading in
            self?.handleLoadingState(isLoading)
        }
        navigationDelegate.onError = { [weak self] error in
            self?.handleLoadError(error)
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
        if registeredContentHeightHandler {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.contentHeightMessageName)
        }
    }

    /// Inset from the safe area for the close button. The floating card uses the
    /// standard 16pt content margin; sheet modes keep their tighter 12pt.
    private static let closeButtonInset: CGFloat = 12
    private static let floatingCardCloseButtonInset: CGFloat = 16

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

        view.addSubview(button)
        let inset = isFloatingCard ? Self.floatingCardCloseButtonInset : Self.closeButtonInset
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: inset),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -inset),
            button.widthAnchor.constraint(equalToConstant: buttonSize),
            button.heightAnchor.constraint(equalToConstant: buttonSize),
        ])

        self.closeButton = button
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
        guard revealBg || liftCard else {
            // No entrance animation requested — just un-hide the WebView.
            completion()
            return
        }
        let js = """
        (function() {
            var revealBg = \(revealBg);
            var liftCard = \(liftCard);
            var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
            var canAnimate = !reduce && typeof document.body.animate === 'function';
            function real(v) { return v && v !== 'none' && v !== 'rgba(0, 0, 0, 0)' && v !== 'transparent'; }

            if (revealBg) {
                var host = document.getElementById('main') || document.body;
                var cs = getComputedStyle(host);
                var bodyCs = getComputedStyle(document.body);
                var image = real(cs.backgroundImage) ? cs.backgroundImage : bodyCs.backgroundImage;
                var color = real(cs.backgroundColor) ? cs.backgroundColor : bodyCs.backgroundColor;
                if (real(image) || real(color)) {
                    var layer = document.getElementById('vbx-bg-reveal');
                    if (!layer) {
                        layer = document.createElement('div');
                        layer.id = 'vbx-bg-reveal';
                        var s = layer.style;
                        s.position = 'fixed'; s.top = '0'; s.left = '0'; s.right = '0'; s.bottom = '0';
                        s.zIndex = '-1';                 // behind the card + page content
                        s.pointerEvents = 'none';        // taps fall through (tap-outside dismiss still works)
                        s.transformOrigin = 'center';
                        s.willChange = 'transform, opacity';
                        s.backgroundImage = image;
                        s.backgroundColor = color;
                        // Force a full-screen cover: the image can come from `body` while the
                        // page's own size/repeat live on a smaller box (`#main` at 340px, or an
                        // unset default of `auto`+`repeat`), which would TILE the image here.
                        s.backgroundSize = 'cover';
                        s.backgroundPosition = 'center';
                        s.backgroundRepeat = 'no-repeat';
                        document.body.appendChild(layer);
                        // Lift the background off the page so it isn't painted twice (a static
                        // copy at element level would sit on top of the z-index:-1 layer).
                        host.style.setProperty('background', 'transparent', 'important');
                        document.body.style.setProperty('background', 'transparent', 'important');
                    }
                    if (canAnimate) {
                        layer.animate(
                            [ { opacity: 0, transform: 'scale(1.08)' },
                              { opacity: 1, transform: 'scale(1)' } ],
                            { duration: 1500, easing: 'cubic-bezier(0.22, 1, 0.36, 1)', fill: 'both' }
                        );
                    } else {
                        layer.style.opacity = '1'; layer.style.transform = 'none';
                    }
                }
            }

            if (liftCard && canAnimate) {
                // A beat after the background, the card assembly (logo + card) lifts
                // up and scales into place — a layered, premium-feeling entrance.
                var main = document.getElementById('main');
                if (main && typeof main.animate === 'function') {
                    main.animate(
                        [ { opacity: 0, transform: 'translateY(26px) scale(0.96)' },
                          { opacity: 1, transform: 'translateY(0) scale(1)' } ],
                        { duration: 850, delay: 180, easing: 'cubic-bezier(0.16, 1, 0.3, 1)', fill: 'both' }
                    );
                }
            }
        })();
        """
        webView.evaluateJavaScript(js) { _, _ in
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Loading

    private func loadVoicebox() {
        if usedPreloadedWebView {
            // Safe to skip the reload entirely: `VoiceboxCache.consumePreloadedWebView`
            // only ever hands back a WebView whose background navigation already
            // finished SUCCESSFULLY at this exact URL (tracked via its own
            // temporary navigation delegate during warm-up) — a still-loading or
            // failed preload is never returned, so there's no blank-sheet risk
            // here. The content is already rendered; just clear the skeleton.
            handleLoadingState(false)
            return
        }

        let url = voiceboxView.buildURL()
        let cache = VoiceboxCache.shared

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

    private func handleLoadingState(_ isLoading: Bool) {
        if isLoading {
            startLoading()
        } else {
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
            if voiceboxView.presentationMode == .fitContent {
                measureContentHeight()
            }
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

    private func handleLoadError(_ error: Error) {
        stopLoading()
        let nsError = error as NSError

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

        if let close = closeButton {
            view.bringSubviewToFront(close)
        }

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
