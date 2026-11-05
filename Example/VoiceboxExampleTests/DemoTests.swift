import XCTest
import VoiceboxKit
@testable import VoiceboxExample

/// Guards on the demo's configuration.
///
/// These exist because this app is public: whatever it does is what people
/// copy into their own apps, so a wrong default here spreads.
///
/// The test target is hosted by the app, so `VoiceboxExampleApp.init()` has
/// already run by the time these execute — the SDK state below is the state a
/// developer's first launch would see.
final class DemoTests: XCTestCase {

    /// Handles that only resolve on staging.
    private static let stagingOnlyHandles: Set<String> = ["p-test"]

    /// The handle and the host have to agree.
    ///
    /// Neither mismatch announces itself at runtime, which is why this is a test:
    ///
    /// - A staging-only handle on production does **not** error. vbx-web answers
    ///   an unknown handle with a redirect to the directory root, so the recorder
    ///   sheet silently opens on the public browse page.
    /// - A real handle with the staging override still in place sends a published
    ///   demo's recordings to staging.
    ///
    /// It fails in both directions on purpose: whichever line you change, this
    /// reminds you to change the other.
    func testHandleAndHostAgree() {
        let handleNeedsStaging = Self.stagingOnlyHandles.contains(Demo.handle)
        let hostIsStaging = VoiceboxKit.baseURL.lowercased().contains("staging")

        XCTAssertEqual(
            handleNeedsStaging,
            hostIsStaging,
            """
            Demo.handle is "\(Demo.handle)" but baseURL is \(VoiceboxKit.baseURL).
            A staging-only handle needs the staging override in VoiceboxExampleApp.init();
            a production handle needs that line deleted.
            """
        )
    }

    /// The handle is passed bare — the SDK builds the URL around it.
    func testHandleIsWellFormed() {
        XCTAssertFalse(Demo.handle.isEmpty, "Set Demo.handle to your own voicebox handle.")
        XCTAssertFalse(Demo.handle.hasPrefix("@"), "Pass the handle without the leading @.")
        XCTAssertFalse(Demo.handle.contains("/"), "Pass the handle alone, not a URL.")
        XCTAssertFalse(Demo.handle.contains(" "), "Handles do not contain spaces.")
    }

    /// Catches a half-finished copy of the demo before it reaches a device.
    func testHandleHasNoLeftoverPlaceholderPunctuation() {
        XCTAssertFalse(Demo.handle.contains("<"), "Replace the placeholder with a real handle.")
        XCTAssertFalse(Demo.handle.contains(">"), "Replace the placeholder with a real handle.")
        XCTAssertNotEqual(Demo.handle, "REPLACE-ME", "Replace the placeholder with a real handle.")
    }
}
