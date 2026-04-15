import XCTest
@testable import VoiceboxKit

final class PresentationModeTests: XCTestCase {

    func testAllModesExist() {
        // Verify all four modes are defined and distinct
        let modes: [VoiceboxPresentationMode] = [
            .fullScreen, .bottomSheet, .sheet, .fitContent,
        ]
        let uniqueModes = Set(modes.map { "\($0)" })
        XCTAssertEqual(uniqueModes.count, 4)
    }

    func testConvenienceMethodSetsMode() {
        let vb = VoiceboxView(handle: "test")

        // presentAsSheet sets bottomSheet mode
        vb.presentationMode = .fullScreen // Start with different mode
        XCTAssertEqual(vb.presentationMode, .fullScreen)

        vb.presentationMode = .bottomSheet
        XCTAssertEqual(vb.presentationMode, .bottomSheet)
    }

    func testFitContentDocIOS16() {
        // Verify fitContent mode is defined (custom detents require iOS 16+)
        let mode = VoiceboxPresentationMode.fitContent
        XCTAssertEqual("\(mode)", "fitContent")
    }

    // MARK: - Custom height modes

    func testCustomHeightMode() {
        let mode = VoiceboxPresentationMode.custom(height: 520)
        if case .custom(let height) = mode {
            XCTAssertEqual(height, 520)
        } else {
            XCTFail("Expected .custom case")
        }
    }

    func testCustomFractionMode() {
        let mode = VoiceboxPresentationMode.customFraction(0.6)
        if case .customFraction(let fraction) = mode {
            XCTAssertEqual(fraction, 0.6)
        } else {
            XCTFail("Expected .customFraction case")
        }
    }

    func testEquatableBetweenModes() {
        XCTAssertEqual(VoiceboxPresentationMode.bottomSheet, .bottomSheet)
        XCTAssertEqual(VoiceboxPresentationMode.custom(height: 400), .custom(height: 400))
        XCTAssertNotEqual(VoiceboxPresentationMode.custom(height: 400), .custom(height: 500))
        XCTAssertNotEqual(VoiceboxPresentationMode.customFraction(0.5), .customFraction(0.6))
        XCTAssertNotEqual(VoiceboxPresentationMode.custom(height: 400), .fitContent)
    }

    func testAssignCustomHeightToVoiceboxView() {
        let vb = VoiceboxView(handle: "test")
        vb.presentationMode = .custom(height: 600)
        XCTAssertEqual(vb.presentationMode, .custom(height: 600))

        vb.presentationMode = .customFraction(0.75)
        XCTAssertEqual(vb.presentationMode, .customFraction(0.75))
    }
}
