import UIKit
import VoiceboxKit

/// Presents the recorder through the UIKit API — the counterpart of Android's
/// `VoiceboxView(handle).present(activity)`.
///
/// Use this when the calling screen isn't SwiftUI. It reports the same events
/// as the `.voicebox()` modifier, through `VoiceboxDelegate` instead of
/// closures, plus `voiceboxDidFail` which the modifier has no equivalent for.
final class UIKitVoiceboxPresenter: NSObject, VoiceboxDelegate {

    /// `VoiceboxView.delegate` is `weak`, so whoever presents the view has to
    /// keep a reference to it. Without this the view deallocates on the way out
    /// of `present(handle:)` and no callback ever arrives.
    private var presented: VoiceboxView?

    private let onEvent: (String, Bool) -> Void

    /// - Parameter onEvent: called with a message and whether it is a failure.
    init(onEvent: @escaping (String, Bool) -> Void) {
        self.onEvent = onEvent
    }

    func present(handle: String) {
        guard let host = Self.topViewController() else { return }
        let view = VoiceboxView(handle: handle)
        view.delegate = self
        presented = view
        view.present(from: host)
    }

    // MARK: - VoiceboxDelegate

    func voiceboxDidFinishRecording(_ voiceboxView: VoiceboxView) {
        onEvent("Recording complete ✓", false)
    }

    func voiceboxDidSubmitMessage(_ voiceboxView: VoiceboxView) {
        onEvent("Message submitted ✓", false)
    }

    func voiceboxDidDismiss(_ voiceboxView: VoiceboxView) {
        onEvent("Voicebox dismissed", false)
        presented = nil
    }

    func voiceboxDidFail(_ voiceboxView: VoiceboxView, error: Error) {
        onEvent("Error: \(error.localizedDescription)", true)
    }

    // MARK: - Helpers

    /// The view controller to present from. A SwiftUI app has no controller to
    /// hand over, so walk down from the active window's root.
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
