import UIKit
import VoiceboxKit

/// The UIKit presentation path, and the only way to observe a load failure:
/// `voiceboxDidFail` lives on `VoiceboxDelegate` and the SwiftUI `.voicebox()`
/// modifier has no equivalent callback.
final class UIKitVoiceboxPresenter: NSObject, VoiceboxDelegate {

    private weak var model: HarnessModel?

    /// `VoiceboxView.delegate` is weak and `present(from:)` doesn't take ownership,
    /// so the harness holds the view until it is dismissed.
    private var presented: VoiceboxView?

    init(model: HarnessModel) {
        self.model = model
        super.init()
    }

    /// Presents with the screen's current scenario, through the UIKit API.
    func present(handle: String, scenario model: HarnessModel) {
        guard let host = Self.topViewController() else {
            model.record("No view controller to present from", isFailure: true)
            return
        }

        let view = VoiceboxView(handle: handle, params: model.params, theme: model.themeChoice.theme)
        view.presentationMode = model.mode.mode
        view.showCloseButton = model.showCloseButton
        view.hidePageChrome = model.hidePageChrome
        view.entranceAnimation = model.entranceAnimation
        view.delegate = self
        presented = view

        model.record("Presenting via UIKit — \(model.mode.title)")
        view.present(from: host)
    }

    // MARK: VoiceboxDelegate

    func voiceboxDidFinishRecording(_ voiceboxView: VoiceboxView) {
        model?.record("UIKit: recording complete ✓")
    }

    func voiceboxDidSubmitMessage(_ voiceboxView: VoiceboxView) {
        model?.record("UIKit: message submitted ✓")
    }

    func voiceboxDidDismiss(_ voiceboxView: VoiceboxView) {
        presented = nil
        model?.record("UIKit: dismissed")
    }

    func voiceboxDidFail(_ voiceboxView: VoiceboxView, error: Error) {
        model?.record("UIKit: failed — \(error.localizedDescription)", isFailure: true)
    }

    func voicebox(_ voiceboxView: VoiceboxView, didResolveAnonymousSessionId sessionId: String) {
        model?.captureSessionId(sessionId)
    }

    // MARK: Helpers

    /// Top-most presented controller in the active scene.
    static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows
            .first { $0.isKeyWindow }

        var controller = window?.rootViewController
        while let next = controller?.presentedViewController {
            controller = next
        }
        return controller
    }
}
