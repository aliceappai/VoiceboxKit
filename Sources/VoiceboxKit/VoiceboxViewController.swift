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
    private var usedPreloadedWebView = false
    private var hasAppeared = false
    private var registeredContentHeightHandler = false

    // MARK: Overlay presentation (.overlay)

    private var isOverlay: Bool { voiceboxView.presentationMode == .overlay }
    /// Dimmed backdrop; tapping it (or the transparent corners that fall through
    /// to it) dismisses. Card-width WebView host that is hit-tested to the
    /// silhouette. Bottom-pinned height that animates as the content resizes.
    private var overlayScrim: UIView?
    private var overlayContainer: VoiceboxOverlayContainerView?
    private var overlayHeightConstraint: NSLayoutConstraint?
    private var overlayDidSlideIn = false
    private var overlaySilhouette = VoiceboxOverlaySilhouette()
    private static let overlayCardWidth = VoiceboxOverlaySilhouette.contentWidth
    private static let overlaySideMargin: CGFloat = 12
    private static let overlayBottomInset: CGFloat = 8
    private static let overlayScrimAlpha: CGFloat = 0.45
    private static let contentHeightMessageName = "voiceboxContentHeight"
    private static let voiceboxEventMessageName = "voiceboxEvent"
    private static let bgColorMessageName = "voiceboxBgColor"

    /// Called on the main thread when JS detects the web page's background colour.
    /// The SwiftUI layer uses this to update `presentationBackground` dynamically
    /// so the home-indicator strip matches the page's actual colour.
    var onBackgroundColorDetected: ((UIColor) -> Void)?

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
        // Overlay mode paints nothing behind the shape: clear root + dimmed scrim.
        view.backgroundColor = isOverlay ? .clear : (voiceboxView.theme.backgroundColor ?? .systemBackground)
        if isOverlay { setupOverlayScrim() }
        setupWebView()
        setupCloseButton()
        setupSkeletonView()
        requestMicrophonePermission()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if isOverlay { slideInOverlayIfNeeded() }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if hasAppeared {
            voiceboxView.delegate?.voiceboxDidDismiss(voiceboxView)
        }
    }

    // MARK: - Setup

    private func setupWebView() {
        // Try to reuse a preloaded WebView for instant display
        if let preloaded = VoiceboxCache.shared.consumePreloadedWebView(for: voiceboxView.handle) {
            webView = preloaded
            usedPreloadedWebView = true
            // Apply visual settings that makeWebView() would normally set
            voiceboxView.applyWebViewSettings(webView)
        } else {
            webView = voiceboxView.makeWebView()
            usedPreloadedWebView = false
        }

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false

        if isOverlay {
            layoutWebViewForOverlay()
        } else {
            view.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: view.topAnchor),
                webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

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

        // Register message handlers
        webView.configuration.userContentController.add(self, name: Self.voiceboxEventMessageName)
        webView.configuration.userContentController.add(self, name: Self.bgColorMessageName)

        // Inject JS to observe recorder button clicks and postMessage events
        let eventScript = WKUserScript(
            source: """
            (function() {
                var handler = window.webkit.messageHandlers.\(Self.voiceboxEventMessageName);

                // Listen for postMessage events (works when embedded in iframe)
                window.addEventListener('message', function(event) {
                    if (!event.data || !event.data.type) return;
                    if (event.data.type === 'voicebox:recordingComplete') handler.postMessage('recordingComplete');
                    if (event.data.type === 'voicebox:messageSubmitted') handler.postMessage('messageSubmitted');
                });

                // Observe button clicks (works in direct WKWebView)
                var observed = { save: false, send: false };
                function attachListeners() {
                    // "Save" button — stops recording & uploads
                    var saveBtn = document.getElementById('record-btn-send');
                    if (saveBtn && !observed.save) {
                        observed.save = true;
                        saveBtn.addEventListener('click', function() {
                            handler.postMessage('recordingComplete');
                        });
                    }
                    // "Send" button — submits the edit form
                    var sendBtn = document.querySelector('[data-recorder--recorder-target="editSubmitButton"]');
                    if (sendBtn && !observed.send) {
                        observed.send = true;
                        sendBtn.addEventListener('click', function() {
                            handler.postMessage('messageSubmitted');
                        });
                    }
                }
                attachListeners();
                new MutationObserver(function() { attachListeners(); })
                    .observe(document.documentElement, { childList: true, subtree: true });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(eventScript)

        // fitContent + overlay both size to the web content height. Overlay
        // additionally receives *continuous* updates (the web streams height on
        // every ResizeObserver change) so the shape grows/shrinks from the bottom.
        if voiceboxView.presentationMode == .fitContent || isOverlay {
            webView.configuration.userContentController.add(
                self,
                name: Self.contentHeightMessageName
            )
            registeredContentHeightHandler = true
        }
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.voiceboxEventMessageName)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bgColorMessageName)
        if registeredContentHeightHandler {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.contentHeightMessageName)
        }
    }

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

        // Background — circular chip or transparent (nil background = transparent)
        if let bgColor = theme.closeButtonBackgroundColor {
            button.backgroundColor = bgColor
            button.layer.cornerRadius = buttonSize / 2
            button.clipsToBounds = true
        } else {
            button.backgroundColor = .clear
        }

        // Accessibility
        button.accessibilityLabel = "Close"
        button.accessibilityTraits = .button

        // In overlay mode pin the close button to the card (via the container),
        // and add it to `view` as a sibling above the container so the silhouette
        // hit-testing never swallows its taps.
        view.addSubview(button)
        if isOverlay, let container = overlayContainer {
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: container.topAnchor, constant: overlaySilhouette.cardTop + 8),
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                button.widthAnchor.constraint(equalToConstant: buttonSize),
                button.heightAnchor.constraint(equalToConstant: buttonSize),
            ])
        } else {
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                button.widthAnchor.constraint(equalToConstant: buttonSize),
                button.heightAnchor.constraint(equalToConstant: buttonSize),
            ])
        }

        self.closeButton = button
    }

    private func setupSkeletonView() {
        skeletonView = VoiceboxSkeletonView()
        skeletonView.translatesAutoresizingMaskIntoConstraints = false
        skeletonView.isHidden = true
        skeletonView.backgroundColor = voiceboxView.theme.resolvedBackgroundColor

        // Overlay: the skeleton lives inside the card container (not full-screen,
        // which would paint an opaque rectangle over the dimmed backdrop).
        if isOverlay, let container = overlayContainer {
            container.insertSubview(skeletonView, belowSubview: webView)
            NSLayoutConstraint.activate([
                skeletonView.topAnchor.constraint(equalTo: container.topAnchor),
                skeletonView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                skeletonView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                skeletonView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            return
        }

        view.addSubview(skeletonView)
        NSLayoutConstraint.activate([
            skeletonView.topAnchor.constraint(equalTo: view.topAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeletonView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Loading

    private func loadVoicebox() {
        if usedPreloadedWebView {
            let url = voiceboxView.buildURL()
            webView.load(URLRequest(url: url))
            return
        }

        let url = voiceboxView.buildURL()
        let cache = VoiceboxCache.shared

        if cache.hasCachedContent(for: voiceboxView.handle) {
            webView.load(URLRequest(url: url))
        } else if isNetworkAvailable() {
            skeletonView.startAnimating()
            webView.load(URLRequest(url: url))
        } else {
            showOfflineView()
        }
    }

    private func handleLoadingState(_ isLoading: Bool) {
        if isLoading {
            skeletonView.startAnimating()
        } else if isOverlay {
            // Nothing opaque to colour-match in overlay mode. Stop the skeleton
            // and take an initial height reading; the web then streams updates.
            skeletonView.stopAnimating()
            measureContentHeight()
        } else {
            if voiceboxView.theme.backgroundColor == nil {
                // Keep the skeleton visible while JS detects the page colour.
                // applyWebBackgroundColor() will stop it once the colour is set,
                // so there's no white-strip flash between skeleton fade-out and colour update.
                // Safety net: force-stop after 1 s in case detection never fires (JS error, etc.).
                detectWebBackgroundColor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.skeletonView.stopAnimating()
                }
            } else {
                skeletonView.stopAnimating()
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
            skeletonView.stopAnimating()
            return
        }
        view.backgroundColor = color
        // Notify the SwiftUI layer so it can update presentationBackground
        // to match — this closes the gap for the home-indicator strip at the bottom.
        onBackgroundColorDetected?(color)
        // Stop the skeleton now that the correct colour is in place.
        // The skeleton was kept visible in handleLoadingState to avoid a white-strip flash.
        skeletonView.stopAnimating()
    }

    // MARK: - Content Height (fitContent)

    private func measureContentHeight() {
        let js = """
        (function() {
            var height = Math.max(
                document.body.scrollHeight,
                document.body.offsetHeight,
                document.documentElement.scrollHeight,
                document.documentElement.offsetHeight
            );
            window.webkit.messageHandlers.\(Self.contentHeightMessageName).postMessage(height);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func updateSheetHeight(_ contentHeight: CGFloat) {
        guard let sheet = sheetPresentationController else { return }

        let safeAreaTop = view.safeAreaInsets.top
        let totalHeight = contentHeight + safeAreaTop + 20

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

    // MARK: - Overlay presentation (.overlay)

    private func setupOverlayScrim() {
        let scrim = UIView()
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0) // fades in on slide-up
        view.addSubview(scrim)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        scrim.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(overlayScrimTapped))
        )
        overlayScrim = scrim
    }

    private func layoutWebViewForOverlay() {
        let container = VoiceboxOverlayContainerView()
        container.silhouette = overlaySilhouette
        container.backgroundColor = .clear
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Card-width, centred, pinned above the home indicator. Height animates
        // from the reported content height; width clamps on narrow screens.
        let screenWidth = UIScreen.main.bounds.width
        let width = min(Self.overlayCardWidth, screenWidth - Self.overlaySideMargin * 2)
        let heightConstraint = container.heightAnchor.constraint(equalToConstant: 420)
        overlayHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -Self.overlayBottomInset
            ),
            heightConstraint,
        ])
        overlayContainer = container

        // Start off-screen until viewDidAppear slides it up.
        container.transform = CGAffineTransform(translationX: 0, y: 1000)

        container.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(handleOverlayPan(_:)))
        )
    }

    private func slideInOverlayIfNeeded() {
        guard let container = overlayContainer, !overlayDidSlideIn else { return }
        overlayDidSlideIn = true
        view.layoutIfNeeded()
        let offset = container.bounds.height + view.safeAreaInsets.bottom + Self.overlayBottomInset
        container.transform = CGAffineTransform(translationX: 0, y: offset)
        UIView.animate(
            withDuration: 0.38, delay: 0,
            usingSpringWithDamping: 0.9, initialSpringVelocity: 0.4,
            options: [.curveEaseOut]
        ) {
            container.transform = .identity
            self.overlayScrim?.backgroundColor = UIColor.black.withAlphaComponent(Self.overlayScrimAlpha)
        }
    }

    private func updateOverlayHeight(_ contentHeight: CGFloat) {
        guard let constraint = overlayHeightConstraint else { return }
        let available = view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - 24
        let target = min(max(contentHeight, 120), max(160, available))
        guard abs(constraint.constant - target) > 0.5 else { return }
        constraint.constant = target
        // Skip animating the very first sizing (still off-screen pre-slide-in).
        guard overlayDidSlideIn else { view.layoutIfNeeded(); return }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func overlayScrimTapped() {
        animateOverlayOutAndDismiss(velocity: 0)
    }

    @objc private func handleOverlayPan(_ recognizer: UIPanGestureRecognizer) {
        guard let container = overlayContainer else { return }
        let translationY = recognizer.translation(in: view).y

        switch recognizer.state {
        case .changed:
            let clamped = max(0, translationY)
            container.transform = CGAffineTransform(translationX: 0, y: clamped)
            let progress = min(1, clamped / max(1, container.bounds.height))
            overlayScrim?.backgroundColor =
                UIColor.black.withAlphaComponent(Self.overlayScrimAlpha * (1 - progress))
        case .ended, .cancelled:
            let velocityY = recognizer.velocity(in: view).y
            if translationY > container.bounds.height * 0.3 || velocityY > 800 {
                animateOverlayOutAndDismiss(velocity: velocityY)
            } else {
                UIView.animate(withDuration: 0.25) {
                    container.transform = .identity
                    self.overlayScrim?.backgroundColor =
                        UIColor.black.withAlphaComponent(Self.overlayScrimAlpha)
                }
            }
        default:
            break
        }
    }

    private func animateOverlayOutAndDismiss(velocity: CGFloat) {
        guard let container = overlayContainer else {
            dismiss(animated: true)
            return
        }
        let distance = container.bounds.height + view.safeAreaInsets.bottom + Self.overlayBottomInset
        UIView.animate(
            withDuration: 0.28, delay: 0, options: [.curveEaseIn],
            animations: {
                container.transform = CGAffineTransform(translationX: 0, y: distance)
                self.overlayScrim?.backgroundColor = UIColor.black.withAlphaComponent(0)
            },
            completion: { _ in
                self.dismiss(animated: false)
            }
        )
    }

    private func handleLoadError(_ error: Error) {
        skeletonView.stopAnimating()
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
        if isOverlay {
            animateOverlayOutAndDismiss(velocity: 0)
        } else {
            dismiss(animated: true)
        }
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
                default:
                    break
                }
            }

        case Self.contentHeightMessageName:
            let height = (message.body as? CGFloat) ?? CGFloat((message.body as? NSNumber)?.doubleValue ?? 0)
            if height > 0 {
                if isOverlay {
                    updateOverlayHeight(height)
                } else {
                    updateSheetHeight(height)
                }
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
