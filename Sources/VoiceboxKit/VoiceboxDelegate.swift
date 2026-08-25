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

    /// Called with the recorder's anonymous session id, once it exists.
    ///
    /// Messages recorded while signed out are attributed to this id and to no account.
    /// Keep it, and hand it back when the user signs in, so those messages can be claimed
    /// for the new account — without it they stay anonymous permanently.
    ///
    /// - Note: May be called more than once for a session (a re-open reports the same id
    ///   again) and may never be called at all — a visitor who opens the recorder without
    ///   submitting anything has no id to report. Treat it as "the latest known id",
    ///   store it, and expect repeats.
    func voicebox(_ voiceboxView: VoiceboxView, didResolveAnonymousSessionId sessionId: String)

    /// Called with the one-time token that claims this device's signed-out recordings.
    ///
    /// Send it with your sign-in call and the backend attributes those messages to the
    /// account. It is **single-use and short-lived** (minted server-side when the page
    /// renders, ~30 minutes), so spend it promptly rather than storing it indefinitely.
    ///
    /// - Note: Only arrives AFTER a message has been submitted in this recorder, and only
    ///   for a visitor with no web session — signed in, the page has nothing to claim and
    ///   renders no token. Expect it not to arrive at all in the common case.
    func voicebox(_ voiceboxView: VoiceboxView, didResolveClaimToken claimToken: String)
}

// MARK: - Default Implementations (all optional)

public extension VoiceboxDelegate {
    func voiceboxDidFinishRecording(_ voiceboxView: VoiceboxView) {}
    func voiceboxDidSubmitMessage(_ voiceboxView: VoiceboxView) {}
    func voiceboxDidDismiss(_ voiceboxView: VoiceboxView) {}
    func voiceboxDidFail(_ voiceboxView: VoiceboxView, error: Error) {}
    func voicebox(_ voiceboxView: VoiceboxView, didResolveAnonymousSessionId sessionId: String) {}
    func voicebox(_ voiceboxView: VoiceboxView, didResolveClaimToken claimToken: String) {}
}
