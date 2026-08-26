import Foundation

/// Diagnostic logging for the SDK, off in release builds.
///
/// Deliberately `print` rather than `os_log`: these lines exist to be read in Xcode's
/// console while wiring a host app up, and a unified-logging subsystem is one more thing
/// to go and find. Gated on `VoiceboxKit.debugLogging`, which is `true` only in DEBUG.
enum VoiceboxLog {

    /// - Parameters:
    ///   - category: Short area tag, e.g. `"session"`. Printed in brackets.
    ///   - message: Autoclosure so the string is never built when logging is off.
    static func debug(_ category: String, _ message: @autoclosure () -> String) {
        guard VoiceboxKit.debugLogging else { return }
        print("[VoiceboxKit][\(category)] \(message())")
    }
}
