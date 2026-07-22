import Foundation
import WebKit

/// Manages prefetching and cache validation for Voicebox handles.
///
/// On app launch, `preload(handle:)` fetches the full HTML/CSS/JS into the
/// WKWebView persistent cache and creates a ready-to-use WKWebView.
/// A lightweight HEAD request validates the cache on each launch using
/// ETag or Last-Modified headers.
final class VoiceboxCache {

    static let shared = VoiceboxCache()

    private let defaults = UserDefaults.standard

    /// A preloaded WebView paired with the exact URL it was warmed with, plus
    /// whether its background navigation actually finished successfully.
    ///
    /// `isReady`/`didFail` are updated by `WarmupObserver` — a temporary
    /// navigation delegate attached during warm-up, before the real consumer's
    /// delegate ever exists. Without tracking this explicitly, a preload that
    /// silently failed in the background (before anyone was watching) would be
    /// indistinguishable from a real success once consumed, and the consumer
    /// would treat a blank/errored WebView as loaded.
    private struct PreloadedEntry {
        let webView: WKWebView
        let url: URL
        let observer: WarmupObserver
        var isReady = false
        var didFail = false
    }

    /// Bridges WKWebView's navigation callbacks back into `PreloadedEntry`
    /// state during warm-up. `WKWebView.navigationDelegate` is `weak`, so this
    /// must be retained elsewhere (it lives inside `PreloadedEntry`) or it's
    /// deallocated immediately and no callback ever fires.
    private final class WarmupObserver: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        var onFail: (() -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish?()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFail?()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onFail?()
        }
    }

    /// Preloaded WebViews keyed by handle, ready for immediate display.
    private var preloadedWebViews: [String: PreloadedEntry] = [:]

    private init() {}

    // MARK: - UserDefaults Keys

    private func cachedKey(for handle: String) -> String {
        "com.voiceboxkit.cache.hasCachedContent.\(handle)"
    }

    private func contentHeightKey(for handle: String) -> String {
        "com.voiceboxkit.cache.contentHeight.\(handle)"
    }

    // MARK: - Cache State

    /// Returns `true` if content has been previously loaded for this handle.
    func hasCachedContent(for handle: String) -> Bool {
        defaults.bool(forKey: cachedKey(for: handle))
    }

    private func markCached(handle: String) {
        defaults.set(true, forKey: cachedKey(for: handle))
    }

    /// The sheet height measured the last time `.fitContent` finished loading
    /// this handle (see `VoiceboxViewController.updateSheetHeight`), if any.
    ///
    /// Used only as the STARTING detent for the next open, so a fresh/slow load
    /// doesn't have to flash full-screen (`.large`) before shrinking down —
    /// the real height is always re-measured after load and corrects this guess.
    func cachedContentHeight(for handle: String) -> CGFloat? {
        let value = defaults.double(forKey: contentHeightKey(for: handle))
        return value > 0 ? CGFloat(value) : nil
    }

    /// Persists the measured sheet height for this handle for next time.
    func setCachedContentHeight(_ height: CGFloat, for handle: String) {
        defaults.set(Double(height), forKey: contentHeightKey(for: handle))
    }

    // MARK: - Preloaded WebView

    /// Returns a preloaded WKWebView for the handle, but ONLY if it was warmed
    /// with the exact same URL being requested AND its background navigation
    /// already finished successfully — removes it from the pool on a hit.
    ///
    /// Returns `nil` (leaving the pool untouched) when: there's no entry, the
    /// URL doesn't match, the warm-up is still in flight, or it failed. Every
    /// one of those cases means the caller must fall back to a fresh load —
    /// this never hands back a WebView the caller can't trust is actually
    /// showing the requested content.
    func consumePreloadedWebView(for handle: String, matching url: URL) -> WKWebView? {
        guard let entry = preloadedWebViews[handle],
              entry.url == url,
              entry.isReady,
              !entry.didFail
        else {
            return nil
        }
        preloadedWebViews.removeValue(forKey: handle)
        // Start warming a replacement in the background
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.warmWebViewCache(handle: handle, url: url)
        }
        return entry.webView
    }

    /// Returns `true` if a preloaded WebView has finished loading successfully
    /// for this handle (any URL — for a URL-specific check use
    /// `consumePreloadedWebView`, which is the only place that should actually
    /// hand the WebView out).
    func hasPreloadedWebView(for handle: String) -> Bool {
        preloadedWebViews[handle]?.isReady == true
    }

    // MARK: - Preload

    /// Warms and caches the Voicebox page for the given handle + params.
    ///
    /// A single `WKWebView` load populates the persistent data store and creates
    /// a ready-to-use WebView — no separate `URLSession` fetch. The WebView load
    /// uses the default cache policy, so a repeat warm is served from the HTTP
    /// cache and revalidated per the server's cache headers, which is what makes
    /// re-opens fast.
    ///
    /// - Important: `params` must match what the sheet will be opened with —
    ///   the URL built here (via `VoiceboxURLBuilder`) is the exact cache key
    ///   `consumePreloadedWebView(for:matching:)` checks against.
    func preload(handle: String, params: [String: String] = [:]) {
        let url = VoiceboxURLBuilder.build(handle: handle, params: params)
        // WebView creation must be on the main thread; `preload` may be called
        // from anywhere. Skip if a warm for this exact URL is already in flight
        // or ready, so repeated preloads (appear + prompt-change + foreground)
        // don't churn WebViews.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let existing = self.preloadedWebViews[handle], existing.url == url { return }
            self.warmWebViewCache(handle: handle, url: url)
        }
    }

    // MARK: - WebView Cache Warming

    /// Creates a WKWebView, loads the URL, and stores it for reuse — NOT
    /// immediately usable; `isReady` flips to `true` only once the observer
    /// below sees the navigation actually finish. Until then (or if it fails)
    /// `consumePreloadedWebView` won't hand it out.
    private func warmWebViewCache(handle: String, url: URL) {
        // Same configuration a live WebView gets (shared scripts + process pool +
        // data store), so the warmed page has the recorder event observers etc.
        // already active and is byte-for-byte reusable when adopted.
        let config = VoiceboxWebScripts.makeConfiguration()

        let webView = WKWebView(frame: .zero, configuration: config)
        let observer = WarmupObserver()
        webView.navigationDelegate = observer

        // Guard against a stale callback: if this handle's entry was replaced
        // (e.g. preload() called again before this one finished), only mutate
        // it if it's still THIS webview's entry.
        observer.onFinish = { [weak self, weak webView] in
            guard let self, let webView, self.preloadedWebViews[handle]?.webView === webView else { return }
            self.preloadedWebViews[handle]?.isReady = true
            // Mark cached only once a warm has actually succeeded, so
            // `hasCachedContent` (which suppresses the loading skeleton on a
            // cache-first open) can't be true before anything is really cached.
            self.markCached(handle: handle)
        }
        observer.onFail = { [weak self, weak webView] in
            guard let self, let webView, self.preloadedWebViews[handle]?.webView === webView else { return }
            self.preloadedWebViews[handle]?.didFail = true
        }

        webView.load(URLRequest(url: url))

        // Store as ready-to-use (replaces any existing one for this handle)
        preloadedWebViews[handle] = PreloadedEntry(webView: webView, url: url, observer: observer)
    }
}
