import XCTest
@testable import VoiceboxKit

final class ThemeTests: XCTestCase {

    // MARK: - Defaults (all nil)

    func testDefaultValuesAreAllNil() {
        let theme = VoiceboxTheme()

        XCTAssertNil(theme.cornerRadius)
        XCTAssertNil(theme.backgroundColor)
        XCTAssertNil(theme.closeButtonIconColor)
        XCTAssertNil(theme.closeButtonBackgroundColor)
        XCTAssertNil(theme.closeButtonSize)
        XCTAssertNil(theme.closeButtonSymbolName)
    }

    // MARK: - Resolved Defaults

    func testResolvedDefaults() {
        let theme = VoiceboxTheme()

        XCTAssertEqual(theme.resolvedCornerRadius, 16)
        XCTAssertEqual(theme.resolvedBackgroundColor, .systemBackground)
        XCTAssertEqual(theme.resolvedCloseButtonIconColor, .label)
        XCTAssertEqual(theme.resolvedCloseButtonSize, 32)
        XCTAssertEqual(theme.resolvedCloseButtonSymbolName, "xmark")
    }

    // MARK: - Custom Values Override Defaults

    func testCustomValues() {
        let theme = VoiceboxTheme(
            cornerRadius: 24,
            backgroundColor: .black,
            closeButtonIconColor: .white,
            closeButtonBackgroundColor: .red,
            closeButtonSize: 44,
            closeButtonSymbolName: "xmark.circle.fill"
        )

        XCTAssertEqual(theme.cornerRadius, 24)
        XCTAssertEqual(theme.backgroundColor, .black)
        XCTAssertEqual(theme.closeButtonIconColor, .white)
        XCTAssertEqual(theme.closeButtonBackgroundColor, .red)
        XCTAssertEqual(theme.closeButtonSize, 44)
        XCTAssertEqual(theme.closeButtonSymbolName, "xmark.circle.fill")

        // Resolved values should match the custom values
        XCTAssertEqual(theme.resolvedCornerRadius, 24)
        XCTAssertEqual(theme.resolvedBackgroundColor, .black)
        XCTAssertEqual(theme.resolvedCloseButtonIconColor, .white)
        XCTAssertEqual(theme.resolvedCloseButtonSize, 44)
        XCTAssertEqual(theme.resolvedCloseButtonSymbolName, "xmark.circle.fill")
    }

    // MARK: - Partial Override

    func testPartialOverrideOnlySetsSpecifiedProperties() {
        // Only override the close button background — everything else stays nil
        let theme = VoiceboxTheme(closeButtonBackgroundColor: .systemBlue)

        // Explicit value
        XCTAssertEqual(theme.closeButtonBackgroundColor, .systemBlue)

        // All others stay nil (unset)
        XCTAssertNil(theme.cornerRadius)
        XCTAssertNil(theme.backgroundColor)
        XCTAssertNil(theme.closeButtonIconColor)
        XCTAssertNil(theme.closeButtonSize)
        XCTAssertNil(theme.closeButtonSymbolName)

        // But resolved values fall back to SDK defaults
        XCTAssertEqual(theme.resolvedCornerRadius, 16)
        XCTAssertEqual(theme.resolvedBackgroundColor, .systemBackground)
        XCTAssertEqual(theme.resolvedCloseButtonIconColor, .label)
        XCTAssertEqual(theme.resolvedCloseButtonSize, 32)
        XCTAssertEqual(theme.resolvedCloseButtonSymbolName, "xmark")
    }

    // MARK: - Mutation

    func testThemeIsMutable() {
        var theme = VoiceboxTheme()
        XCTAssertNil(theme.cornerRadius)

        theme.cornerRadius = 8
        theme.closeButtonBackgroundColor = .systemBlue
        theme.closeButtonIconColor = .white

        XCTAssertEqual(theme.cornerRadius, 8)
        XCTAssertEqual(theme.closeButtonBackgroundColor, .systemBlue)
        XCTAssertEqual(theme.closeButtonIconColor, .white)

        // Unset a previously-set value
        theme.cornerRadius = nil
        XCTAssertNil(theme.cornerRadius)
        XCTAssertEqual(theme.resolvedCornerRadius, 16)  // back to default
    }

    // MARK: - Presets

    func testPlainPreset() {
        let theme = VoiceboxTheme.plain
        XCTAssertNil(theme.closeButtonBackgroundColor)
        XCTAssertNil(theme.closeButtonIconColor)  // nil → resolves to .label
        XCTAssertEqual(theme.resolvedCloseButtonIconColor, .label)
    }

    func testDarkCirclePreset() {
        let theme = VoiceboxTheme.darkCircle
        XCTAssertNotNil(theme.closeButtonBackgroundColor)
        XCTAssertEqual(theme.closeButtonIconColor, .white)
    }

    func testLightCirclePreset() {
        let theme = VoiceboxTheme.lightCircle
        XCTAssertNotNil(theme.closeButtonBackgroundColor)
        XCTAssertEqual(theme.closeButtonIconColor, .label)
    }
}
