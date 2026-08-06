import UIKit

/// Ref-counted owner of `UIApplication.shared.isIdleTimerDisabled`, used to keep the
/// screen awake while a Voicebox recorder is on screen.
///
/// **Why the SDK does this:** a Voicebox message can run to the recorder's full length
/// (two minutes), but the iOS auto-lock default is commonly 30s–1min — i.e. shorter than
/// the recorder's own limit. If the device locks mid-take the recording is lost: capture
/// runs in the WebView's content process, so the microphone track is torn down as soon as
/// the app leaves the foreground and the page's JavaScript is suspended shortly after.
/// The user returns to a frozen recorder. Holding the idle timer open for the lifetime of
/// the recorder removes the most common way that happens.
///
/// **Why ref-counted rather than a plain flag:** `isIdleTimerDisabled` is process-global,
/// and a host app can have more than one `VoiceboxViewController` alive across a
/// present/dismiss transition. With a bare boolean the first controller to disappear
/// would either wake the screen while another is still recording, or leave the flag stuck
/// on. Stuck on is the worse failure — the user's device silently stops auto-locking for
/// the rest of the session, and nothing about the symptom points back at the SDK. Balance
/// is enforced here so callers only have to pair `acquire()` with `release()`.
///
/// - Important: Main thread only. `VoiceboxViewController` drives it from its view
///   lifecycle, which already satisfies that.
final class VoiceboxScreenAwake {

    /// Shared instance used by `VoiceboxViewController`. Tests construct their own with a
    /// capturing closure rather than touching `UIApplication`.
    static let shared = VoiceboxScreenAwake()

    private let setIdleTimerDisabled: (Bool) -> Void

    /// Number of live holders. The system flag is written only on the 0↔1 edges, so
    /// repeated acquires and releases don't thrash `UIApplication`.
    private(set) var holderCount = 0

    init(setIdleTimerDisabled: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    /// `true` while at least one holder is keeping the screen awake.
    var isKeepingScreenAwake: Bool { holderCount > 0 }

    /// Registers a holder. The first one disables the idle timer.
    func acquire() {
        holderCount += 1
        if holderCount == 1 {
            setIdleTimerDisabled(true)
        }
    }

    /// Drops a holder. The last one re-enables the idle timer.
    ///
    /// Releasing with no holders is a no-op rather than an error: the count must never go
    /// negative, or a later `acquire()` would fail to reach 1 and the screen would sleep
    /// during a recording with no visible cause.
    func release() {
        guard holderCount > 0 else { return }
        holderCount -= 1
        if holderCount == 0 {
            setIdleTimerDisabled(false)
        }
    }
}
