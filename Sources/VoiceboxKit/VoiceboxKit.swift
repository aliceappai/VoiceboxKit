import Foundation
import WebKit

/// Top-level namespace for VoiceboxKit configuration and preloading.
public enum VoiceboxKit {

    /// SDK version string.
    public static let version = "1.1.3"

    /// Base URL for Voicebox handles. Defaults to production (`https://vbx.to`).
    public static var baseURL: String = "https://vbx.to"

    /// When `true`, the SDK prints diagnostics to the console (`[VoiceboxKit][...]`).
    ///
    /// Defaults to `true` in DEBUG builds and `false` in release, so a shipping app is
    /// silent without the host having to remember to turn it off. Set it explicitly to
    /// override either way:
    /// ```swift
    /// VoiceboxKit.debugLogging = true
    /// ```
    public static var debugLogging: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    // MARK: - Global Configuration

    /// When `true`, the SDK auto-grants microphone permission to the WebView
    /// if the host app already has native mic access. Default is `false`.
    ///
    /// Set this once at app launch:
    /// ```swift
    /// VoiceboxKit.autoGrantMicPermission = true
    /// ```
    ///
    /// Individual `VoiceboxView` instances can override this value.
    public static var autoGrantMicPermission: Bool = false

    /// When `true`, the SDK automatically collects non-PII app and device
    /// context (bundleID, appVersion, osVersion, deviceModel, locale, etc.)
    /// and includes it in the Voicebox URL.
    ///
    /// This lets feedback recipients immediately see which app and version
    /// a recording came from, without the host app manually passing these
    /// params on every call.
    ///
    /// App-provided params always take precedence over auto-collected values.
    /// Default is `true`.
    ///
    /// ```swift
    /// // Opt out (e.g., for strict-privacy apps)
    /// VoiceboxKit.autoCollectAppContext = false
    /// ```
    ///
    /// See ``VoiceboxAppContext`` for the full list of collected fields.
    public static var autoCollectAppContext: Bool = true

    /// When `true`, the SDK keeps the screen awake while a Voicebox is on screen,
    /// restoring normal auto-lock as soon as it closes. Default is `false`.
    ///
    /// **Recommended for any host that records.** A recording can run to the recorder's
    /// full length (two minutes), but the iOS auto-lock default is commonly 30s–1min —
    /// shorter than the recorder's own limit. If the device locks mid-take the recording
    /// is lost: the microphone is cut off as soon as the app leaves the foreground, and
    /// the recorder freezes with no way to send.
    ///
    /// Opt-in rather than on by default because `isIdleTimerDisabled` is process-global
    /// state the **host** owns — upgrading the SDK should not silently change how a
    /// device behaves. Same reasoning as ``autoGrantMicPermission``.
    ///
    /// Set this once at app launch:
    /// ```swift
    /// VoiceboxKit.keepsScreenAwake = true
    /// ```
    ///
    /// Individual `VoiceboxView` instances can override this value.
    ///
    /// - Note: This tracks the Voicebox being **presented**, not actively recording —
    ///   the SDK is not told when recording starts, only when it completes. A Voicebox
    ///   left open while the user reads the prompt also holds the screen awake.
    ///
    /// - Note: Only *auto-lock* is prevented. A manual lock, an app switch, or an
    ///   incoming call still interrupt the recording, because they take the app out of
    ///   the foreground regardless of the idle timer.
    public static var keepsScreenAwake: Bool = false

    /// Prefetch and cache the Voicebox page for the given handle.
    ///
    /// Call this once during app launch (or as soon as the destination screen
    /// appears) so the WebView loads instantly when the user taps a button.
    ///
    /// - Important: Pass the **same `params`** you'll later pass to
    ///   `.voicebox(handle:params:...)` / `VoiceboxView(handle:params:...)`.
    ///   The preloaded WebView is only reused if the resulting URL matches
    ///   exactly (including auto-collected app context and UTM tags) — a
    ///   mismatched `params` means the sheet falls back to a fresh load and
    ///   the loading skeleton shows, same as if `preload` was never called.
    ///
    /// ```swift
    /// // In AppDelegate or App.init
    /// VoiceboxKit.preload(handle: "alice-feedback")
    ///
    /// // If the sheet is opened with params, preload with the SAME params:
    /// let params = ["email": user.email, "prompt": prompt]
    /// VoiceboxKit.preload(handle: "alice-feedback", params: params)
    /// // ... later ...
    /// view.voicebox(isPresented: $show, handle: "alice-feedback", params: params)
    /// ```
    ///
    /// - Parameters:
    ///   - handle: The Voicebox handle to preload.
    ///   - params: The exact params the sheet will be opened with. Defaults to none.
    public static func preload(handle: String, params: [String: String] = [:]) {
        VoiceboxCache.shared.preload(handle: handle, params: params)
    }

    // MARK: - Recorder session

    /// Sign the recorder's web view in, using a URL your app obtained from its own backend.
    ///
    /// The recorder runs on a different host from your app's API, with its own cookie, so
    /// a natively signed-in user still reaches it signed OUT — and everything they record
    /// is anonymous. Loading a session URL here fixes that: messages are then attributed
    /// as they are submitted.
    ///
    /// **VoiceboxKit does not mint this URL, does not call any Voicebox API, and never
    /// handles credentials.** It navigates to what you give it, in the storage context the
    /// recorder uses, and reports whether it arrived. Most integrations never need this —
    /// it is for a host whose users have Voicebox accounts.
    ///
    /// Call it once per session, not per recorder open: the cookie is shared by every web
    /// view in the app, so one call covers every voicebox opened afterwards. Sensible
    /// moments are app launch when already signed in, straight after your own sign-in, and
    /// a foreground return when the session may have lapsed.
    ///
    /// **Treat failure as unimportant.** Do not block opening the recorder on it and do not
    /// show an error: a recording made without a session is still captured, just anonymously,
    /// and can be claimed afterwards. Blocking trades a working recorder for a spinner.
    ///
    /// Warmed WebViews are dropped and re-warmed around the load, since a page warmed before
    /// this rendered signed-out and would keep saying so.
    ///
    /// - Parameters:
    ///   - url: The session URL from your backend.
    ///   - completion: Called on the main queue with whether the load succeeded.
    public static func establishSession(from url: URL, completion: ((Bool) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { establishSession(from: url, completion: completion) }
            return
        }

        VoiceboxLog.debug("session", "establishing session via \(url.host ?? "?")\(url.path)")
        SessionPrimer.shared.load(url) { success in
            VoiceboxLog.debug("session", "establish \(success ? "succeeded" : "failed")")
            // AFTER the load, so the pages that come back are warmed against the new cookie.
            VoiceboxCache.shared.resetWarmedWebViews()
            completion?(success)
        }
    }

    /// Forget who was recording on this device. Call it on sign-out.
    ///
    /// Clears both halves of the recorder's identity, because a host that did one and
    /// forgot the other would leave the device in a state neither of them describes:
    ///
    /// - the **session cookie** for `baseURL`'s origin, so the recorder stops being signed
    ///   in as the account that just left;
    /// - the **anonymous session id** in local + session storage, which outlives any
    ///   session and would otherwise keep accumulating every recording made on this device
    ///   under one identity.
    ///
    /// Clearing the id is **not** on its own a defence against the wrong account claiming
    /// those recordings — that protection is server-side, where a claim only ever touches
    /// messages nobody owns yet. What it does is bound how much history one claim can
    /// cover. vbx-web does the equivalent when it tears a session down.
    ///
    /// Caches are left alone: this forgets who was recording, not everything the recorder
    /// ever loaded. Warmed WebViews are dropped and re-warmed, since a preloaded page still
    /// holding the old id in memory writes it straight back on its next
    /// `ensureProfilesSessionId()`.
    ///
    /// - Note: A new anonymous id is minted the next time the recorder opens. This severs
    ///   the link to earlier recordings; it does not stop future ones being tracked.
    ///
    /// - Parameter completion: Called on the main queue once the data has been removed.
    public static func clearSession(completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { clearSession(completion: completion) }
            return
        }

        // Before the removal, not after: a warmed page holding the old id in memory is
        // exactly what would write it back into the store we are about to empty.
        VoiceboxCache.shared.resetWarmedWebViews()

        guard let host = URL(string: baseURL)?.host, !host.isEmpty else {
            VoiceboxLog.debug("session", "clear skipped — baseURL has no host (\(baseURL))")
            completion?()
            return
        }

        // `WKWebsiteDataRecord.displayName` is the registrable domain ("vbx.to"), while
        // baseURL's host may be a subdomain of it, so match both ways.
        let types: Set<String> = [
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeCookies
        ]
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { record in
                host == record.displayName || host.hasSuffix(".\(record.displayName)")
            }
            guard !matching.isEmpty else {
                VoiceboxLog.debug("session", "clear found no stored data for \(host)")
                DispatchQueue.main.async { completion?() }
                return
            }
            store.removeData(ofTypes: types, for: matching) {
                VoiceboxLog.debug("session", "cleared recorder session + storage for \(host)")
                completion?()
            }
        }
    }
}
