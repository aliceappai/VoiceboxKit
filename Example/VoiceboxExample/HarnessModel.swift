import Combine
import Foundation
import VoiceboxKit

/// One line in the event log.
struct HarnessEvent: Identifiable {
    let id = UUID()
    let at = Date()
    let message: String
    let isFailure: Bool

    var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: at)
    }
}

/// Everything the harness screen can change, plus what the SDK reports back.
///
/// Not `@MainActor`: SwiftUI mutates it on the main thread and the SDK delivers
/// its callbacks there too, so the annotation would only add isolation noise.
final class HarnessModel: ObservableObject {

    // MARK: Scenario

    @Published var handle = Harness.defaultHandle
    @Published var mode: ModeChoice = .bottomSheet
    @Published var themeChoice: ThemeChoice = .standard
    @Published var sendUserParams = true
    @Published var showCloseButton = true
    @Published var showDragIndicator = true
    @Published var hidePageChrome = false
    @Published var animateCardEntrance = true

    /// What the SDK is actually asked to present with.
    var params: [String: String] { sendUserParams ? Harness.userParams : [:] }

    var entranceAnimation: VoiceboxEntranceAnimation {
        animateCardEntrance ? .all : .none
    }

    // MARK: SDK globals, mirrored so the switches show the live value

    @Published var debugLogging: Bool {
        didSet { VoiceboxKit.debugLogging = debugLogging }
    }
    @Published var autoGrantMicPermission: Bool {
        didSet { VoiceboxKit.autoGrantMicPermission = autoGrantMicPermission }
    }
    @Published var autoCollectAppContext: Bool {
        didSet { VoiceboxKit.autoCollectAppContext = autoCollectAppContext }
    }
    @Published var keepsScreenAwake: Bool {
        didSet { VoiceboxKit.keepsScreenAwake = keepsScreenAwake }
    }
    @Published var baseURLChoice: BaseURLChoice {
        didSet { VoiceboxKit.baseURL = baseURLChoice.urlString }
    }

    // MARK: Results

    @Published private(set) var events: [HarnessEvent] = []
    @Published private(set) var status = ""
    @Published private(set) var anonymousSessionId: String?

    /// Session URL your backend would mint. Typed in by hand here.
    @Published var sessionURLString = ""

    init() {
        debugLogging = VoiceboxKit.debugLogging
        autoGrantMicPermission = VoiceboxKit.autoGrantMicPermission
        autoCollectAppContext = VoiceboxKit.autoCollectAppContext
        keepsScreenAwake = VoiceboxKit.keepsScreenAwake
        baseURLChoice = VoiceboxKit.baseURL == Harness.productionBaseURL ? .production : .staging
    }

    // MARK: Event log

    private var statusToken = 0

    /// Logs an event and flashes it in the status card for three seconds —
    /// the same auto-clear the Android example uses.
    func record(_ message: String, isFailure: Bool = false) {
        events.insert(HarnessEvent(message: message, isFailure: isFailure), at: 0)
        if events.count > 40 { events.removeLast(events.count - 40) }

        status = message
        statusToken += 1
        let token = statusToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.statusToken == token else { return }
            self.status = ""
        }
    }

    func clearEvents() {
        events.removeAll()
        status = ""
    }

    // MARK: SDK calls the screen triggers

    /// Warms a WebView for exactly what the screen will present. The cache key is
    /// the full URL, so preloading with different params is a wasted warm-up.
    func preloadCurrentScenario() {
        VoiceboxKit.preload(handle: handle, params: params)
        record("Preloaded \(handle)\(params.isEmpty ? "" : " with \(params.count) params")")
    }

    func captureSessionId(_ id: String) {
        anonymousSessionId = id
        record("Anonymous session id: \(id)")
    }

    func establishSession() {
        guard let url = URL(string: sessionURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            record("Not a valid session URL", isFailure: true)
            return
        }
        VoiceboxKit.establishSession(from: url) { [weak self] ok in
            DispatchQueue.main.async {
                self?.record(ok ? "Session established" : "establishSession failed", isFailure: !ok)
            }
        }
    }

    func clearSession() {
        VoiceboxKit.clearSession { [weak self] in
            DispatchQueue.main.async {
                self?.anonymousSessionId = nil
                self?.record("Session cleared")
            }
        }
    }
}
