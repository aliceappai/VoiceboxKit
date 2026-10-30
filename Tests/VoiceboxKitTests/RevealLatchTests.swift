import XCTest
@testable import VoiceboxKit

/// Covers the reveal latch and what may cover the WebView, which together decide when the
/// recorder's card is on screen.
///
/// The bug these pin down: the app hid the WebView on EVERY page load but only ever uncovered
/// it once per open. In `.floatingCard` the page paints the card *and* the background, so a
/// second load cycle left the user on a permanently shimmering, otherwise blank screen with
/// only the × working.
///
/// A second load cycle is not a corner case. The recorder's own "Send another" button is
/// `onclick="window.location.reload()"` in vbx-web (`app/views/recorder/
/// _post_message_header.html.erb` and `_thank_you_content.html.erb`), and message submission
/// is a Turbo Stream replace that leaves the URL on `/@handle` — so the reload re-navigates
/// the main frame to the same recorder URL. That makes every "record → send → Send another"
/// run hit this path.
///
/// Three rules come out of it, one test each:
///
/// 1. Only the FIRST load may cover the screen. A re-navigation is the same recorder before
///    and after, and WebKit holds the old page painted until the new one commits, so there is
///    nothing to hide. Android does the same — its `onPageStarted` raises no skeleton.
/// 2. A later load still runs the per-document background strip. That is page setup, not part
///    of the reveal, and skipping it leaves two backgrounds painting at different scaling.
/// 3. Nothing ever clears the latch — which is safe only for as long as rule 1 holds.
///
/// These are structural, reading SDK source the way `SessionCaptureTests` does. Driving the
/// real thing needs `viewDidLoad`, which calls `loadVoicebox()` and hits the network, and both
/// the latch and `startLoading()` are private. An earlier draft drove
/// `VoiceboxNavigationDelegate` against a live `WKWebView` instead: constructing one spins up
/// a WebContent process, which cost 26 s — longer than the rest of the suite put together —
/// for a test that passed with and without the fix.
final class RevealLatchTests: XCTestCase {

    // MARK: - The premise: a reload really is a second load cycle

    /// The navigation delegate reports loading for EVERY main-frame navigation, not just the
    /// first. That is what the gate below has to recognise; if this ever became
    /// first-load-only, the gate would be dead code and this file would be describing a
    /// problem the SDK no longer has.
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

    // MARK: - Rule 1: only the first load covers the screen

    /// A re-navigation keeps the current card up. In `.floatingCard` the page paints the
    /// background too, so covering it blanks the whole screen rather than just the card.
    func testOnlyTheFirstLoadCoversTheScreen() {
        let source = VoiceboxKitSourceReader.read("VoiceboxViewController.swift")
        let body = Self.body(after: "func handleLoadingState(", in: source)

        XCTAssertFalse(body.isEmpty, "could not find handleLoadingState()")

        guard let guardIndex = body.range(of: "guard !didReveal")?.lowerBound,
              let startIndex = body.range(of: "startLoading()")?.lowerBound
        else {
            return XCTFail("handleLoadingState must gate startLoading() on didReveal, or "
                           + "every reload blanks the card it is replacing")
        }

        XCTAssertTrue(guardIndex < startIndex,
                      "the gate has to precede startLoading() or it cannot stop it")
    }

    // MARK: - Rule 2: a later load still does its page setup

    /// A load that was never covered still needs its new document's background stripped. Skip
    /// it and the page's own CSS background paints over the native layer at different scaling,
    /// so the background shifts as the card swaps — "the card jumps on Send another".
    func testALatchedLoadStillStripsTheNewDocumentsBackground() {
        let source = VoiceboxKitSourceReader.read("VoiceboxViewController.swift")
        let reveal = Self.body(after: "func revealContent(", in: source)

        XCTAssertFalse(reveal.isEmpty, "could not find revealContent()")
        XCTAssertTrue(reveal.contains("playFloatingCardEntrance(animated: false)"),
                      "the latched path must still run the per-document page setup, or a "
                      + "reload paints two backgrounds and the card appears to jump")
    }

    // MARK: - Rule 3: the latch is never cleared

    /// Nothing clears the latch, and that is load-bearing rather than incidental: it is safe
    /// only because nothing covers the content after the first load. Clearing it inside
    /// `revealContent` in particular would restore the double-reveal it exists to prevent —
    /// DOM-ready and `didFinish` both fire for one navigation, and the second would replay the
    /// entrance over an already-visible card.
    ///
    /// If a clear ever becomes necessary, the thing to re-read is
    /// `testOnlyTheFirstLoadCoversTheScreen`: the two rules only make sense together.
    func testTheLatchIsNeverCleared() {
        let source = VoiceboxKitSourceReader.read("VoiceboxViewController.swift")

        XCTAssertTrue(source.contains("private var didReveal = false"),
                      "declaration moved — the count below assumes it exists")

        // The declaration, and nothing else.
        let clears = source.components(separatedBy: "didReveal = false").count - 1
        XCTAssertEqual(clears, 1,
                       "the latch is never cleared — a clear means something covers the "
                       + "content again, so re-check that nothing can be left hidden behind "
                       + "a latched reveal; found \(clears) occurrences")

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
