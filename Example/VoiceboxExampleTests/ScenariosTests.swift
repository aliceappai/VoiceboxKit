import XCTest
import VoiceboxKit
@testable import VoiceboxExample

/// The harness's job is to reach every SDK scenario, so these tests pin the
/// catalogue: a mode that drops off the list, or two entries that collapse onto
/// the same SDK value, would silently shrink what the app can exercise.
final class ScenariosTests: XCTestCase {

    func testEveryPresentationModeIsOffered() {
        let modes = ModeChoice.allCases.map(\.mode)
        XCTAssertEqual(modes.count, 7, "SDK has 7 presentation modes; the harness must offer all of them")
        XCTAssertTrue(modes.contains(.bottomSheet))
        XCTAssertTrue(modes.contains(.sheet))
        XCTAssertTrue(modes.contains(.fullScreen))
        XCTAssertTrue(modes.contains(.fitContent))
        XCTAssertTrue(modes.contains(.custom(height: 500)))
        XCTAssertTrue(modes.contains(.customFraction(0.7)))
        XCTAssertTrue(modes.contains(.floatingCard(dimOpacity: 0.35)))
    }

    func testModeChoicesMapToDistinctModesAndTitles() {
        let modes = ModeChoice.allCases.map(\.mode)
        for (index, mode) in modes.enumerated() {
            XCTAssertFalse(modes[(index + 1)...].contains(mode), "duplicate mode: \(mode)")
        }
        XCTAssertEqual(Set(ModeChoice.allCases.map(\.title)).count, ModeChoice.allCases.count)
    }

    func testOnlyCustomDetentModesFallBackOniOS15() {
        let fallback = ModeChoice.allCases.filter(\.fallsBackOniOS15)
        XCTAssertEqual(Set(fallback), [.fitContent, .customHeight, .customFraction])
    }

    func testThemeChoicesCoverPresetsAndACustomTheme() {
        XCTAssertNil(ThemeChoice.standard.theme.closeButtonBackgroundColor)
        XCTAssertEqual(ThemeChoice.darkCircle.theme.closeButtonIconColor, .white)
        XCTAssertEqual(ThemeChoice.lightCircle.theme.closeButtonBackgroundColor, .systemGray5)

        let custom = ThemeChoice.custom.theme
        XCTAssertEqual(custom.cornerRadius, 28)
        XCTAssertEqual(custom.closeButtonSize, 40)
        XCTAssertEqual(custom.closeButtonSymbolName, "xmark.circle")
    }

    func testBaseURLChoicesMatchTheSDKHosts() {
        XCTAssertEqual(BaseURLChoice.staging.urlString, "https://vbxstaging.com")
        XCTAssertEqual(BaseURLChoice.production.urlString, "https://vbx.to")
    }

    func testParamsAreOmittedWhenTheToggleIsOff() {
        let model = HarnessModel()
        model.sendUserParams = true
        XCTAssertEqual(model.params, Harness.userParams)
        model.sendUserParams = false
        XCTAssertTrue(model.params.isEmpty)
    }

    func testGlobalTogglesWriteThroughToTheSDK() {
        let model = HarnessModel()
        let original = VoiceboxKit.keepsScreenAwake
        defer { VoiceboxKit.keepsScreenAwake = original }

        model.keepsScreenAwake = !original
        XCTAssertEqual(VoiceboxKit.keepsScreenAwake, !original)
    }

    func testBaseURLPickerWritesThroughToTheSDK() {
        let model = HarnessModel()
        let original = VoiceboxKit.baseURL
        defer { VoiceboxKit.baseURL = original }

        model.baseURLChoice = .production
        XCTAssertEqual(VoiceboxKit.baseURL, "https://vbx.to")
        model.baseURLChoice = .staging
        XCTAssertEqual(VoiceboxKit.baseURL, "https://vbxstaging.com")
    }

    func testEventLogKeepsNewestFirstAndIsCapped() {
        let model = HarnessModel()
        for index in 0..<45 { model.record("event \(index)") }

        XCTAssertEqual(model.events.count, 40)
        XCTAssertEqual(model.events.first?.message, "event 44")
        XCTAssertEqual(model.events.last?.message, "event 5")
    }

    func testInvalidSessionURLIsReportedAsAFailure() {
        let model = HarnessModel()
        model.sessionURLString = "   "
        model.establishSession()

        XCTAssertEqual(model.events.first?.isFailure, true)
    }
}
