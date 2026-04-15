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
    private let session: URLSession

    /// Preloaded WebViews keyed by handle, ready for immediate display.
    private var preloadedWebViews: [String: WKWebView] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - UserDefaults Keys

    private func etagKey(for handle: String) -> String {
        "com.voiceboxkit.cache.etag.\(handle)"
    }

    private func lastModifiedKey(for handle: String) -> String {
        "com.voiceboxkit.cache.lastModified.\(handle)"
    }

    private func cachedKey(for handle: String) -> String {
        "com.voiceboxkit.cache.hasCachedContent.\(handle)"
    }

    // MARK: - Cache State

    /// Returns `true` if content has been previously loaded for this handle.
    func hasCachedContent(for handle: String) -> Bool {
        defaults.bool(forKey: cachedKey(for: handle))
    }

    private func markCached(handle: String) {
        defaults.set(true, forKey: cachedKey(for: handle))
    }

    // MARK: - Preloaded WebView

    /// Returns a preloaded WKWebView for the handle if available, removing it from the pool.
    /// After consuming, a new WebView is warmed in the background for next use.
    func consumePreloadedWebView(for handle: String) -> WKWebView? {
        guard let webView = preloadedWebViews.removeValue(forKey: handle) else {
            return nil
        }
        // Start warming a replacement in the background
        let url = URL(string: "\(VoiceboxKit.baseURL)/@\(handle)")!
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.warmWebViewCache(handle: handle, url: url)
        }
        return webView
    }

    /// Returns `true` if a preloaded WebView is ready for this handle.
    func hasPreloadedWebView(for handle: String) -> Bool {
        preloadedWebViews[handle] != nil
    }

    // MARK: - Preload

    /// Fetches and caches the Voicebox page for the given handle.
    ///
    /// Makes a full GET request, stores the ETag/Last-Modified for future
    /// validation, and creates a ready-to-use WKWebView. The WKWebView
    /// persistent data store handles the actual asset caching.
    func preload(handle: String) {
        let url = URL(string: "\(VoiceboxKit.baseURL)/@\(handle)")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self, error == nil, let httpResponse = response as? HTTPURLResponse else {
                return
            }

            // Store cache validators
            if let etag = httpResponse.value(forHTTPHeaderField: "ETag") {
                self.defaults.set(etag, forKey: self.etagKey(for: handle))
            }
            if let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified") {
                self.defaults.set(lastModified, forKey: self.lastModifiedKey(for: handle))
            }

            self.markCached(handle: handle)

            // Create a ready-to-use WKWebView with the content loaded
            DispatchQueue.main.async {
                self.warmWebViewCache(handle: handle, url: url)
            }
        }
        task.resume()

        // Also validate cache in parallel if we already have cached content
        if hasCachedContent(for: handle) {
            validateCache(handle: handle)

            // If we already have cached content, warm a WebView immediately
            // (it will load from the WKWebView disk cache)
            DispatchQueue.main.async { [weak self] in
                if self?.preloadedWebViews[handle] == nil {
                    self?.warmWebViewCache(handle: handle, url: url)
                }
            }
        }
    }

    // MARK: - Cache Validation

    /// Makes a HEAD request to check if the server content has changed.
    ///
    /// Compares ETag/Last-Modified from the response against stored values.
    /// If they differ, re-fetches the full content in the background.
    private func validateCache(handle: String) {
        let url = URL(string: "\(VoiceboxKit.baseURL)/@\(handle)")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self, error == nil, let httpResponse = response as? HTTPURLResponse else {
                return
            }

            let storedEtag = self.defaults.string(forKey: self.etagKey(for: handle))
            let storedLastModified = self.defaults.string(forKey: self.lastModifiedKey(for: handle))

            let serverEtag = httpResponse.value(forHTTPHeaderField: "ETag")
            let serverLastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")

            var isStale = false

            if let serverEtag, let storedEtag {
                isStale = serverEtag != storedEtag
            } else if let serverLastModified, let storedLastModified {
                isStale = serverLastModified != storedLastModified
            }

            if isStale {
                // Re-fetch in background
                self.refetch(handle: handle)
            }
        }
        task.resume()
    }

    /// Re-fetches the full content for a handle and updates cache validators.
    private func refetch(handle: String) {
        let url = URL(string: "\(VoiceboxKit.baseURL)/@\(handle)")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self, error == nil, let httpResponse = response as? HTTPURLResponse else {
                return
            }

            if let etag = httpResponse.value(forHTTPHeaderField: "ETag") {
                self.defaults.set(etag, forKey: self.etagKey(for: handle))
            }
            if let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified") {
                self.defaults.set(lastModified, forKey: self.lastModifiedKey(for: handle))
            }

            DispatchQueue.main.async {
                self.warmWebViewCache(handle: handle, url: url)
            }
        }
        task.resume()
    }

    // MARK: - WebView Cache Warming

    /// Creates a WKWebView, loads the URL, and stores it for reuse.
    private func warmWebViewCache(handle: String, url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))

        // Store as ready-to-use (replaces any existing one for this handle)
        preloadedWebViews[handle] = webView
    }
}
