import SwiftUI
import VoiceboxKit

/// Entry point for the VoiceboxKit harness.
///
/// Mirrors `VoiceboxExampleApp.kt` in the Android example: configure the SDK once
/// at launch, then warm a WebView for the handle the screen opens with.
@main
struct VoiceboxExampleApp: App {

    init() {
        // Staging, so harness recordings never reach a production voicebox.
        VoiceboxKit.baseURL = Harness.stagingBaseURL

        // Verbose `[VoiceboxKit]` logging in the Xcode console. On by default in
        // DEBUG; set explicitly so a Release build of the harness logs too.
        VoiceboxKit.debugLogging = true

        // Grant the WebView mic access once the app itself holds it, so the first
        // open shows one prompt instead of two.
        VoiceboxKit.autoGrantMicPermission = true

        // A take can outlast auto-lock, which would otherwise lose the recording.
        VoiceboxKit.keepsScreenAwake = true

        // Warm the handle the screen starts on, with the params it starts with —
        // the cache key is the full URL, so both have to match to get a warm load.
        VoiceboxKit.preload(handle: Harness.defaultHandle, params: Harness.userParams)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
