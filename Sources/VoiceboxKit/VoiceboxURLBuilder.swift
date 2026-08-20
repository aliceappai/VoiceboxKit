import Foundation

/// Builds the Voicebox URL for a handle + params, shared by `VoiceboxView.buildURL()`
/// and `VoiceboxCache.preload(handle:params:)` so a preload always warms the exact
/// URL the sheet will later request — otherwise the preloaded WebView goes unused
/// and the sheet re-fetches from scratch.
enum VoiceboxURLBuilder {

    /// Merge order (lowest to highest precedence):
    /// 1. Auto-collected app context (if `VoiceboxKit.autoCollectAppContext == true`)
    /// 2. App-provided `params` (always win over auto-collected)
    /// 3. UTM tags (always appended last)
    static func build(handle: String, params: [String: String]) -> URL {
        var components = URLComponents(string: "\(VoiceboxKit.baseURL)/@\(handle)")!

        var merged: [String: String] = [:]
        if VoiceboxKit.autoCollectAppContext {
            merged = VoiceboxAppContext.collect()
        }

        for (key, value) in params {
            merged[key] = value
        }

        var queryItems = merged.map { key, value in
            URLQueryItem(name: key, value: value)
        }

        // Sort for deterministic URLs (easier to test, cache, and compare).
        queryItems.sort { $0.name < $1.name }

        queryItems.append(URLQueryItem(name: "utm_source", value: "voiceboxkit"))
        queryItems.append(URLQueryItem(name: "utm_medium", value: "ios_sdk"))

        components.queryItems = queryItems
        return components.url!
    }

    /// Whether `url` is still THIS handle's recorder page.
    ///
    /// vbx-web answers an unknown or unavailable `/@handle` with a 303 to the directory root
    /// (`RecorderController#set_voicebox`), preserving the query string — so the redirect is
    /// indistinguishable from a normal load unless the PATH is checked. Without this, a dead
    /// handle silently renders the public directory browse page inside a recorder sheet.
    ///
    /// Compared case-insensitively because vbx-web downcases the handle server-side, and by
    /// prefix so a deeper recorder path still counts as the recorder.
    static func isRecorderPath(_ url: URL, handle: String) -> Bool {
        guard !handle.isEmpty else { return true }
        return url.path.lowercased().hasPrefix("/@\(handle.lowercased())")
    }
}
