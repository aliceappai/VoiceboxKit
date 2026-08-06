import XCTest
@testable import VoiceboxKit

/// Pins the acquire/release balance of `VoiceboxScreenAwake` — the thing that keeps
/// `UIApplication.isIdleTimerDisabled` from being stranded on (the user's device silently
/// stops auto-locking for the rest of the session) or stranded off (the screen sleeps
/// mid-recording and the take is lost).
///
/// Each test builds its own coordinator with a capturing closure, so nothing here touches
/// `UIApplication` or shared state.
final class ScreenAwakeTests: XCTestCase {

    /// Records every write to the system flag, so tests can assert both the value and that
    /// redundant writes aren't happening.
    private var writes: [Bool] = []

    private func makeCoordinator() -> VoiceboxScreenAwake {
        writes = []
        return VoiceboxScreenAwake { [weak self] in self?.writes.append($0) }
    }

    // MARK: - Basic acquire / release

    func testAcquireDisablesTheIdleTimer() {
        let awake = makeCoordinator()

        awake.acquire()

        XCTAssertEqual(writes, [true])
        XCTAssertTrue(awake.isKeepingScreenAwake)
    }

    func testReleaseAfterAcquireRestoresTheIdleTimer() {
        let awake = makeCoordinator()

        awake.acquire()
        awake.release()

        XCTAssertEqual(writes, [true, false])
        XCTAssertFalse(awake.isKeepingScreenAwake)
    }

    // MARK: - Nesting

    func testNestedAcquiresStayDisabledUntilTheLastRelease() {
        // Two controllers can be alive across a present/dismiss transition. The first
        // release must not wake the screen while the second still needs it.
        let awake = makeCoordinator()

        awake.acquire()
        awake.acquire()
        awake.release()

        XCTAssertTrue(awake.isKeepingScreenAwake)
        XCTAssertEqual(writes, [true], "First release must not touch the flag")

        awake.release()

        XCTAssertFalse(awake.isKeepingScreenAwake)
        XCTAssertEqual(writes, [true, false])
    }

    func testOnlyTheZeroToOneEdgeWritesToTheSystem() {
        let awake = makeCoordinator()

        awake.acquire()
        awake.acquire()
        awake.acquire()

        XCTAssertEqual(writes, [true])
        XCTAssertEqual(awake.holderCount, 3)
    }

    // MARK: - Unbalanced calls

    func testReleaseWithoutAcquireIsIgnored() {
        let awake = makeCoordinator()

        awake.release()

        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(awake.holderCount, 0)
    }

    func testRepeatedReleaseCannotDriveTheCountNegative() {
        // Regression guard: a negative count would stop the NEXT acquire reaching 1, so
        // the screen would sleep during a recording with no visible cause.
        let awake = makeCoordinator()

        awake.acquire()
        awake.release()
        awake.release()
        awake.release()

        XCTAssertEqual(awake.holderCount, 0)

        awake.acquire()

        XCTAssertTrue(awake.isKeepingScreenAwake)
        XCTAssertEqual(writes, [true, false, true])
    }

    // MARK: - Configuration resolution

    func testKeepsScreenAwakeDefaultsToOffGlobally() {
        // Opt-in on purpose: `isIdleTimerDisabled` is process-global state the HOST owns,
        // so upgrading the SDK must not change how a device behaves on its own. Hosts
        // that record are expected to turn it on, same as `autoGrantMicPermission`.
        XCTAssertFalse(VoiceboxKit.keepsScreenAwake)
    }

    func testNilInstanceFollowsTheGlobalValue() {
        let original = VoiceboxKit.keepsScreenAwake
        defer { VoiceboxKit.keepsScreenAwake = original }

        let view = VoiceboxView(handle: "test")

        VoiceboxKit.keepsScreenAwake = true
        XCTAssertTrue(view.effectiveKeepsScreenAwake)

        VoiceboxKit.keepsScreenAwake = false
        XCTAssertFalse(view.effectiveKeepsScreenAwake)
    }

    // MARK: - View controller lifecycle

    // These drive the real `VoiceboxScreenAwake.shared`, so they measure against a
    // baseline rather than asserting absolute counts — that keeps them honest if another
    // test in the bundle ever leaves a holder behind.

    func testAppearAcquiresAndWillDisappearReleases() {
        let original = VoiceboxKit.keepsScreenAwake
        defer { VoiceboxKit.keepsScreenAwake = original }
        VoiceboxKit.keepsScreenAwake = true

        let baseline = VoiceboxScreenAwake.shared.holderCount
        let vc = VoiceboxViewController(voiceboxView: VoiceboxView(handle: "test"))

        vc.viewDidAppear(false)
        XCTAssertEqual(VoiceboxScreenAwake.shared.holderCount, baseline + 1)

        // viewWillDisappear alone must be enough. It fires before the dismiss animation
        // and is the path that reliably runs when a SwiftUI .sheet tears down its
        // representable — viewDidDisappear cannot be counted on there.
        vc.viewWillDisappear(false)
        XCTAssertEqual(VoiceboxScreenAwake.shared.holderCount, baseline)

        // ...and the later viewDidDisappear must not double-release.
        vc.viewDidDisappear(false)
        XCTAssertEqual(VoiceboxScreenAwake.shared.holderCount, baseline)
    }

    func testRepeatedAppearDoesNotDoubleAcquire() {
        let original = VoiceboxKit.keepsScreenAwake
        defer { VoiceboxKit.keepsScreenAwake = original }
        VoiceboxKit.keepsScreenAwake = true

        let baseline = VoiceboxScreenAwake.shared.holderCount
        let vc = VoiceboxViewController(voiceboxView: VoiceboxView(handle: "test"))

        // e.g. returning from a nested presentation over the sheet.
        vc.viewDidAppear(false)
        vc.viewDidAppear(false)
        XCTAssertEqual(VoiceboxScreenAwake.shared.holderCount, baseline + 1)

        vc.viewWillDisappear(false)
        XCTAssertEqual(VoiceboxScreenAwake.shared.holderCount, baseline)
    }

    func testDisabledControllerNeverAcquires() {
        let original = VoiceboxKit.keepsScreenAwake
        defer { VoiceboxKit.keepsScreenAwake = original }
        VoiceboxKit.keepsScreenAwake = false

        let baseline = VoiceboxScreenAwake.shared.holderCount
        let vc = VoiceboxViewController(voiceboxView: VoiceboxView(handle: "test"))

        vc.viewDidAppear(false)
        XCTAssertEqual(VoiceboxScreenAwake.shared.holderCount, baseline)

        vc.viewWillDisappear(false)
        XCTAssertEqual(VoiceboxScreenAwake.shared.holderCount, baseline,
                       "an unmatched release must not drive the count below baseline")
    }

    func testInstanceOverrideWinsOverTheGlobal() {
        let original = VoiceboxKit.keepsScreenAwake
        defer { VoiceboxKit.keepsScreenAwake = original }

        let view = VoiceboxView(handle: "test")

        VoiceboxKit.keepsScreenAwake = false
        view.keepsScreenAwake = true
        XCTAssertTrue(view.effectiveKeepsScreenAwake, "instance true beats global false")

        VoiceboxKit.keepsScreenAwake = true
        view.keepsScreenAwake = false
        XCTAssertFalse(view.effectiveKeepsScreenAwake, "instance false beats global true")
    }
}
