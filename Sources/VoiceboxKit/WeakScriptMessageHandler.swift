import WebKit

/// Forwards script messages to a target it holds WEAKLY.
///
/// `WKUserContentController.add(_:name:)` retains its handler strongly, and the content
/// controller belongs to the WebView's configuration. So a view controller that holds its
/// WebView and registers ITSELF as a handler is a retain cycle:
/// controller → WebView → configuration → content controller → controller.
///
/// That cycle is what kept every recorder ever opened alive after it closed: the
/// `VoiceboxViewController`, its `WKWebView`, and the page's WebContent process, with the
/// page still running JavaScript. The only place the handlers were removed was `deinit`,
/// which the cycle stopped from ever running. Registering this proxy instead leaves the
/// content controller holding the proxy and nothing more, so the controller lives exactly as
/// long as whoever presented it keeps it.
///
/// A message that arrives after the target has gone is dropped.
final class WeakScriptMessageHandler: NSObject {

    /// Where messages are forwarded. Weak by design — see the type's documentation.
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }
}

extension WeakScriptMessageHandler: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
