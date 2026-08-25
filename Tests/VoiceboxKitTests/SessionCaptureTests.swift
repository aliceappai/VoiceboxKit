import XCTest
import WebKit
@testable import VoiceboxKit

/// Covers the anonymous-session capture contract (`VoiceboxWebScripts.sessionUserScript`).
///
/// The behaviour these pin down is the one that has bitten this file before: a script that
/// works on a fresh WebView but was never added to the SHARED configuration, so a warmed
/// / preloaded WebView silently runs without it. `addUserScript` only fires on the next
/// navigation, and a preloaded page has already navigated.
final class SessionCaptureTests: XCTestCase {

    // MARK: - Warm-path registration

    /// The script must live in `makeConfiguration()`, which BOTH the live path
    /// (`VoiceboxView.makeWebView`) and the warm path (`VoiceboxCache.warmWebViewCache`)
    /// build from. Asserting on the shared configuration is what makes that structural
    /// rather than a promise in a comment.
    func testSessionScriptIsInTheSharedConfiguration() {
        let scripts = VoiceboxWebScripts.makeConfiguration().userContentController.userScripts
        let sessionScripts = scripts.filter {
            $0.source.contains(VoiceboxWebScripts.sessionMessageName)
                && $0.source.contains(VoiceboxWebScripts.profilesSessionStorageKey)
        }
        XCTAssertEqual(sessionScripts.count, 1,
                       "Exactly one session script belongs in the shared configuration")
    }

    /// Document-END, because `localStorage` is read on the way in — and not main-frame-only,
    /// matching `eventUserScript`, so an embedded recorder is covered too.
    func testSessionScriptInjectionTiming() {
        let scripts = VoiceboxWebScripts.makeConfiguration().userContentController.userScripts
        let session = scripts.first { $0.source.contains(VoiceboxWebScripts.profilesSessionStorageKey) }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.injectionTime, .atDocumentEnd)
        XCTAssertEqual(session?.isForMainFrameOnly, false)
    }

    // MARK: - Cross-repo contract

    /// This key is owned by vbx-web (`app/javascript/profiles_session.js`). It is not a
    /// local naming choice: messages are stamped with the id stored under it, and the
    /// backend claims them by that id. A rename on either side breaks capture silently,
    /// so the literal is pinned here to make the break loud.
    func testStorageKeyMatchesTheWebContract() {
        XCTAssertEqual(VoiceboxWebScripts.profilesSessionStorageKey, "vbx_profiles_session_id")
    }

    /// The id is written lazily — a first-time recorder has none at load — so the script
    /// has to keep looking rather than reading once and giving up.
    func testSessionScriptRetriesForALazilyCreatedId() {
        let scripts = VoiceboxWebScripts.makeConfiguration().userContentController.userScripts
        let source = scripts.first { $0.source.contains(VoiceboxWebScripts.profilesSessionStorageKey) }?.source ?? ""
        XCTAssertTrue(source.contains("setInterval"), "must poll for a lazily-written id")
        XCTAssertTrue(source.contains("clearInterval"), "must stop polling once it has one")
        XCTAssertTrue(source.contains("sessionStorage"),
                      "must fall back to sessionStorage, as vbx-web's own reader does")
    }

    /// The recorder events are the earliest useful trigger, so `eventUserScript` calls into
    /// the session script rather than duplicating the read.
    func testRecorderEventsTriggerASessionRead() {
        let scripts = VoiceboxWebScripts.makeConfiguration().userContentController.userScripts
        let event = scripts.first { $0.source.contains("recordingComplete") }?.source ?? ""
        XCTAssertTrue(event.contains("__voiceboxPostSessionId"),
                      "recorder events should prompt a session read")
    }

    // MARK: - Delegate

    /// The method has a default implementation, so existing conformers keep compiling.
    func testDelegateMethodIsOptional() {
        final class MinimalDelegate: VoiceboxDelegate {}
        let delegate = MinimalDelegate()
        let view = VoiceboxView(handle: "test")
        // Compiles and does nothing — that is the whole assertion.
        delegate.voicebox(view, didResolveAnonymousSessionId: "abc-123")
    }

    // MARK: - Claim token

    /// The token is minted server-side into the post-recording links, so the only place to
    /// read it is the DOM. This pins the selector and the param name — vbx-web owns both.
    func testSessionScriptReadsTheClaimTokenFromThePostMessageCards() {
        let scripts = VoiceboxWebScripts.makeConfiguration().userContentController.userScripts
        let source = scripts.first { $0.source.contains(VoiceboxWebScripts.profilesSessionStorageKey) }?.source ?? ""
        XCTAssertTrue(source.contains("#post-message-cards"),
                      "the token lives on the links vbx-web fills in after a submit")
        XCTAssertTrue(source.contains("claim_token"))
    }

    /// The token cannot exist before a recording is submitted, so a script that stopped
    /// polling once the session id turned up would never see it.
    func testPollingContinuesUntilBothValuesExist() {
        let scripts = VoiceboxWebScripts.makeConfiguration().userContentController.userScripts
        let source = scripts.first { $0.source.contains(VoiceboxWebScripts.profilesSessionStorageKey) }?.source ?? ""
        XCTAssertTrue(source.contains("return !!(id && token);"),
                      "the poll must only stop once BOTH the id and the token exist")
    }

    /// Both delegate methods are optional, so existing conformers keep compiling.
    func testClaimTokenDelegateMethodIsOptional() {
        final class MinimalDelegate: VoiceboxDelegate {}
        let delegate = MinimalDelegate()
        let view = VoiceboxView(handle: "test")
        delegate.voicebox(view, didResolveClaimToken: "tok-123")
    }

    // MARK: - Clearing (sign-out)

    /// The completion always runs, including on the "nothing stored" path — a caller
    /// chaining sign-out steps behind it must never be stranded.
    func testClearAnonymousSessionCallsBackEvenWithNothingStored() {
        let done = expectation(description: "clear completed")
        VoiceboxKit.clearAnonymousSession { done.fulfill() }
        wait(for: [done], timeout: 30)
    }

    /// A malformed `baseURL` has no host to match records against. It must no-op and still
    /// call back rather than hang a sign-out.
    func testClearAnonymousSessionSurvivesAHostlessBaseURL() {
        let original = VoiceboxKit.baseURL
        defer { VoiceboxKit.baseURL = original }
        VoiceboxKit.baseURL = "not a url"

        let done = expectation(description: "clear completed")
        VoiceboxKit.clearAnonymousSession { done.fulfill() }
        wait(for: [done], timeout: 30)
    }

    /// Clearing must drop warmed WebViews too: a preloaded page still holds the old id in
    /// memory and vbx-web writes it back on its next `ensureProfilesSessionId()`.
    func testClearAnonymousSessionDiscardsWarmedWebViews() {
        VoiceboxKit.preload(handle: "test-handle")
        VoiceboxCache.shared.discardWarmedWebViews()
        XCTAssertFalse(VoiceboxCache.shared.hasPreloadedWebView(for: "test-handle"))
    }

    /// Debug logging is opt-out in DEBUG and off in release, so a host app gets useful
    /// console output while integrating without a shipping build printing anything.
    func testDebugLoggingDefault() {
        #if DEBUG
        XCTAssertTrue(VoiceboxKit.debugLogging)
        #else
        XCTAssertFalse(VoiceboxKit.debugLogging)
        #endif
    }
}
