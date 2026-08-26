import Foundation
import WebKit

/// Loads a host-supplied session URL in an off-screen WebView, so the cookie it sets lands
/// in the same storage every recorder WebView reads from.
///
/// Why a navigation at all: only the server can mint a session cookie, via `Set-Cookie` on
/// a real response. There is nothing to inject — the value does not exist until something
/// asks for it — so the cookie has to be *earned* by loading the URL.
///
/// Why OFF-SCREEN rather than as the recorder's own first navigation: the recorder's
/// `VoiceboxNavigationDelegate` cancels any main-frame navigation before its first load
/// completes that is not this handle's recorder page, and reports the handle as
/// unavailable. That guard is load-bearing — vbx-web answers an unknown handle with a
/// redirect to the directory, which would otherwise render the public directory inside a
/// recorder sheet. Entering on a session URL trips it. Priming in a separate WebView with
/// no such delegate leaves both behaviours intact.
///
/// The WebView is retained only for the duration of the load: a `WKWebView` deallocated
/// mid-navigation simply stops, and its delegate callbacks never arrive.
final class SessionPrimer: NSObject {

    static let shared = SessionPrimer()

    /// The maximum a prime may take before it is abandoned.
    ///
    /// A wall clock rather than trusting the navigation to end, because it is not always
    /// the network that stalls — a redirect chain that never terminates finishes no
    /// navigation and fires no error. The value matters little: priming is best-effort and
    /// the host is told not to block on it, so a slow one costs nothing but a late `false`.
    private static let timeout: TimeInterval = 20

    private var webView: WKWebView?
    private var completion: ((Bool) -> Void)?
    private var timeoutWork: DispatchWorkItem?

    /// - Parameter completion: Always called, exactly once, on the main queue.
    func load(_ url: URL, completion: @escaping (Bool) -> Void) {
        // A second prime while one is in flight abandons the first. The token in that URL
        // is single-use and already spent or spending, so there is nothing to preserve —
        // and letting them race would leave two WebViews writing the same cookie jar.
        finish(false)

        self.completion = completion

        // The SHARED configuration, so the cookie lands in the same store the recorder
        // reads. A default-initialised WKWebViewConfiguration would use its own and prime
        // nothing that matters.
        let webView = WKWebView(frame: .zero, configuration: VoiceboxWebScripts.makeConfiguration())
        webView.navigationDelegate = self
        self.webView = webView

        let work = DispatchWorkItem { [weak self] in
            VoiceboxLog.debug("session", "prime timed out after \(Self.timeout)s")
            self?.finish(false)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: work)

        webView.load(URLRequest(url: url))
    }

    /// Idempotent by construction: the completion is taken before it is called, so the
    /// timeout firing alongside a navigation callback cannot report twice.
    private func finish(_ success: Bool) {
        timeoutWork?.cancel()
        timeoutWork = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        guard let completion else { return }
        self.completion = nil
        completion(success)
    }
}

extension SessionPrimer: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The cookie is set by the response's Set-Cookie header, which WebKit has already
        // stored by the time the navigation it belongs to finishes — including across the
        // redirect the session URL performs. Reaching here at all is the success signal;
        // the page's own content is not inspected, so a host can point this anywhere.
        finish(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        VoiceboxLog.debug("session", "prime failed: \(error.localizedDescription)")
        finish(false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        VoiceboxLog.debug("session", "prime failed before loading: \(error.localizedDescription)")
        finish(false)
    }
}
