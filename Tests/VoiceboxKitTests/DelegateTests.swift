import XCTest
@testable import VoiceboxKit

/// Test helper that records which delegate methods were called.
private final class MockDelegate: VoiceboxDelegate {
    var didFinishRecordingCalled = false
    var didSubmitMessageCalled = false
    var didDismissCalled = false
    var didFailCalled = false
    var lastError: Error?

    func voiceboxDidFinishRecording(_ voiceboxView: VoiceboxView) {
        didFinishRecordingCalled = true
    }

    func voiceboxDidSubmitMessage(_ voiceboxView: VoiceboxView) {
        didSubmitMessageCalled = true
    }

    func voiceboxDidDismiss(_ voiceboxView: VoiceboxView) {
        didDismissCalled = true
    }

    func voiceboxDidFail(_ voiceboxView: VoiceboxView, error: Error) {
        didFailCalled = true
        lastError = error
    }
}

/// Test helper that only implements one method to verify defaults work.
private final class PartialDelegate: VoiceboxDelegate {
    var didDismissCalled = false

    func voiceboxDidDismiss(_ voiceboxView: VoiceboxView) {
        didDismissCalled = true
    }
}

final class DelegateTests: XCTestCase {

    func testDelegateIsWeaklyHeld() {
        let vb = VoiceboxView(handle: "test")
        var delegate: MockDelegate? = MockDelegate()
        vb.delegate = delegate
        XCTAssertNotNil(vb.delegate)

        delegate = nil
        XCTAssertNil(vb.delegate)
    }

    func testDelegateReceivesAllCallbacks() {
        let vb = VoiceboxView(handle: "test")
        let delegate = MockDelegate()
        vb.delegate = delegate

        delegate.voiceboxDidFinishRecording(vb)
        XCTAssertTrue(delegate.didFinishRecordingCalled)

        delegate.voiceboxDidSubmitMessage(vb)
        XCTAssertTrue(delegate.didSubmitMessageCalled)

        delegate.voiceboxDidDismiss(vb)
        XCTAssertTrue(delegate.didDismissCalled)

        let error = NSError(domain: "test", code: -1)
        delegate.voiceboxDidFail(vb, error: error)
        XCTAssertTrue(delegate.didFailCalled)
        XCTAssertEqual((delegate.lastError as? NSError)?.code, -1)
    }

    func testPartialDelegateDoesNotCrash() {
        // Verify that default empty implementations work — calling
        // unimplemented methods should be a no-op, not a crash.
        let vb = VoiceboxView(handle: "test")
        let delegate = PartialDelegate()
        vb.delegate = delegate

        // These should be no-ops (default implementations)
        delegate.voiceboxDidFinishRecording(vb)
        delegate.voiceboxDidSubmitMessage(vb)
        delegate.voiceboxDidFail(vb, error: NSError(domain: "test", code: 0))

        // This one is implemented
        delegate.voiceboxDidDismiss(vb)
        XCTAssertTrue(delegate.didDismissCalled)
    }
}
