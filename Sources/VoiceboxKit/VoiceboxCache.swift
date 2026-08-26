import Foundation
import UIKit
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
        /// Handle being warmed. Load-bearing: the redirect check below compares the
        /// destination against THIS handle's recorder path.
        var handle: String = "-"

        /// vbx-web 303s an unknown /@handle to the directory root, and the warm is where most
        /// recorder loads happen — so a dead handle surfaces here first.
        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            let destination = webView.url
            let stillRecorder = destination.map { VoiceboxURLBuilder.isRecorderPath($0, handle: handle) } ?? true

            guard stillRecorder else {
                // Redirected off this handle's page entirely — vbx-web does this (303) when the
                // handle doesn't resolve. Failing the warm is essential: otherwise it finishes
                // "successfully" holding the DIRECTORY page, `consumePreloadedWebView` hands
                // that out as a hit, and the recorder sheet opens straight onto the browse page
                // with no load and no error.
                onFail?()
                return
            }
        }

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

    /// The params each handle was last warmed with, so ``resetWarmedWebViews()`` can put the
    /// pool back exactly as it found it. Kept separately from ``preloadedWebViews`` because
    /// that entry stores only the built URL, and picking params back out of a URL means
    /// re-deriving what ``VoiceboxURLBuilder`` merged in (app context, UTM tags) — a guess
    /// that would silently warm a different URL than the sheet later asks for.
    private var warmParams: [String: [String: String]] = [:]

    /// Handles in warm order, oldest first — the eviction order for ``maxWarmedWebViews``.
    /// A plain array (not an ordered dictionary) because this holds a handful of entries
    /// at most and every operation here is already O(n) over that handful.
    private var warmOrder: [String] = []

    /// How many warmed WebViews may be held at once.
    ///
    /// Each entry retains a live `WKWebView`, which is a whole WebContent process — tens of
    /// MB apiece. Callers that warm from a LIST (the Directory's card list and map, where the
    /// handle is only known from what the user is looking at) would otherwise grow this pool
    /// without limit as the user browses.
    ///
    /// Four is the host's realistic concurrent working set: the voicebox currently open, the
    /// in-app feedback handle, and a Directory candidate from EACH of its two surfaces (the
    /// card list and the map warm independently). Sized at three, the oldest — usually the
    /// feedback handle — was evicted as soon as someone browsed the Directory, so opening
    /// Help went from instant to a full load.
    ///
    /// Evicting is cheap and safe — a miss just falls back to a normal load.
    private static let maxWarmedWebViews = 4

    /// An idle, already-constructed `WKWebView` kept ready for a handle we could NOT predict.
    ///
    /// The preload pool only helps handles someone thought to warm. The Directory's whole
    /// problem is the opposite: any of hundreds of pins can be tapped, and the handle isn't
    /// known until the tap. Measurements showed 0.6–3.2 s of every such open going to work
    /// done BEFORE the network was touched — dominated by constructing a `WKWebView` and
    /// launching its WebContent process.
    ///
    /// That cost is entirely handle-independent, so it can be paid in advance ONCE and reused
    /// by every unpredicted open. The spare loads `about:blank` only: enough to force the
    /// process to launch, with no network request and nothing to go stale.
    private var hotSpare: WKWebView?

    /// Absorbs the spare's own `about:blank` navigation callbacks while it sits idle.
    ///
    /// `WKWebView.navigationDelegate` is weak, so without holding this the spare would have
    /// no delegate and the blank load's `didFinish` could land on the VIEW CONTROLLER's
    /// delegate once it adopts the spare — which would mark the recorder "loaded" before it
    /// had loaded anything, log a bogus ready time, and switch off the unavailable-handle
    /// guard (which only applies before the first completed load).
    private var hotSpareObserver: WarmupObserver?

    /// Whether the host has actually used the SDK yet. The spare costs a WebContent process
    /// (tens of MB), so an app that never opens a recorder must never be charged for one — it
    /// is created only after a real preload or a real open, never at import time.
    private var hasBeenUsed = false

    private init() {
        // The spare is a pure cache: drop it whenever the system or the user's own behaviour
        // says holding a spare process is the wrong trade. It is rebuilt lazily on the next
        // preload/open, so losing it only ever costs the spin-up we were trying to avoid.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(releaseHotSpare),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(releaseHotSpare),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    // MARK: - Hot spare

    /// Builds the spare if the SDK is in use and there isn't one already. Cheap and idempotent.
    func prepareHotSpareIfNeeded() {
        guard hasBeenUsed, hotSpare == nil else { return }

        let webView = WKWebView(frame: .zero, configuration: VoiceboxWebScripts.makeConfiguration())
        let observer = WarmupObserver()
        observer.handle = "hotSpare"
        webView.navigationDelegate = observer
        hotSpareObserver = observer
        // Forces the WebContent process to actually launch — an untouched WKWebView may defer
        // that until its first real load, which would leave the cost exactly where we are
        // trying to remove it from. Empty local content, so this costs no network.
        webView.loadHTMLString("", baseURL: nil)
        hotSpare = webView
    }

    /// Hands over the spare (if any) and immediately starts building its replacement, so the
    /// open after this one is just as cheap. Returns nil when no spare is ready.
    func takeHotSpare() -> WKWebView? {
        hasBeenUsed = true
        guard let spare = hotSpare else {
            // Deferred, NOT inline: building the spare here would put a second WebView
            // construction on the very open we already failed to spare, making this path
            // slower than having no spare mechanism at all.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.prepareHotSpareIfNeeded()
            }
            return nil
        }
        hotSpare = nil
        hotSpareObserver = nil
        // Next runloop, not now: building the replacement competes with the load we are about
        // to start, and the replacement is for a tap that hasn't happened yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.prepareHotSpareIfNeeded()
        }
        return spare
    }

    @objc private func releaseHotSpare() {
        guard hotSpare != nil else { return }
        hotSpare = nil
        hotSpareObserver = nil
    }

    /// Drops every warmed / preloaded WebView and the hot spare, then warms the same
    /// handles again from scratch.
    ///
    /// Called by both session methods on ``VoiceboxKit``, and the dropping half is
    /// required rather than tidy: a warmed WebView holds an already-LOADED recorder
    /// document. Its JavaScript still has the old anonymous id in memory, and vbx-web's
    /// `ensureProfilesSessionId()` writes whatever it holds back to storage the next time
    /// it runs — so emptying the data store without dropping those pages lets one of them
    /// resurrect the id that was just removed. A page loaded before a session was
    /// established is stale in the same way: it rendered signed-out and will keep saying so.
    ///
    /// Re-warming is deliberately NOT the host's job. The pool is an SDK internal — only
    /// this class knows what is in it — so a host asked to replay its own preloads would
    /// have to track them separately and remember to do it, a contract that is silently
    /// wrong the first time somebody forgets. Warming is best-effort anyway: a miss just
    /// falls back to a normal load.
    func resetWarmedWebViews() {
        let toRewarm = warmParams

        preloadedWebViews.removeAll()
        warmOrder.removeAll()
        warmParams.removeAll()
        releaseHotSpare()

        for (handle, params) in toRewarm {
            preload(handle: handle, params: params)
        }
    }

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

    /// What ``consumePreloadedWebView(for:matching:)`` found for this exact URL.
    enum Adoption {
        /// Warm finished successfully — the page is rendered, show it immediately.
        case ready(WKWebView)
        /// Warm is still in flight for this exact URL. The WebView is handed over anyway so
        /// the caller can wait for the load already running instead of starting a second,
        /// competing one for the same page — which is what used to happen, and it made the
        /// open SLOWER than doing nothing (two loads sharing the bandwidth, the finished
        /// warm then thrown away).
        case warming(WKWebView)
    }

    /// Adopts the preloaded WebView for this handle when it was warmed with the exact same
    /// URL — as ``Adoption/ready(_:)`` if its navigation already finished, or
    /// ``Adoption/warming(_:)`` if that navigation is still running. Removes it from the
    /// pool either way.
    ///
    /// Returns `nil` (leaving the pool untouched) when there's no entry, the URL doesn't
    /// match, or the warm failed — the caller must then do a normal load. This never hands
    /// back a WebView showing content other than the requested URL.
    func consumePreloadedWebView(for handle: String, matching url: URL) -> Adoption? {
        guard let entry = preloadedWebViews[handle],
              entry.url == url,
              !entry.didFail
        else {
            // A miss is the whole reason an open is slow, and the causes need very different
            // fixes (never warmed / params drifted / the warm itself failed), so name which
            // one it was rather than just "miss".
            return nil
        }
        if entry.isReady {
        } else {
        }
        preloadedWebViews.removeValue(forKey: handle)
        warmOrder.removeAll { $0 == handle }
        // Also drop the warm PARAMS: this handle is being adopted for display, so it is no
        // longer part of the pool, and ``resetWarmedWebViews()`` restoring it would warm a
        // second copy of a page that is already on screen. The host re-preloads on its next
        // appear, as it does today.
        warmParams.removeValue(forKey: handle)
        // Start warming a replacement in the background
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.warmWebViewCache(handle: handle, url: url)
        }
        return entry.isReady ? .ready(entry.webView) : .warming(entry.webView)
    }

    /// Returns `true` if a preloaded WebView has finished loading successfully
    /// for this handle (any URL — for a URL-specific check use
    /// `consumePreloadedWebView`, which is the only place that should actually
    /// hand the WebView out).
    func hasPreloadedWebView(for handle: String) -> Bool {
        preloadedWebViews[handle]?.isReady == true
    }

    /// Whether a warm for `handle` exists at all — in flight OR ready.
    ///
    /// Distinct from ``hasPreloadedWebView(for:)``, which answers "is one ready to adopt".
    /// The difference matters right after ``resetWarmedWebViews()``: the replacements have
    /// been started but none has finished loading, so the ready check says no while the
    /// pool is in fact being rebuilt.
    func isWarming(handle: String) -> Bool {
        preloadedWebViews[handle] != nil
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
            // A real preload means the SDK is genuinely in use, so a spare is now worth its
            // memory — an unpredicted open (Directory pin/card) can then skip process launch.
            self.hasBeenUsed = true
            self.prepareHotSpareIfNeeded()
            self.warmParams[handle] = params
            if let existing = self.preloadedWebViews[handle], existing.url == url {
                // Not a problem — this is the dedupe doing its job when a screen warms on
                // appear AND on foreground AND on prompt change. Logged so a "why didn't my
                // preload run?" question has an answer other than silence.
                return
            }
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
        observer.handle = handle
        webView.navigationDelegate = observer

        // Guard against a stale callback: if this handle's entry was replaced
        // (e.g. preload() called again before this one finished), only mutate
        // it if it's still THIS webview's entry.
        observer.onFinish = { [weak self, weak webView] in
            guard let self, let webView, self.preloadedWebViews[handle]?.webView === webView else { return }
            self.preloadedWebViews[handle]?.isReady = true
            // Elapsed here is the head start a later open gets for free. If it routinely
            // exceeds the time between warming and tapping, the warm is starting too late.
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
        warmOrder.removeAll { $0 == handle }
        warmOrder.append(handle)
        evictOldestWarmedIfNeeded()
    }

    /// Drops the oldest warmed WebViews until the pool fits ``maxWarmedWebViews``.
    ///
    /// Releasing the entry releases its `WKWebView` (and the `WarmupObserver` it retains),
    /// which tears down the WebContent process — that IS the point. Dropping one mid-warm is
    /// harmless: the observer dies with it, and the handle simply takes the normal load path
    /// next time it's opened.
    private func evictOldestWarmedIfNeeded() {
        while warmOrder.count > Self.maxWarmedWebViews {
            let oldest = warmOrder.removeFirst()
            preloadedWebViews.removeValue(forKey: oldest)
            warmParams.removeValue(forKey: oldest)
        }
    }
}
