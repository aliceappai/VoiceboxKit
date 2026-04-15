import Foundation

/// Delegate protocol for receiving Voicebox lifecycle events.
///
/// All methods have default empty implementations, so conforming types
/// only need to implement the callbacks they care about.
///
/// ```swift
/// class MyViewController: UIViewController, VoiceboxDelegate {
///     func voiceboxDidFinishRecording(_ voiceboxView: VoiceboxView) {
///         print("Recording submitted!")
///     }
/// }
/// ```
public protocol VoiceboxDelegate: AnyObject {

    /// Called when the user finishes recording (receives `voicebox:recordingComplete`).
    func voiceboxDidFinishRecording(_ voiceboxView: VoiceboxView)

    /// Called when the recording is submitted/saved (receives `voicebox:messageSubmitted`).
    func voiceboxDidSubmitMessage(_ voiceboxView: VoiceboxView)

    /// Called when the Voicebox view is dismissed (swipe, close button, or programmatic).
    func voiceboxDidDismiss(_ voiceboxView: VoiceboxView)

    /// Called when the Voicebox fails to load (network error, timeout, etc.).
    func voiceboxDidFail(_ voiceboxView: VoiceboxView, error: Error)
}

// MARK: - Default Implementations (all optional)

public extension VoiceboxDelegate {
    func voiceboxDidFinishRecording(_ voiceboxView: VoiceboxView) {}
    func voiceboxDidSubmitMessage(_ voiceboxView: VoiceboxView) {}
    func voiceboxDidDismiss(_ voiceboxView: VoiceboxView) {}
    func voiceboxDidFail(_ voiceboxView: VoiceboxView, error: Error) {}
}
