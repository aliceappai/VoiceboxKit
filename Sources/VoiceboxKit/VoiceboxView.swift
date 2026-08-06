import UIKit
import WebKit

/// The primary interface for presenting a Voicebox recording experience.
///
/// Create a `VoiceboxView` with a handle and optional params, then present it
/// using one of the built-in presentation methods.
///
/// ```swift
/// let vb = VoiceboxView(handle: "alice-feedback")
/// vb.presentAsSheet(from: self)
/// ```
public final class VoiceboxView {

    /// The Voicebox handle (required).
    public let handle: String

    /// Query parameters appended to the Voicebox URL.
    public let params: [String: String]

    /// Visual theme for the presentation.
    public var theme: VoiceboxTheme

    /// How the Voicebox view is presented. Default is `.bottomSheet`.
    public var presentationMode: VoiceboxPresentationMode = .bottomSheet

    /// Whether to show the close button. Default is `true`.
    public var showCloseButton: Bool = true

    /// Delegate for receiving lifecycle events (recording complete, dismiss, error).
    public weak var delegate: VoiceboxDelegate?

    /// Per-instance override for mic permission handling.
    /// - `nil` — uses the global `VoiceboxKit.autoGrantMicPermission` value.
    /// - `true` — auto-grant WebView mic permission (app already has native mic access).
    /// - `false` — let the WebView show its own permission prompt.
    public var autoGrantMicPermission: Bool?

    /// Resolved mic permission setting (instance override > global default).
    var effectiveAutoGrantMicPermission: Bool {
        autoGrantMicPermission ?? VoiceboxKit.autoGrantMicPermission
    }

    /// Per-instance override for keeping the screen awake while this Voicebox is shown.
    /// - `nil` — uses the global `VoiceboxKit.keepsScreenAwake` value.
    /// - `true` — hold the idle timer open while this Voicebox is on screen.
    /// - `false` — leave auto-lock alone (the recording is lost if the device locks).
    public var keepsScreenAwake: Bool?

    /// Resolved screen-awake setting (instance override > global default).
    var effectiveKeepsScreenAwake: Bool {
        keepsScreenAwake ?? VoiceboxKit.keepsScreenAwake
    }

    // MARK: - Init

    /// Creates a VoiceboxView for the given handle.
    ///
    /// - Parameters:
    ///   - handle: The Voicebox handle. **Required.**
    ///   - params: Key-value pairs appended as query parameters.
    ///   - theme: Visual theme. Uses defaults if omitted.
    public init(
        handle: String,
        params: [String: String] = [:],
        theme: VoiceboxTheme = VoiceboxTheme()
    ) {
        self.handle = handle
        self.params = params
        self.theme = theme
    }

    // MARK: - URL Construction

    /// Builds the full Voicebox URL with params and UTM tags.
    ///
    /// Delegates to `VoiceboxURLBuilder` so this always matches whatever
    /// `VoiceboxCache.preload(handle:params:)` warmed for the same handle + params.
    func buildURL() -> URL {
        VoiceboxURLBuilder.build(handle: handle, params: params)
    }

    // MARK: - WebView Factory

    /// Creates a configured WKWebView for the Voicebox experience.
    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()

        // Media playback
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Persistent cache
        config.websiteDataStore = .default()

        // Disable context menus and text selection via JS
        let disableScript = WKUserScript(
            source: """
            document.addEventListener('contextmenu', function(e) { e.preventDefault(); });
            document.addEventListener('long-press', function(e) { e.preventDefault(); });
            var style = document.createElement('style');
            style.textContent = '* { -webkit-user-select: none !important; -webkit-touch-callout: none !important; }';
            document.head.appendChild(style);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(disableScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        applyWebViewSettings(webView)

        return webView
    }

    /// Applies visual settings and user agent to a WKWebView.
    ///
    /// Used both by ``makeWebView()`` and when configuring a preloaded WebView
    /// that was created by `VoiceboxCache`.
    func applyWebViewSettings(_ webView: WKWebView) {
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = theme.resolvedBackgroundColor

        // Custom User-Agent
        let iosVersion = UIDevice.current.systemVersion
        webView.customUserAgent = "VoiceboxKit/\(VoiceboxKit.version) iOS/\(iosVersion)"

        // Inject context menu/text selection disable script if not already present
        let disableScript = WKUserScript(
            source: """
            document.addEventListener('contextmenu', function(e) { e.preventDefault(); });
            document.addEventListener('long-press', function(e) { e.preventDefault(); });
            var style = document.createElement('style');
            style.textContent = '* { -webkit-user-select: none !important; -webkit-touch-callout: none !important; }';
            document.head.appendChild(style);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(disableScript)
    }

    // MARK: - Presentation

    /// Present the Voicebox view using the configured ``presentationMode``.
    ///
    /// - Parameter viewController: The presenting view controller.
    public func present(from viewController: UIViewController) {
        let vc = VoiceboxViewController(voiceboxView: self)

        switch presentationMode {
        case .fullScreen:
            vc.modalPresentationStyle = .fullScreen
        case .bottomSheet:
            vc.modalPresentationStyle = .pageSheet
            if let sheet = vc.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = theme.resolvedCornerRadius
            }
        case .sheet:
            vc.modalPresentationStyle = .pageSheet
            if let sheet = vc.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = theme.resolvedCornerRadius
            }
        case .fitContent:
            vc.modalPresentationStyle = .pageSheet
            if let sheet = vc.sheetPresentationController {
                // Start at large; VoiceboxViewController will update to
                // a custom detent once it measures the web content height.
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = theme.resolvedCornerRadius
            }
        case .custom(let height):
            vc.modalPresentationStyle = .pageSheet
            if let sheet = vc.sheetPresentationController {
                if #available(iOS 16.0, *) {
                    let detent = UISheetPresentationController.Detent.custom(
                        identifier: .init("voicebox.custom.\(Int(height))")
                    ) { _ in
                        return height
                    }
                    sheet.detents = [detent]
                } else {
                    // iOS 15 fallback
                    sheet.detents = [.large()]
                }
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = theme.resolvedCornerRadius
            }
        case .customFraction(let fraction):
            vc.modalPresentationStyle = .pageSheet
            let clamped = max(0.1, min(1.0, fraction))
            if let sheet = vc.sheetPresentationController {
                if #available(iOS 16.0, *) {
                    let detent = UISheetPresentationController.Detent.custom(
                        identifier: .init("voicebox.fraction.\(Int(clamped * 100))")
                    ) { context in
                        return context.maximumDetentValue * clamped
                    }
                    sheet.detents = [detent]
                } else {
                    // iOS 15 fallback
                    sheet.detents = [.large()]
                }
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = theme.resolvedCornerRadius
            }
        }

        viewController.present(vc, animated: true)
    }

    /// Convenience: present as a bottom sheet (medium + large detents).
    public func presentAsSheet(from viewController: UIViewController) {
        presentationMode = .bottomSheet
        present(from: viewController)
    }

    /// Convenience: present as a full-screen modal.
    public func presentFullScreen(from viewController: UIViewController) {
        presentationMode = .fullScreen
        present(from: viewController)
    }
}
