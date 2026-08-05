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

    /// When `true`, injects CSS that hides ONLY the recorder page's own footer
    /// (the "Secure voicebox / Privacy / Terms" row). The page background is left
    /// intact, so a voicebox's configured background — image or colour — renders
    /// exactly as on the web and fills the sheet. (A voicebox with no configured
    /// background shows the page's own default background, not the sheet's.)
    /// Default is `false` (page renders exactly as vbx-web serves it).
    ///
    /// - Note: This is a client-side CSS injection scoped to VoiceboxKit's
    ///   WebView only — it does not change the page for any other embed
    ///   (desktop web, Android). It also depends on vbx-web's current DOM
    ///   structure (`#recorder-footer`, `#main`); if that markup changes,
    ///   this silently stops matching.
    public var hidePageChrome: Bool = false

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
    ///
    /// Uses the shared configuration (`VoiceboxWebScripts.makeConfiguration`) so a
    /// freshly-made WebView is wired identically to a warmed/preloaded one — same
    /// base scripts, event observers, process pool, and data store. The
    /// presentation-dependent chrome CSS is layered on by `applyWebViewSettings`.
    func makeWebView() -> WKWebView {
        let config = VoiceboxWebScripts.makeConfiguration()
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
        webView.configuration.userContentController.addUserScript(chromeUserScript())
    }

    /// Dim opacity for `.floatingCard`, or `nil` for every other presentation mode.
    private var floatingCardDim: Double? {
        if case .floatingCard(let dim) = presentationMode { return dim }
        return nil
    }

    /// The CSS applied to the recorder page — always disables text
    /// selection/context menus. In `.floatingCard` mode it also hides the footer,
    /// lets the card size to its content, dims the surrounding page, and centers
    /// the card in the viewport; otherwise, when ``hidePageChrome`` is `true`, it
    /// hides the footer only and leaves the page background untouched (so a
    /// configured image or colour shows through).
    private var chromeCSS: String {
        var css = "* { -webkit-user-select: none !important; -webkit-touch-callout: none !important; }"
        if floatingCardDim != nil {
            // Floating card: hide the footer, let the card be its natural height,
            // and vertically center it. Deliberately do NOT set a body/page
            // background — that would clobber the voicebox's configured background
            // image. The dim is applied natively behind the WebView instead
            // (VoiceboxViewController), so a background image shows at full
            // brightness while a transparent page still gets the dim.
            css += " #recorder-footer { display: none !important; }"
            css += " #recorder-card { height: auto !important; }"
            // Clear only the background COLOR (not background-image): a voicebox
            // with a configured image still shows it; one without falls back to a
            // transparent page, revealing the native dim — matching Android.
            css += " html, body, #main { background-color: transparent !important; }"
            css += " html, body { min-height: 100vh !important; margin: 0 !important; }"
            css += " #main { min-height: 100vh !important; display: flex !important; flex-direction: column !important; justify-content: center !important; }"
        } else if hidePageChrome {
            // Hide ONLY the footer; leave the page background untouched so a
            // voicebox's configured background — image OR colour — renders exactly
            // as on the web and fills the sheet. We deliberately do NOT clear the
            // background here: stripping `background-color` erases a configured page
            // colour (and the `background` shorthand would erase an image too),
            // leaving the sheet's clear/glass instead of what the voicebox set. A
            // voicebox with no configured background therefore shows the page's own
            // default background, not the sheet's.
            css += " #recorder-footer { display: none !important; }"
        }
        return css
    }

    /// JS that injects ``chromeCSS`` into a `<style>` tag under `<head>`. Shared
    /// by the user-script (future navigations) and the immediate-injection
    /// (already-loaded page) paths so both apply the exact same styling. In
    /// `.floatingCard` mode it also wires a tap-outside-the-card → dismiss bridge
    /// (the message name must match `VoiceboxViewController.voiceboxEventMessageName`).
    private var chromeInjectionJS: String {
        var js = """
        (function() {
            document.addEventListener('contextmenu', function(e) { e.preventDefault(); });
            document.addEventListener('long-press', function(e) { e.preventDefault(); });
            var existing = document.getElementById('voiceboxkit-chrome-style');
            var style = existing || document.createElement('style');
            style.id = 'voiceboxkit-chrome-style';
            style.textContent = '\(chromeCSS)';
            if (!existing) { document.head.appendChild(style); }
        """
        if floatingCardDim != nil {
            js += """

            if (!window.__vbxDismissBound) {
                window.__vbxDismissBound = true;
                document.addEventListener('click', function(e) {
                    var card = document.getElementById('recorder-card');
                    var logo = document.getElementById('voicebox-logo');
                    var inCard = card && card.contains(e.target);
                    var inLogo = logo && logo.contains(e.target);
                    if (!inCard && !inLogo && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.voiceboxEvent) {
                        window.webkit.messageHandlers.voiceboxEvent.postMessage('dismiss');
                    }
                });
            }
        """
        }
        js += "\n})();"
        return js
    }

    /// Builds the shared page-styling `WKUserScript` for the page's own load.
    private func chromeUserScript() -> WKUserScript {
        WKUserScript(source: chromeInjectionJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Immediately applies ``chromeCSS`` to a WebView whose page has ALREADY
    /// finished loading — the preloaded/warmed case. A `WKUserScript` only runs
    /// on the *next* navigation, so a reused preloaded WebView (whose page is
    /// already rendered) would otherwise never get the styling, making the
    /// chrome-hiding appear to work only intermittently (on fresh loads).
    /// `evaluateJavaScript` runs against the live DOM right now, closing that gap.
    func applyChromeCSSNow(to webView: WKWebView) {
        webView.evaluateJavaScript(chromeInjectionJS, completionHandler: nil)
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
        case .floatingCard:
            // Over the current context with a transparent container — the dim and
            // card layout are painted by the web page itself (see chromeCSS).
            // No UISheetPresentationController → no system glass/blur backdrop.
            vc.modalPresentationStyle = .overFullScreen
            vc.modalTransitionStyle = .crossDissolve
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
