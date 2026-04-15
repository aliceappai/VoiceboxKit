import XCTest
@testable import VoiceboxKit

final class VoiceboxViewTests: XCTestCase {

    private var previousAutoCollect: Bool = true

    override func setUp() {
        super.setUp()
        previousAutoCollect = VoiceboxKit.autoCollectAppContext
        VoiceboxKit.autoCollectAppContext = false
    }

    override func tearDown() {
        VoiceboxKit.autoCollectAppContext = previousAutoCollect
        super.tearDown()
    }

    // MARK: - Default Values

    func testDefaultPresentationMode() {
        let vb = VoiceboxView(handle: "test")
        XCTAssertEqual(vb.presentationMode, .bottomSheet)
    }

    func testDefaultShowCloseButton() {
        let vb = VoiceboxView(handle: "test")
        XCTAssertTrue(vb.showCloseButton)
    }

    func testDefaultDelegateIsNil() {
        let vb = VoiceboxView(handle: "test")
        XCTAssertNil(vb.delegate)
    }

    func testDefaultAutoGrantMicPermissionIsNil() {
        let vb = VoiceboxView(handle: "test")
        XCTAssertNil(vb.autoGrantMicPermission)
    }

    func testDefaultParamsEmpty() {
        let vb = VoiceboxView(handle: "test")
        XCTAssertTrue(vb.params.isEmpty)
    }

    // MARK: - Presentation Mode Assignment

    func testPresentationModeAssignment() {
        let vb = VoiceboxView(handle: "test")

        vb.presentationMode = .fullScreen
        XCTAssertEqual(vb.presentationMode, .fullScreen)

        vb.presentationMode = .sheet
        XCTAssertEqual(vb.presentationMode, .sheet)

        vb.presentationMode = .fitContent
        XCTAssertEqual(vb.presentationMode, .fitContent)

        vb.presentationMode = .bottomSheet
        XCTAssertEqual(vb.presentationMode, .bottomSheet)
    }

    // MARK: - Mic Permission Resolution

    func testEffectiveAutoGrantMicDefaultsToGlobal() {
        let previousGlobal = VoiceboxKit.autoGrantMicPermission
        defer { VoiceboxKit.autoGrantMicPermission = previousGlobal }

        let vb = VoiceboxView(handle: "test")

        VoiceboxKit.autoGrantMicPermission = false
        XCTAssertFalse(vb.effectiveAutoGrantMicPermission)

        VoiceboxKit.autoGrantMicPermission = true
        XCTAssertTrue(vb.effectiveAutoGrantMicPermission)
    }

    func testEffectiveAutoGrantMicInstanceOverridesGlobal() {
        let previousGlobal = VoiceboxKit.autoGrantMicPermission
        defer { VoiceboxKit.autoGrantMicPermission = previousGlobal }

        let vb = VoiceboxView(handle: "test")

        // Global = false, instance = true → should be true
        VoiceboxKit.autoGrantMicPermission = false
        vb.autoGrantMicPermission = true
        XCTAssertTrue(vb.effectiveAutoGrantMicPermission)

        // Global = true, instance = false → should be false
        VoiceboxKit.autoGrantMicPermission = true
        vb.autoGrantMicPermission = false
        XCTAssertFalse(vb.effectiveAutoGrantMicPermission)
    }

    // MARK: - Handle Stored Correctly

    func testHandleStoredAsProvided() {
        let vb = VoiceboxView(handle: "alice-feedback")
        XCTAssertEqual(vb.handle, "alice-feedback")
    }

    func testParamsStoredAsProvided() {
        let params = ["email": "test@example.com", "userID": "123"]
        let vb = VoiceboxView(handle: "test", params: params)
        XCTAssertEqual(vb.params, params)
    }

    // MARK: - URL Construction Edge Cases

    func testURLContainsAtSymbol() {
        let vb = VoiceboxView(handle: "my-handle")
        let url = vb.buildURL()
        XCTAssertTrue(url.absoluteString.contains("/@my-handle"))
    }

    func testURLWithSpecialCharactersInParams() {
        let vb = VoiceboxView(
            handle: "test",
            params: ["name": "John & Jane", "tag": "a=b"]
        )
        let url = vb.buildURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let name = components.queryItems?.first { $0.name == "name" }
        let tag = components.queryItems?.first { $0.name == "tag" }

        XCTAssertEqual(name?.value, "John & Jane")
        XCTAssertEqual(tag?.value, "a=b")
    }

    func testURLWithEmojiInParams() {
        let vb = VoiceboxView(
            handle: "test",
            params: ["prompt": "How's it going? 👋"]
        )
        let url = vb.buildURL()

        // No raw emoji in URL string
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let prompt = components.queryItems?.first { $0.name == "prompt" }
        XCTAssertEqual(prompt?.value, "How's it going? 👋")
    }
}
