import XCTest
@testable import VoiceboxKit

/// Covers the reveal latch, which decides when the WebView stops being hidden behind the
/// loading skeleton.
///
/// The bug these pin down: the latch was one-shot per CONTROLLER, not per load, so it only
/// ever allowed ONE reveal per open. In `.floatingCard` the page paints the card *and* the
/// background, and `startLoading()` hides the WebView outright — so a second load cycle left
/// the user on a permanently shimmering, otherwise blank screen with only the × working.
///
/// A second load cycle is not a corner case. The recorder's own "Send another" button is
/// `onclick="window.location.reload()"` in vbx-web (`app/views/recorder/
/// _post_message_header.html.erb` and `_thank_you_content.html.erb`), and message submission
/// is a Turbo Stream replace that leaves the URL on `/@handle` — so the reload re-navigates
/// the main frame to the same recorder URL. That makes every "record → send → Send another"
/// run hit this path.
///
/// These are structural, reading SDK source the way `SessionCaptureTests` does. Driving the
/// real thing needs `viewDidLoad`, which calls `loadVoicebox()` and hits the network, and
/// both the latch and `startLoading()` are private. An earlier draft drove
/// `VoiceboxNavigationDelegate` against a live `WKWebView` instead: constructing one spins up
/// a WebContent process, which cost 26 s — longer than the rest of the suite put together —
/// for a test that passed with and without the fix.
final class RevealLatchTests: XCTestCase {

    // MARK: - The premise: a reload really is a second load cycle

    /// The navigation delegate reports loading for EVERY main-frame navigation, not just the
    /// first, which is what hands the controller a second `startLoading()`. If this ever
    /// became first-load-only, the latch reset below would be dead code.
    ///
    /// Note what is NOT here: `hasCompletedFirstLoad`. The delegate does gate its
    /// unavailable-handle check on that, deliberately — but gating the loading callback the
    /// same way would resurrect this bug from the other side.
    func testEveryNavigationReportsLoading() {
        let source = VoiceboxKitSourceReader.read("VoiceboxNavigationDelegate.swift")
        let body = Self.body(after: "didStartProvisionalNavigation navigation: WKNavigation!)",
                             in: source)

        XCTAssertFalse(body.isEmpty, "could not find didStartProvisionalNavigation")
        XCTAssertTrue(body.contains("onLoadingStateChanged?(true)"),
                      "every navigation must report that it started loading")
        XCTAssertFalse(body.contains("hasCompletedFirstLoad"),
                      "the loading callback must not be gated on the first load — a reload "
                      + "has to report its own cycle")
    }

    // MARK: - The fix

    /// Whatever hides the content owes a reveal, so `startLoading()` — the ONE place the
    /// WebView is hidden — has to clear the latch.
    func testStartLoadingClearsTheRevealLatch() {
        let source = VoiceboxKitSourceReader.read("VoiceboxViewController.swift")
        let body = Self.body(after: "func startLoading()", in: source)

        XCTAssertFalse(body.isEmpty, "could not find startLoading() — did it get renamed?")
        XCTAssertTrue(body.contains("didReveal = false"),
                      "startLoading() hides the WebView, so it must clear didReveal or the "
                      + "next load can never reveal it again")
    }

    /// The latch must be cleared where the content is HIDDEN, not inside `revealContent`.
    /// Clearing it on the way out would restore the double-reveal it exists to prevent:
    /// DOM-ready and `didFinish` both fire for one navigation, and the second would replay
    /// the entrance animation over an already-visible card.
    func testLatchIsClearedOnlyWhereContentIsHidden() {
        let source = VoiceboxKitSourceReader.read("VoiceboxViewController.swift")

        XCTAssertTrue(source.contains("private var didReveal = false"),
                      "declaration moved — the count below assumes it exists")

        // One for the declaration, one for the reset in startLoading(). Nothing else.
        let clears = source.components(separatedBy: "didReveal = false").count - 1
        XCTAssertEqual(clears, 2,
                       "expected exactly the declaration plus startLoading()'s reset; "
                       + "found \(clears) assignments of didReveal = false")

        let reveal = Self.body(after: "func revealContent(", in: source)
        XCTAssertFalse(reveal.isEmpty, "could not find revealContent()")
        XCTAssertFalse(reveal.contains("didReveal = false"),
                       "revealContent must keep latching, not unlatch — it is called twice "
                       + "per navigation (DOM-ready and didFinish)")
    }

    // MARK: - Helper

    /// Text between the first `{` at or after `signature` and its matching `}`. Crude brace
    /// counting on purpose — it only has to isolate known methods whose bodies hold no braces
    /// inside string literals. Takes a signature fragment rather than a bare name because the
    /// navigation delegate's three methods are all called `webView`.
    private static func body(after signature: String, in source: String) -> String {
        guard let found = source.range(of: signature) else { return "" }
        var depth = 0
        var body = ""
        for character in source[found.lowerBound...] {
            if character == "{" {
                depth += 1
                if depth == 1 { continue }
            }
            if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            if depth >= 1 { body.append(character) }
        }
        return body
    }
}
