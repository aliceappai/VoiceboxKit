import XCTest
import WebKit
@testable import VoiceboxKit

/// Covers how long a recorder lives after it closes, and what its page sees when it does.
///
/// The bug these pin down: `VoiceboxViewController` registered ITSELF as its WebView's
/// script message handler. `WKUserContentController` retains its handlers, and the
/// controller retains the WebView that owns the content controller, so every recorder ever
/// opened stayed alive after closing — the controller, its `WKWebView` and the page's
/// WebContent process, with the recorder's JavaScript still running. Memory grew with every
/// open, and a recorder closed mid-recording never unloaded, so vbx-web's `pagehide` "leave"
/// beacon never went out and the take sat `capturing` until the server's sweeper found it.
///
/// Two rules come out of it:
///
/// 1. Nothing the WebView owns may retain the controller — handlers go through
///    `WeakScriptMessageHandler`.
/// 2. A real dismissal unloads the page (so it gets `pagehide` with `persisted: false`), and a
///    disappearance that is coming back does not.
///
/// Rule 1 is driven for real against a `WKUserContentController`, which needs no WebView. The
/// controller itself is never loaded here: `viewDidLoad` asks for microphone permission
/// (fatal in a test host with no usage description) and starts a network load, and
/// constructing a `WKWebView` launches a WebContent process — see `RevealLatchTests` for what
/// that cost. Rule 2 is asserted on source, the way `RevealLatchTests` does, because the
/// signals it reads (`isBeingDismissed`, SwiftUI's dismantle) only exist mid-transition.
final class ControllerLifetimeTests: XCTestCase {

    // MARK: - Rule 1: nothing retains the controller

    /// THE regression. The test holds the content controller itself, which is strictly more
    /// than the cycle ever did, so the controller can only go away if registration never
    /// retained it.
    @MainActor
    func testRegisteredHandlersDoNotRetainTheController() {
        let contentController = WKUserContentController()
        weak var weakController: VoiceboxViewController?

        autoreleasepool {
            let controller = VoiceboxViewController(voiceboxView: VoiceboxView(handle: "test"))
            controller.registerScriptMessageHandlers(on: contentController)
            weakController = controller
        }

        XCTAssertNil(weakController,
                     "the content controller kept the recorder alive — every recorder ever "
                     + "opened would leak with its WebView and WebContent process")
    }

    /// `.fitContent` registers one more handler than the other modes; it must go through the
    /// proxy like the rest.
    @MainActor
    func testFitContentHandlersDoNotRetainTheControllerEither() {
        let contentController = WKUserContentController()
        weak var weakController: VoiceboxViewController?

        autoreleasepool {
            let view = VoiceboxView(handle: "test")
            view.presentationMode = .fitContent
            let controller = VoiceboxViewController(voiceboxView: view)
            controller.registerScriptMessageHandlers(on: contentController)
            weakController = controller
        }

        XCTAssertNil(weakController)
    }

    /// Unregistering lets the same names be registered again — `WKUserContentController`
    /// raises on a duplicate name, so a removal that missed one would crash a recorder that is
    /// shown again after being unloaded.
    @MainActor
    func testUnregisteringClearsEveryNameForReRegistration() {
        let contentController = WKUserContentController()
        let view = VoiceboxView(handle: "test")
        view.presentationMode = .fitContent
        let controller = VoiceboxViewController(voiceboxView: view)

        controller.registerScriptMessageHandlers(on: contentController)
        controller.unregisterScriptMessageHandlers(from: contentController)
        controller.registerScriptMessageHandlers(on: contentController)
        controller.unregisterScriptMessageHandlers(from: contentController)
    }

    /// No source path may register `self` directly again. The runtime tests above cover the
    /// method that registers today; this covers a new call site added beside it.
    func testNoControllerRegistersItselfAsAScriptMessageHandler() {
        let source = VoiceboxKitSourceReader.read("VoiceboxViewController.swift")
        XCTAssertFalse(source.isEmpty, "could not read VoiceboxViewController.swift")
        XCTAssertFalse(source.contains(".add(self"),
                       "register through WeakScriptMessageHandler — adding self is a retain cycle")
    }

    // MARK: - The proxy

    @MainActor
    func testProxyForwardsMessagesToItsTarget() {
        let target = RecordingHandler()
        let proxy = WeakScriptMessageHandler(target: target)
        let contentController = WKUserContentController()

        proxy.userContentController(contentController, didReceive: FakeScriptMessage(name: "voiceboxEvent", body: "dismiss"))

        XCTAssertEqual(target.received.map(\.name), ["voiceboxEvent"])
        XCTAssertEqual(target.received.first?.body as? String, "dismiss")
    }

    @MainActor
    func testProxyDoesNotRetainItsTarget() {
        weak var weakTarget: RecordingHandler?
        var proxy: WeakScriptMessageHandler?

        autoreleasepool {
            let target = RecordingHandler()
            proxy = WeakScriptMessageHandler(target: target)
            weakTarget = target
        }

        XCTAssertNil(weakTarget, "the proxy kept its target alive — that is the cycle it exists to break")
        XCTAssertNil(proxy?.target)
    }

    /// A message from a page that outlived its controller (one held by `VoiceboxPageUnloader`)
    /// is dropped, not a crash.
    @MainActor
    func testProxyDropsAMessageOnceItsTargetIsGone() {
        var proxy: WeakScriptMessageHandler?
        autoreleasepool {
            proxy = WeakScriptMessageHandler(target: RecordingHandler())
        }

        proxy?.userContentController(WKUserContentController(), didReceive: FakeScriptMessage(name: "voiceboxEvent", body: "dismiss"))

        XCTAssertNil(proxy?.target)
    }

    // MARK: - Rule 2: a real dismissal unloads the page

    /// A controller that is not being dismissed or removed is not leaving: covering it with a
    /// presentation or pushing over it must never unload a recorder that is coming back.
    @MainActor
    func testAControllerThatIsNotBeingDismissedIsNotLeaving() {
        let controller = VoiceboxViewController(voiceboxView: VoiceboxView(handle: "test"))
        XCTAssertFalse(controller.isLeavingPermanently)
    }

    /// The UIKit paths — `VoiceboxView.present(from:)`, the floating card, a host's own
    /// navigation controller — unload from `viewDidDisappear`, gated on the dismissal check.
    /// Not `viewWillDisappear`: an abandoned swipe-to-dismiss runs that and then reappears.
    func testViewDidDisappearUnloadsOnlyOnARealDismissal() {
        let source = VoiceboxKitSourceReader.read("VoiceboxViewController.swift")

        let didDisappear = Self.body(after: "func viewDidDisappear(", in: source)
        XCTAssertFalse(didDisappear.isEmpty, "could not find viewDidDisappear")
        guard let gate = didDisappear.range(of: "if isLeavingPermanently")?.lowerBound,
              let unload = didDisappear.range(of: "unloadForDismissal()")?.lowerBound
        else {
            return XCTFail("viewDidDisappear must unload the page when the recorder is leaving "
                           + "for good, or a recorder closed mid-take never sends its leave beacon")
        }
        XCTAssertTrue(gate < unload, "the unload must be gated on a real dismissal")

        let willDisappear = Self.body(after: "func viewWillDisappear(", in: source)
        XCTAssertFalse(willDisappear.isEmpty, "could not find viewWillDisappear")
        XCTAssertFalse(willDisappear.contains("unloadForDismissal"),
                       "an abandoned swipe-to-dismiss runs viewWillDisappear and then comes back")

        let leaving = Self.body(after: "var isLeavingPermanently: Bool", in: source)
        for signal in ["isBeingDismissed", "isMovingFromParent", ".parent"] {
            XCTAssertTrue(leaving.contains(signal),
                          "isLeavingPermanently must check \(signal) — a recorder inside a "
                          + "navigation controller or a SwiftUI sheet is not the presented controller")
        }
    }

    /// The SwiftUI `.sheet` / `.fullScreenCover` path unloads from `dismantleUIViewController`,
    /// because the representable's own `viewDidDisappear` cannot be counted on there.
    func testSwiftUIDismantleUnloadsThePage() {
        let source = VoiceboxKitSourceReader.read("View+Voicebox.swift")
        let dismantle = Self.body(after: "static func dismantleUIViewController(", in: source)

        XCTAssertFalse(dismantle.isEmpty, "VoiceboxRepresentable must implement dismantleUIViewController")
        XCTAssertTrue(dismantle.contains("unloadForDismissal()"))
    }

    /// The unload navigates the main frame to `about:blank` — a real navigation, so the
    /// outgoing page gets `pagehide` — and holds the WebView until that navigation ends,
    /// since the controller that owned it is usually released straight after dismissal.
    func testTheUnloaderNavigatesAwayAndHoldsTheWebView() {
        let source = VoiceboxKitSourceReader.read("VoiceboxPageUnloader.swift")
        let unload = Self.body(after: "func unload(_ webView: WKWebView)", in: source)

        XCTAssertFalse(unload.isEmpty, "could not find VoiceboxPageUnloader.unload")
        XCTAssertTrue(source.contains("URL(string: \"about:blank\")"))
        XCTAssertTrue(unload.contains("webView.load("), "the page must be navigated away from, not just released")
        XCTAssertTrue(unload.contains("unloading[key] = (webView:"), "the WebView must be held until the navigation ends")
        XCTAssertTrue(unload.contains("webView.navigationDelegate = self"),
                      "the blank navigation's callbacks must not reach the recorder's own delegate")
    }

    // MARK: - Helpers

    /// Text between the first `{` at or after `signature` and its matching `}` — the same
    /// crude brace counting as `RevealLatchTests`, for methods with no braces in strings.
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

/// Records the messages forwarded to it.
private final class RecordingHandler: NSObject, WKScriptMessageHandler {
    var received: [WKScriptMessage] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        received.append(message)
    }
}

/// `WKScriptMessage` has no public initializer that sets its fields, so the two the proxy
/// passes along are overridden.
private final class FakeScriptMessage: WKScriptMessage {
    private let fakeName: String
    private let fakeBody: Any

    init(name: String, body: Any) {
        fakeName = name
        fakeBody = body
        super.init()
    }

    override var name: String { fakeName }
    override var body: Any { fakeBody }
}
