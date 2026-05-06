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
    /// Call this once during app launch so the WebView loads instantly
    /// when the user taps a button.
    ///
    /// ```swift
    /// // In AppDelegate or App.init
    /// VoiceboxKit.preload(handle: "alice-feedback")
    /// ```
    ///
    /// - Parameter handle: The Voicebox handle to preload.
    public static func preload(handle: String) {
        VoiceboxCache.shared.preload(handle: handle)
    }
}
