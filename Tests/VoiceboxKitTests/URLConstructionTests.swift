import XCTest
@testable import VoiceboxKit

final class URLConstructionTests: XCTestCase {

    private var previousAutoCollect: Bool = true

    override func setUp() {
        super.setUp()
        // Disable auto-collect so these tests only see user-provided params + UTM
        previousAutoCollect = VoiceboxKit.autoCollectAppContext
        VoiceboxKit.autoCollectAppContext = false
    }

    override func tearDown() {
        VoiceboxKit.autoCollectAppContext = previousAutoCollect
        super.tearDown()
    }

    func testBasicURL() {
        let vb = VoiceboxView(handle: "alice-feedback")
        let url = vb.buildURL()

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "vbx.to")
        XCTAssertEqual(url.path, "/@alice-feedback")
    }

    func testUTMParamsAlwaysPresent() {
        let vb = VoiceboxView(handle: "test")
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryItems = components.queryItems ?? []

        let utmSource = queryItems.first { $0.name == "utm_source" }
        let utmMedium = queryItems.first { $0.name == "utm_medium" }

        XCTAssertEqual(utmSource?.value, "voiceboxkit")
        XCTAssertEqual(utmMedium?.value, "ios_sdk")
    }

    func testParamsAppended() {
        let vb = VoiceboxView(
            handle: "alice-feedback",
            params: [
                "email": "jane@example.com",
                "userID": "usr_abc123",
            ]
        )
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryItems = components.queryItems ?? []

        let email = queryItems.first { $0.name == "email" }
        let userID = queryItems.first { $0.name == "userID" }

        XCTAssertEqual(email?.value, "jane@example.com")
        XCTAssertEqual(userID?.value, "usr_abc123")
    }

    func testParamsAreURLEncoded() {
        let vb = VoiceboxView(
            handle: "test",
            params: ["prompt": "How are you liking Alice?"]
        )
        let url = vb.buildURL()
        let urlString = url.absoluteString

        // Space should be percent-encoded (no raw spaces in URL)
        XCTAssertFalse(urlString.contains(" "))

        // The prompt value should be recoverable via URLComponents
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let prompt = components.queryItems?.first { $0.name == "prompt" }
        XCTAssertEqual(prompt?.value, "How are you liking Alice?")
    }

    func testLocationParam() {
        let vb = VoiceboxView(
            handle: "test",
            params: ["ll": "47.6062,-122.3321"]
        )
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let ll = components.queryItems?.first { $0.name == "ll" }

        XCTAssertEqual(ll?.value, "47.6062,-122.3321")
    }

    func testParamsAreSortedDeterministically() {
        let vb = VoiceboxView(
            handle: "test",
            params: [
                "zebra": "z",
                "alpha": "a",
                "middle": "m",
            ]
        )
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let names = components.queryItems?.map(\.name) ?? []

        // User params sorted alphabetically, then UTM params at the end
        XCTAssertEqual(names, ["alpha", "middle", "zebra", "utm_source", "utm_medium"])
    }

    func testEmptyParams() {
        let vb = VoiceboxView(handle: "test")
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        // Only UTM params should be present
        XCTAssertEqual(components.queryItems?.count, 2)
    }
}
