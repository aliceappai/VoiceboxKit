import WebKit

/// Restricts WebView navigation to the Voicebox recording flow only.
///
/// Any link tap that would navigate away from `vbx.to` is intercepted and
/// cancelled. Nothing opens Safari.
final class VoiceboxNavigationDelegate: NSObject, WKNavigationDelegate {

    private let handle: String
    var onLoadingStateChanged: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    /// Fallback: fired when URL navigates to a path containing `/sent/`.
    var onMessageSubmitted: (() -> Void)?

    init(handle: String) {
        self.handle = handle
        super.init()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Allow the configured baseURL host plus production Voicebox domains.
        let configuredHost = URL(string: VoiceboxKit.baseURL)?.host
        if let host = url.host,
           host.hasSuffix("vbx.to")
            || host.hasSuffix("voicebox.ai")
            || (configuredHost.map { host == $0 || host.hasSuffix(".\($0)") } ?? false) {

            // Fallback: detect navigation to /sent/ URL pattern
            if url.path.contains("/sent/") {
                onMessageSubmitted?()
            }

            decisionHandler(.allow)
            return
        }

        // Allow about:blank and data URIs used internally by the WebView
        if url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" {
            decisionHandler(.allow)
            return
        }

        // Block everything else
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onLoadingStateChanged?(true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoadingStateChanged?(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onLoadingStateChanged?(false)
        onError?(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLoadingStateChanged?(false)
        onError?(error)
    }
}
