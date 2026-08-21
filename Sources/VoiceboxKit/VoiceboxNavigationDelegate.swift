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
    /// Fired when the INITIAL load is redirected off this handle's recorder page, i.e. the
    /// handle doesn't resolve server-side. Carries the destination we refused to show.
    var onHandleUnavailable: ((URL) -> Void)?

    /// Whether a load has completed for this delegate yet. The unavailable-handle guard in
    /// `decidePolicyFor` only applies BEFORE that: once the recorder is up, whatever it
    /// navigates to next is the recorder's own business and must not be second-guessed.
    private var hasCompletedFirstLoad = false

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

            // The handle didn't resolve: vbx-web 303s an unknown /@handle to the directory
            // root, carrying the query string over, so this looks like an ordinary allowed
            // navigation. Letting it through renders the public DIRECTORY BROWSE PAGE inside
            // the recorder sheet — which is what a user sees as "it opened the wrong thing".
            //
            // Only before the first completed load, and only for the main frame: after the
            // recorder is up, its own navigations are none of our business.
            if !hasCompletedFirstLoad,
               navigationAction.targetFrame?.isMainFrame ?? true,
               !VoiceboxURLBuilder.isRecorderPath(url, handle: handle) {
                decisionHandler(.cancel)
                onHandleUnavailable?(url)
                return
            }

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
        hasCompletedFirstLoad = true
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
