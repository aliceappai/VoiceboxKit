import SwiftUI
import VoiceboxKit

/// Settings for this demo, in one place so there is one thing to change.
enum Demo {

    /// The voicebox that recordings are sent to.
    ///
    /// Replace this with your own handle — it is the part after the `@` in
    /// your voicebox's address, so `vbx.to/@acme-support` is `"acme-support"`.
    ///
    /// - Note: `p-test` is a stand-in that exists only on staging, which is why
    ///   `init()` below points the SDK at the staging host. The two go together:
    ///   change this to a handle on `vbx.to` and delete that line at the same time.
    static let handle = "p-test"
}

/// A minimal app that opens the Voicebox recorder.
///
/// Integrating the SDK takes two things:
///
/// 1. A microphone usage string in your Info.plist. This target sets it with
///    `INFOPLIST_KEY_NSMicrophoneUsageDescription` in build settings; an app
///    with its own Info.plist adds `NSMicrophoneUsageDescription` there.
/// 2. The `.voicebox(isPresented:handle:)` modifier — see `ContentView`.
///
/// Everything in `init()` below is optional. The SDK works without any of it.
@main
struct VoiceboxExampleApp: App {

    init() {
        // TEMPORARY — delete this line before the demo is published.
        //
        // A real integration never sets `baseURL`: it already defaults to
        // production (`https://vbx.to`). This is here only because
        // `Demo.handle` is a staging-only voicebox, and on production that
        // handle redirects to the directory listing instead of a recorder.
        VoiceboxKit.baseURL = "https://vbxstaging.com"

        // Optional. Loads the recorder in the background now so the first open
        // is instant rather than waiting on the page. Call it once at launch
        // for the handle you expect to open.
        VoiceboxKit.preload(handle: Demo.handle)

        // Optional. Passes the app's microphone permission through to the web
        // view, so the user answers one prompt instead of two. Leave it off if
        // your app manages microphone access itself.
        VoiceboxKit.autoGrantMicPermission = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
