import WebKit

/// Presentation-independent WebView wiring shared by the live path
/// (`VoiceboxView.makeWebView`) and the preload/warm path
/// (`VoiceboxCache.warmWebViewCache`), so a preloaded WebView is byte-for-byte
/// configured like a freshly-made one.
///
/// Why this exists: previously the warm path built a **bare** configuration, so
/// the recorder's event observers (record/send buttons) and text-selection
/// disabling only ran on a *fresh* load — a reused preloaded WebView (whose page
/// is already rendered) never got them, because `addUserScript` only fires on the
/// next navigation. Baking them into the shared configuration means they run at
/// warm-load and are already active when the WebView is adopted.
enum VoiceboxWebScripts {

    // MARK: - Message handler names

    static let eventMessageName = "voiceboxEvent"
    static let bgColorMessageName = "voiceboxBgColor"
    static let contentHeightMessageName = "voiceboxContentHeight"
    static let domReadyMessageName = "voiceboxDomReady"

    // MARK: - Configuration

    /// Builds the standard configuration every Voicebox WebView uses. Both the
    /// live and warm paths call this so a preloaded WebView is configured
    /// identically to a fresh one (same scripts, same data store).
    ///
    /// - Note: We intentionally don't set a shared `WKProcessPool` — it's a no-op
    ///   since iOS 15 (WebKit shares process infrastructure automatically).
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(baseUserScript())
        config.userContentController.addUserScript(eventUserScript())
        config.userContentController.addUserScript(domReadyUserScript())
        return config
    }

    // MARK: - Scripts

    /// Disables text selection / context menus / callouts. Presentation-agnostic.
    private static func baseUserScript() -> WKUserScript {
        let source = """
        (function() {
            document.addEventListener('contextmenu', function(e) { e.preventDefault(); });
            document.addEventListener('long-press', function(e) { e.preventDefault(); });
            var style = document.createElement('style');
            style.textContent = '* { -webkit-user-select: none !important; -webkit-touch-callout: none !important; }';
            (document.head || document.documentElement).appendChild(style);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Signals that the recorder is PAINTED and usable, which happens well before the page
    /// has finished loading.
    ///
    /// `didFinish` — what the reveal used to wait for — fires on the window `load` event,
    /// i.e. after every subresource has landed. Measured on the recorder that is ~400 ms
    /// after DOMContentLoaded, and none of it changes what the user sees: the card, prompt,
    /// language picker and Tap-to-Talk button are all server-rendered HTML styled by CSS
    /// that is already in the cache. The straggling requests are the visualizer, ActionCable,
    /// ahoy and Bugsnag — background machinery, not pixels.
    ///
    /// Injected `.atDocumentEnd` — the document is parsed and its render-blocking CSS (all
    /// cached) has been applied, so the card is styled and ready to show.
    ///
    /// Deliberately posts IMMEDIATELY rather than waiting on `requestAnimationFrame`. rAF is
    /// driven by the display link, and a WKWebView that is off-screen or hidden does not
    /// paint — so its rAF callbacks simply queue up. That cost most of the saving this signal
    /// exists for (measured: DCL at 1,514 ms but the rAF post at 1,697 ms), and on the hot
    /// spare it was worse than useless: the spare's blank document queued a callback that
    /// only fired once the WebView was added to a real hierarchy, arriving AFTER adoption and
    /// revealing an empty sheet.
    ///
    /// The current `location.href` goes with the message so the receiver can tell which
    /// document is speaking, since a recycled WebView may have more than one in its past.
    private static func domReadyUserScript() -> WKUserScript {
        let source = """
        (function() {
            try {
                var mh = window.webkit && window.webkit.messageHandlers;
                if (mh && mh.\(domReadyMessageName)) {
                    mh.\(domReadyMessageName).postMessage(String(window.location.href));
                }
            } catch (e) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Observes recorder button clicks / postMessage events and forwards them to
    /// the `voiceboxEvent` message handler.
    ///
    /// Crucially, it reads `window.webkit.messageHandlers.voiceboxEvent` **at
    /// post time**, not once up front — so it works even when baked into a warm
    /// config, where the handler isn't registered until the WebView is adopted
    /// later. (The old version captured the handler once at document-start, so a
    /// warmed page's click would hit an `undefined` handler and throw.)
    private static func eventUserScript() -> WKUserScript {
        let source = """
        (function() {
            function post(msg) {
                try {
                    var mh = window.webkit && window.webkit.messageHandlers;
                    if (mh && mh.\(eventMessageName)) { mh.\(eventMessageName).postMessage(msg); }
                } catch (e) {}
            }

            // postMessage bridge (works when embedded in an iframe)
            window.addEventListener('message', function(event) {
                if (!event.data || !event.data.type) return;
                if (event.data.type === 'voicebox:recordingComplete') post('recordingComplete');
                if (event.data.type === 'voicebox:messageSubmitted') post('messageSubmitted');
            });

            // Direct button observation (works in a direct WKWebView)
            var observed = { save: false, send: false };
            function attach() {
                var saveBtn = document.getElementById('record-btn-send');
                if (saveBtn && !observed.save) {
                    observed.save = true;
                    saveBtn.addEventListener('click', function() { post('recordingComplete'); });
                }
                var sendBtn = document.querySelector('[data-recorder--recorder-target="editSubmitButton"]');
                if (sendBtn && !observed.send) {
                    observed.send = true;
                    sendBtn.addEventListener('click', function() { post('messageSubmitted'); });
                }
            }
            attach();
            new MutationObserver(attach).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
