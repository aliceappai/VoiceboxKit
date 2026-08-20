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

    // MARK: - isRecorderPath (unavailable-handle guard)
    //
    // vbx-web answers an unknown or unavailable /@handle with a 303 to the directory root,
    // preserving the query string — so the redirect is indistinguishable from a normal load
    // unless the PATH is checked. Getting this predicate wrong has two bad failure modes:
    // too strict blocks real recorders, too loose renders the public directory browse page
    // inside a recorder sheet (which is exactly the bug this guard was added for).

    func testIsRecorderPathAcceptsOwnRecorder() {
        let url = URL(string: "https://vbx.to/@alice-feedback?utm_source=voiceboxkit")!
        XCTAssertTrue(VoiceboxURLBuilder.isRecorderPath(url, handle: "alice-feedback"))
    }

    func testIsRecorderPathIgnoresCase() {
        // vbx-web downcases the handle server-side, so a caller passing mixed case must
        // still match its own recorder rather than being treated as a dead handle.
        let url = URL(string: "https://vbx.to/@AliceFeedback")!
        XCTAssertTrue(VoiceboxURLBuilder.isRecorderPath(url, handle: "alicefeedback"))
        XCTAssertTrue(VoiceboxURLBuilder.isRecorderPath(url, handle: "AliceFeedback"))
    }

    func testIsRecorderPathRejectsDirectoryRoot() {
        // The actual observed failure: /@amd -> 303 -> / with the query string carried over.
        let url = URL(string: "https://vbx.to/?utm_source=voiceboxkit&utm_medium=ios_sdk")!
        XCTAssertFalse(VoiceboxURLBuilder.isRecorderPath(url, handle: "amd"))
    }

    func testIsRecorderPathRejectsADifferentHandle() {
        let url = URL(string: "https://vbx.to/@someone-else")!
        XCTAssertFalse(VoiceboxURLBuilder.isRecorderPath(url, handle: "alice-feedback"))
    }

    func testIsRecorderPathRejectsBlankDocument() {
        // The hot spare arrives holding about:blank and runs the same DOM-ready script; its
        // signal must never be mistaken for the recorder having painted.
        let url = URL(string: "about:blank")!
        XCTAssertFalse(VoiceboxURLBuilder.isRecorderPath(url, handle: "alice-feedback"))
    }

    func testIsRecorderPathAcceptsDeeperRecorderPaths() {
        // Matched by prefix so the recorder's own sub-paths still count as the recorder.
        let url = URL(string: "https://vbx.to/@alice-feedback/messages")!
        XCTAssertTrue(VoiceboxURLBuilder.isRecorderPath(url, handle: "alice-feedback"))
    }

    func testIsRecorderPathAllowsEverythingForABlankHandle() {
        // No handle means nothing to compare against; the guard must not block every
        // navigation in that case.
        let url = URL(string: "https://vbx.to/")!
        XCTAssertTrue(VoiceboxURLBuilder.isRecorderPath(url, handle: ""))
    }
}
