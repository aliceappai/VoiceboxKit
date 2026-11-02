import Foundation
import WebKit

/// Unloads a dismissed recorder's page the way closing a browser tab would, and keeps its
/// WebView alive until that has happened.
///
/// Why this exists: the recorder page tells the server it has been left with a `sendBeacon`
/// from its `pagehide` listener (vbx-web `app/javascript/recorder/chunked_capture.js`,
/// `persisted: false`). The server then merges an unfinished take within ~30 s instead of
/// leaving it `capturing` until its sweeper runs ~30 min later (vbx-web `docs/RECORDER.md`,
/// "When the visitor does not finish"). Releasing a `WKWebView` is not a navigation, so it
/// is not a dependable way to get that event; navigating the main frame off the page is.
///
/// Why `about:blank`: it is a real main-frame navigation, so the outgoing document gets its
/// `pagehide`; it stays in the same WebContent process, so the page that receives the event
/// is the one that was recording; it needs no network; and `VoiceboxNavigationDelegate`
/// would allow it anyway.
///
/// Why the WebView is HELD here: the controller that owned it is usually released straight
/// after dismissal, and a `WKWebView` deallocated before the blank navigation commits takes
/// the page down with no navigation at all. The beacon itself is handed to the network
/// process from inside `pagehide`, so once the blank document has finished loading there is
/// nothing left to wait for. A wall clock bounds the hold in case that never comes.
///
/// - Note: WebKit decides whether a page goes into its back/forward cache, and a cached page
///   gets `pagehide` with `persisted: true`, on which vbx-web deliberately sends nothing —
///   the same outcome as a browser that caches the tab.
final class VoiceboxPageUnloader: NSObject {

    static let shared = VoiceboxPageUnloader()

    /// The longest a WebView is held waiting for its blank navigation. Generous on purpose:
    /// the navigation is local and normally finishes in milliseconds, and holding a little
    /// longer only delays freeing a WebView that is already off screen.
    private static let timeout: TimeInterval = 5

    private static let blankURL = URL(string: "about:blank")!

    /// WebViews being unloaded, with the blank navigation each is waiting on. Keyed by the
    /// WebView's identity; the entry is what keeps the WebView alive. `hold` tells one unload
    /// of a WebView from a later one, so an earlier unload's timeout cannot end it.
    private var unloading: [ObjectIdentifier: (webView: WKWebView, navigation: WKNavigation?, hold: Int)] = [:]
    private var nextHold = 0

    /// Navigates `webView` off its page and holds it until that navigation ends.
    ///
    /// Takes over the WebView's navigation delegate, so the blank navigation's callbacks never
    /// reach the recorder's own delegate — which would otherwise treat `about:blank` as a
    /// recorder load (and, in `.fitContent`, measure and cache its height). Idempotent.
    func unload(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard unloading[key] == nil else { return }

        nextHold += 1
        let hold = nextHold
        webView.navigationDelegate = self
        let navigation = webView.load(URLRequest(url: Self.blankURL))
        unloading[key] = (webView: webView, navigation: navigation, hold: hold)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self, weak webView] in
            guard let self, let webView, self.unloading[key]?.hold == hold else { return }
            self.release(webView)
        }
    }

    /// Stops holding `webView` and gives up its navigation delegate. Also how a controller
    /// that is shown again takes its WebView back. No-op for a WebView that is not held.
    func release(_ webView: WKWebView) {
        guard unloading.removeValue(forKey: ObjectIdentifier(webView)) != nil else { return }
        if webView.navigationDelegate === self {
            webView.navigationDelegate = nil
        }
    }

    /// Ends the hold when the callback is for the blank navigation itself. The navigation it
    /// replaced (a recorder load still in flight when the sheet closed) reports its own
    /// cancellation to this delegate too, and must not end the hold before the blank page
    /// has committed.
    private func finish(_ webView: WKWebView, navigation: WKNavigation?) {
        guard let entry = unloading[ObjectIdentifier(webView)] else { return }
        if let expected = entry.navigation, expected !== navigation { return }
        release(webView)
    }
}

extension VoiceboxPageUnloader: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(webView, navigation: navigation)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(webView, navigation: navigation)
    }
}
