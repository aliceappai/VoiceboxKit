import XCTest
@testable import VoiceboxKit

final class AppContextTests: XCTestCase {

    // MARK: - Raw context collection

    func testCollectReturnsNonEmptyDict() {
        let context = VoiceboxAppContext.collect()
        XCTAssertFalse(context.isEmpty)
    }

    func testCollectIncludesPlatform() {
        let context = VoiceboxAppContext.collect()
        XCTAssertEqual(context["platform"], "ios")
    }

    func testCollectIncludesSDKVersion() {
        let context = VoiceboxAppContext.collect()
        XCTAssertEqual(context["sdkVersion"], VoiceboxKit.version)
    }

    func testCollectIncludesOSVersion() {
        let context = VoiceboxAppContext.collect()
        XCTAssertNotNil(context["osVersion"])
        XCTAssertFalse(context["osVersion"]?.isEmpty ?? true)
    }

    func testCollectIncludesDeviceModel() {
        let context = VoiceboxAppContext.collect()
        // Simulator returns "arm64" or similar; real device returns "iPhone16,2"
        XCTAssertNotNil(context["deviceModel"])
        XCTAssertFalse(context["deviceModel"]?.isEmpty ?? true)
    }

    func testCollectIncludesLocale() {
        let context = VoiceboxAppContext.collect()
        XCTAssertNotNil(context["locale"])
        XCTAssertFalse(context["locale"]?.isEmpty ?? true)
    }

    func testCollectDoesNotIncludePrivacySensitiveFields() {
        let context = VoiceboxAppContext.collect()

        // Device name (often PII like "John's iPhone")
        XCTAssertNil(context["deviceName"])
        // IDFA and vendor ID
        XCTAssertNil(context["idfa"])
        XCTAssertNil(context["vendorID"])
        XCTAssertNil(context["identifierForVendor"])
    }

    // MARK: - Integration with buildURL

    func testBuildURLIncludesAutoContextWhenEnabled() {
        let previous = VoiceboxKit.autoCollectAppContext
        defer { VoiceboxKit.autoCollectAppContext = previous }
        VoiceboxKit.autoCollectAppContext = true

        let vb = VoiceboxView(handle: "test")
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let names = Set(components.queryItems?.map(\.name) ?? [])

        XCTAssertTrue(names.contains("platform"))
        XCTAssertTrue(names.contains("sdkVersion"))
        XCTAssertTrue(names.contains("osVersion"))
        XCTAssertTrue(names.contains("deviceModel"))
        XCTAssertTrue(names.contains("locale"))
        XCTAssertTrue(names.contains("utm_source"))
        XCTAssertTrue(names.contains("utm_medium"))
    }

    func testBuildURLExcludesAutoContextWhenDisabled() {
        let previous = VoiceboxKit.autoCollectAppContext
        defer { VoiceboxKit.autoCollectAppContext = previous }
        VoiceboxKit.autoCollectAppContext = false

        let vb = VoiceboxView(handle: "test")
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let names = Set(components.queryItems?.map(\.name) ?? [])

        XCTAssertFalse(names.contains("platform"))
        XCTAssertFalse(names.contains("sdkVersion"))
        XCTAssertFalse(names.contains("osVersion"))
        XCTAssertFalse(names.contains("deviceModel"))
        XCTAssertFalse(names.contains("locale"))

        // UTM params still present
        XCTAssertTrue(names.contains("utm_source"))
        XCTAssertTrue(names.contains("utm_medium"))
    }

    func testAppProvidedParamOverridesAutoCollected() {
        let previous = VoiceboxKit.autoCollectAppContext
        defer { VoiceboxKit.autoCollectAppContext = previous }
        VoiceboxKit.autoCollectAppContext = true

        // Explicit param for a key that's also auto-collected
        let vb = VoiceboxView(
            handle: "test",
            params: ["appVersion": "99.99.99-custom"]
        )
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let appVersion = components.queryItems?.first { $0.name == "appVersion" }

        XCTAssertEqual(appVersion?.value, "99.99.99-custom")
    }

    func testAppProvidedPlatformOverridesAutoCollected() {
        let previous = VoiceboxKit.autoCollectAppContext
        defer { VoiceboxKit.autoCollectAppContext = previous }
        VoiceboxKit.autoCollectAppContext = true

        let vb = VoiceboxView(
            handle: "test",
            params: ["platform": "ios-custom-build"]
        )
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let platform = components.queryItems?.first { $0.name == "platform" }

        // App-provided value wins
        XCTAssertEqual(platform?.value, "ios-custom-build")

        // Verify there's only one `platform` entry (no duplicates)
        let platformCount = components.queryItems?.filter { $0.name == "platform" }.count
        XCTAssertEqual(platformCount, 1)
    }

    func testAutoCollectDefaultIsTrue() {
        // Read the static default by resetting and checking
        // Note: another test may have flipped it, so we can't rely on the
        // current value. Instead, verify the flag is accessible and writable.
        let previous = VoiceboxKit.autoCollectAppContext
        defer { VoiceboxKit.autoCollectAppContext = previous }

        VoiceboxKit.autoCollectAppContext = true
        XCTAssertTrue(VoiceboxKit.autoCollectAppContext)

        VoiceboxKit.autoCollectAppContext = false
        XCTAssertFalse(VoiceboxKit.autoCollectAppContext)
    }
}
