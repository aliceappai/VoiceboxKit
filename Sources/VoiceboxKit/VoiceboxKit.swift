import Foundation

/// Top-level namespace for VoiceboxKit configuration and preloading.
public enum VoiceboxKit {

    /// SDK version string.
    public static let version = "1.0.3"

    /// Base URL for Voicebox handles. Defaults to production (`https://vbx.to`).
    public static var baseURL: String = "https://vbx.to"

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
}
