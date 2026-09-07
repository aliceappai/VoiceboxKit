import XCTest
import WebKit
import JavaScriptCore
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
    /// has to keep looking rather than reading once and giving up, and must stop as soon as
    /// it has one rather than polling on for two minutes.
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

    // MARK: - Delivery, not read

    /// THE regression this file exists for now: an id read while nothing is listening must
    /// not be recorded as reported.
    ///
    /// A warmed WebView runs `sessionUserScript` with no message handler registered — they
    /// are added in `VoiceboxViewController.setup` at adoption, and adoption does not
    /// re-navigate, so the script never runs again. When `post()` latched `lastSessionId`
    /// on the READ, that first warm read consumed the only report the host would ever get:
    /// every later call, including the one fired at `messageSubmitted`, returned early and
    /// the id never arrived. Recordings made in the app therefore stayed anonymous and no
    /// sign-in could claim them — silently, because every layer of that path fails quietly.
    ///
    /// Exercised through JavaScriptCore rather than a real WebView so the two states that
    /// matter — handler absent, then present, on ONE already-run script — are deterministic
    /// rather than a load race.
    func testAnIdReadWithNoHandlerIsReportedOnceOneAppears() {
        let context = makeSessionScriptHost(storedId: "psid-abc-123", handlerPresent: false)

        XCTAssertEqual(deliveredCount(context), 0,
                       "nothing can be delivered before a handler exists")
        XCTAssertEqual(context.objectForKeyedSubscript("intervals")?.toInt32(), 1,
                       "an undelivered id must leave the poll running, not end it")

        attachSessionHandler(to: context)
        let posted = context.evaluateScript("window.__voiceboxPostSessionId('adopt')")

        XCTAssertEqual(posted?.toBool(), true)
        XCTAssertEqual(deliveredCount(context), 1,
                       "the id must still be reportable — latching on the earlier read is the bug")
        XCTAssertEqual(deliveredId(context), "psid-abc-123")
    }

    /// The other half of the same rule: once an id HAS been delivered, repeat triggers stay
    /// quiet. `eventUserScript` fires on both recordingComplete and messageSubmitted, so
    /// without this the host would get the same id two or three times per recording.
    func testADeliveredIdIsNotSentAgain() {
        let context = makeSessionScriptHost(storedId: "psid-abc-123", handlerPresent: true)

        XCTAssertEqual(deliveredCount(context), 1, "delivered on the way in")
        XCTAssertEqual(context.objectForKeyedSubscript("intervals")?.toInt32(), 0,
                       "a delivered id ends the poll")

        context.evaluateScript("window.__voiceboxPostSessionId('event')")
        context.evaluateScript("window.__voiceboxPostSessionId('event')")

        XCTAssertEqual(deliveredCount(context), 1, "each distinct id is delivered once")
    }

    /// No id yet is not a failure — it is the first-time recorder, whose id vbx-web writes
    /// lazily. The script must keep polling and report whenever it appears.
    func testAMissingIdKeepsPolling() {
        let context = makeSessionScriptHost(storedId: nil, handlerPresent: true)

        XCTAssertEqual(deliveredCount(context), 0)
        XCTAssertEqual(context.objectForKeyedSubscript("intervals")?.toInt32(), 1)

        context.evaluateScript("window.__vbxStoredId = 'psid-late-999';")
        context.evaluateScript("window.__voiceboxPostSessionId('poll')")

        XCTAssertEqual(deliveredCount(context), 1)
        XCTAssertEqual(deliveredId(context), "psid-late-999")
    }

    // MARK: - Adoption nudge

    /// The poll caps at two minutes, so a warm page that sat longer has stopped looking by
    /// the time it is adopted. `VoiceboxViewController` therefore asks it to report once the
    /// handler is registered — and the ORDER is the whole point, so it is asserted on source
    /// (there is no runtime surface for "which line ran first").
    func testAdoptionNudgesTheScriptAfterRegisteringTheHandler() {
        let source = VoiceboxKitSourceReader.read("VoiceboxViewController.swift")
        guard let register = source.range(of: "add(self, name: Self.sessionMessageName)"),
              let nudge = source.range(of: "sessionRereadSnippet") else {
            return XCTFail("adoption must register the session handler and then nudge the page")
        }
        XCTAssertTrue(register.upperBound < nudge.lowerBound,
                      "nudging before the handler exists delivers the id to nobody — the original bug")
    }

    /// Evaluated against every WebView, including a fresh one still on `about:blank` that
    /// has never run the script, so it has to be guarded rather than assume the global.
    func testSessionRereadSnippetIsGuarded() {
        let context = JSContext()!
        context.evaluateScript("var window = {};")
        context.evaluateScript(VoiceboxWebScripts.sessionRereadSnippet)
        XCTAssertNil(context.exception, "the snippet must no-op on a page that never ran the script")
    }

    // MARK: - JS harness

    /// Runs the real `sessionUserScript` source against stubbed page globals.
    ///
    /// `window.__vbxStoredId` stands in for the vbx-web key so a test can make the id appear
    /// late, which is the normal case — the recorder writes it lazily.
    private func makeSessionScriptHost(storedId: String?, handlerPresent: Bool) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            XCTFail("JS exception: \(exception?.toString() ?? "unknown")")
        }

        let initialId = storedId.map { "'\($0)'" } ?? "null"
        context.evaluateScript("""
        var delivered = [];
        var intervals = 0;
        function setInterval(fn, ms) { intervals += 1; return intervals; }
        function clearInterval(id) { intervals -= 1; }
        var window = {
            __vbxStoredId: \(initialId),
            localStorage: { getItem: function (key) { return window.__vbxStoredId; } },
            sessionStorage: { getItem: function (key) { return null; } },
            location: { href: 'https://vbx.to/@acme' },
            addEventListener: function (type, fn) {},
            webkit: { messageHandlers: {} }
        };
        """)

        if handlerPresent { attachSessionHandler(to: context) }
        context.evaluateScript(sessionScriptSource())
        return context
    }

    private func attachSessionHandler(to context: JSContext) {
        context.evaluateScript("""
        window.webkit.messageHandlers.\(VoiceboxWebScripts.sessionMessageName) = {
            postMessage: function (message) { delivered.push(message); }
        };
        """)
    }

    private func sessionScriptSource() -> String {
        let scripts = VoiceboxWebScripts.makeConfiguration().userContentController.userScripts
        return scripts.first { $0.source.contains(VoiceboxWebScripts.profilesSessionStorageKey) }?.source ?? ""
    }

    private func deliveredCount(_ context: JSContext) -> Int {
        Int(context.evaluateScript("delivered.length")?.toInt32() ?? -1)
    }

    private func deliveredId(_ context: JSContext) -> String? {
        context.evaluateScript("delivered.length ? delivered[0].sessionId : null")?.toString()
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

    // MARK: - Session (establish / clear)

    /// The completion always runs, including on the "nothing stored" path — a caller
    /// chaining sign-out steps behind it must never be stranded.
    func testClearSessionCallsBackEvenWithNothingStored() {
        let done = expectation(description: "clear completed")
        VoiceboxKit.clearSession { done.fulfill() }
        wait(for: [done], timeout: 30)
    }

    /// A malformed `baseURL` has no host to match records against. It must no-op and still
    /// call back rather than hang a sign-out.
    func testClearSessionSurvivesAHostlessBaseURL() {
        let original = VoiceboxKit.baseURL
        defer { VoiceboxKit.baseURL = original }
        VoiceboxKit.baseURL = "not a url"

        let done = expectation(description: "clear completed")
        VoiceboxKit.clearSession { done.fulfill() }
        wait(for: [done], timeout: 30)
    }

    /// Clearing must take the COOKIE as well as the storage. A host that cleared one and
    /// forgot the other would leave the device signed in as the account that just left, or
    /// signed out but still accumulating recordings under the previous identity — and the
    /// only way to make that impossible is for one call to do both.
    func testClearSessionRemovesCookiesAndStorageTogether() {
        // Asserted on the data types the implementation asks WebKit to remove, because the
        // alternative — round-tripping a real cookie through a live data store — is exactly
        // the WebKit timing this suite already found to be flaky.
        let source = VoiceboxKitSourceReader.read("VoiceboxKit.swift")
        let clearBody = VoiceboxKitSourceReader.body(of: "clearSession", in: source)

        XCTAssertTrue(clearBody.contains("WKWebsiteDataTypeCookies"),
                      "clearSession must drop the recorder's session cookie")
        XCTAssertTrue(clearBody.contains("WKWebsiteDataTypeLocalStorage"),
                      "clearSession must drop the anonymous session id")
        XCTAssertTrue(clearBody.contains("WKWebsiteDataTypeSessionStorage"),
                      "sessionStorage holds the id too, as vbx-web's own reader assumes")
    }

    /// Both session methods reset the warm pool, and the ORDER differs on purpose:
    /// establishing warms afterwards so the new pages carry the new cookie, while clearing
    /// drops first so a page still holding the old id cannot write it back into the store
    /// being emptied.
    func testBothSessionMethodsResetTheWarmPool() {
        let source = VoiceboxKitSourceReader.read("VoiceboxKit.swift")

        let establish = VoiceboxKitSourceReader.body(of: "establishSession", in: source)
        XCTAssertTrue(establish.contains("resetWarmedWebViews"),
                      "a page warmed before a session rendered signed-out and stays that way")

        let clear = VoiceboxKitSourceReader.body(of: "clearSession", in: source)
        XCTAssertTrue(clear.contains("resetWarmedWebViews"))
        let resetIndex = clear.range(of: "resetWarmedWebViews")!.lowerBound
        let removeIndex = clear.range(of: "removeData")!.lowerBound
        XCTAssertTrue(resetIndex < removeIndex,
                      "clearSession must drop warmed pages BEFORE emptying the store")
    }

    /// Re-warming is the SDK's job, not the host's: only the cache knows what is in the
    /// pool, so a host asked to replay its own preloads would have to track them separately
    /// and remember to. This pins that the reset puts the pool back rather than emptying it.
    func testResetWarmedWebViewsRewarmsWhatItDropped() {
        VoiceboxKit.preload(handle: "reset-rewarm-handle")
        VoiceboxCache.shared.resetWarmedWebViews()

        // preload() hops to the main queue, so the re-warm is queued rather than immediate.
        let settled = expectation(description: "re-warm scheduled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 30)

        XCTAssertTrue(VoiceboxCache.shared.isWarming(handle: "reset-rewarm-handle"),
                      "a dropped handle must be warmed again, not silently lost")
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

/// Reads SDK source so a test can assert on a decision that has no observable runtime
/// surface — which data types a removal asks for, and the order two internal calls happen
/// in. Both are load-bearing and both are otherwise only visible by reading the file.
enum VoiceboxKitSourceReader {

    static func read(_ fileName: String) -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()  // VoiceboxKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let path = root
            .appendingPathComponent("Sources/VoiceboxKit")
            .appendingPathComponent(fileName)
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    /// Everything from a function's signature to the start of the next one. Crude on
    /// purpose — it only has to separate two adjacent methods in one known file.
    static func body(of functionName: String, in source: String) -> String {
        guard let start = source.range(of: "func \(functionName)(") else { return "" }
        let rest = source[start.upperBound...]
        guard let next = rest.range(of: "\n    public static func ") else { return String(rest) }
        return String(rest[..<next.lowerBound])
    }
}
