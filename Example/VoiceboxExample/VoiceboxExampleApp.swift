import SwiftUI
import VoiceboxKit

@main
struct VoiceboxExampleApp: App {
    init() {
        // Preload on app launch for instant WebView load
        VoiceboxKit.preload(handle: "alice-feedback")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
