import CoreLocation
import WebKit

/// Bridges the web `navigator.geolocation` API to native Core Location.
///
/// Without this, WKWebView geolocation shows a **second**, WebKit-managed
/// per-origin permission prompt on top of the iOS Core Location prompt — and it
/// re-prompts on later opens, because that WebKit grant does not persist across
/// the SDK recreating its WebView. This bridge overrides `navigator.geolocation`
/// and serves it from `CLLocationManager`, so the WebKit layer is bypassed and
/// only the single native iOS prompt appears (which iOS remembers).
///
/// Enabled by ``VoiceboxKit/nativeGeolocationEnabled``. Requires the host app to
/// declare `NSLocationWhenInUseUsageDescription` in its Info.plist.
final class VoiceboxGeolocationBridge: NSObject {

    static let messageName = "voiceboxGeolocation"

    private let manager = CLLocationManager()
    private weak var webView: WKWebView?

    /// One-shot `getCurrentPosition` request ids awaiting the next fix.
    private var oneShotIds: [Int] = []
    /// Active `watchPosition` request ids — kept until `clearWatch`.
    private var watcherIds: Set<Int> = []
    /// Requests received while authorization was still `.notDetermined`.
    private var pendingUntilAuthorized: [(id: Int, watch: Bool)] = []
    private var didRequestAuthorization = false

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Registers the message handler + JS polyfill and patches the already-loaded
    /// (preloaded) page immediately, since the `atDocumentStart` script only runs
    /// on a fresh navigation.
    func install() {
        guard let webView else { return }
        let ucc = webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: Self.messageName)
        ucc.add(self, name: Self.messageName)
        ucc.addUserScript(
            WKUserScript(
                source: Self.polyfillJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        // Preloaded / live page: the user script won't re-run, so patch now.
        // The `__vbxGeoInstalled` guard makes this idempotent with the script.
        webView.evaluateJavaScript(Self.polyfillJS, completionHandler: nil)
    }

    func uninstall() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        manager.stopUpdatingLocation()
    }

    // MARK: - Request handling

    private func start(id: Int, watch: Bool) {
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingUntilAuthorized.append((id, watch))
            if !didRequestAuthorization {
                didRequestAuthorization = true
                manager.requestWhenInUseAuthorization()
            }
        case .denied, .restricted:
            reject(id: id, code: 1, message: "Location permission denied")
        case .authorizedWhenInUse, .authorizedAlways:
            begin(id: id, watch: watch)
        @unknown default:
            reject(id: id, code: 2, message: "Location unavailable")
        }
    }

    private func begin(id: Int, watch: Bool) {
        if watch {
            watcherIds.insert(id)
            manager.startUpdatingLocation()
        } else {
            oneShotIds.append(id)
            manager.requestLocation()
        }
    }

    private func clearWatch(id: Int) {
        watcherIds.remove(id)
        if watcherIds.isEmpty {
            manager.stopUpdatingLocation()
        }
    }

    // MARK: - JS resolve / reject

    private func resolve(id: Int, _ loc: CLLocation) {
        let c = loc.coordinate
        let heading = loc.course >= 0 ? String(loc.course) : "null"
        let speed = loc.speed >= 0 ? String(loc.speed) : "null"
        let ts = Int(loc.timestamp.timeIntervalSince1970 * 1000)
        let js = "window.__voiceboxGeoResolve && window.__voiceboxGeoResolve("
            + "\(id), \(c.latitude), \(c.longitude), \(loc.horizontalAccuracy), "
            + "\(loc.altitude), \(loc.verticalAccuracy), \(heading), \(speed), \(ts));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func reject(id: Int, code: Int, message: String) {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let js = "window.__voiceboxGeoReject && window.__voiceboxGeoReject(\(id), \(code), \"\(escaped)\");"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - WKScriptMessageHandler

extension VoiceboxGeolocationBridge: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any],
              let method = body["method"] as? String,
              let id = body["id"] as? Int else { return }
        switch method {
        case "getCurrentPosition": start(id: id, watch: false)
        case "watchPosition": start(id: id, watch: true)
        case "clearWatch": clearWatch(id: id)
        default: break
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension VoiceboxGeolocationBridge: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            let queued = pendingUntilAuthorized
            pendingUntilAuthorized.removeAll()
            for req in queued { begin(id: req.id, watch: req.watch) }
        case .denied, .restricted:
            let queued = pendingUntilAuthorized
            pendingUntilAuthorized.removeAll()
            for req in queued { reject(id: req.id, code: 1, message: "Location permission denied") }
        case .notDetermined:
            break // still waiting on the user's choice
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let oneShots = oneShotIds
        oneShotIds.removeAll()
        for id in oneShots { resolve(id: id, loc) }
        for id in watcherIds { resolve(id: id, loc) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Fail only the pending one-shots; keep watchers alive to retry.
        let oneShots = oneShotIds
        oneShotIds.removeAll()
        let code = (error as? CLError)?.code == .denied ? 1 : 2
        for id in oneShots { reject(id: id, code: code, message: error.localizedDescription) }
    }
}

// MARK: - JS polyfill

extension VoiceboxGeolocationBridge {
    /// Overrides `navigator.geolocation` to route through the native bridge.
    /// Idempotent (guarded by `__vbxGeoInstalled`) so the user script and the
    /// post-load `evaluateJavaScript` can both run safely.
    static let polyfillJS = """
    (function() {
      if (window.__vbxGeoInstalled) return;
      window.__vbxGeoInstalled = true;
      try {
        var geo = navigator.geolocation;
        if (!geo) { return; }
        var cbs = {};
        var nextId = 1;
        function post(method, id, options) {
          try {
            window.webkit.messageHandlers.voiceboxGeolocation.postMessage(
              { method: method, id: id, options: options || {} }
            );
          } catch (e) {}
        }
        geo.getCurrentPosition = function(success, error, options) {
          var id = nextId++;
          cbs[id] = { success: success, error: error, once: true };
          post('getCurrentPosition', id, options);
        };
        geo.watchPosition = function(success, error, options) {
          var id = nextId++;
          cbs[id] = { success: success, error: error, once: false };
          post('watchPosition', id, options);
          return id;
        };
        geo.clearWatch = function(id) {
          delete cbs[id];
          post('clearWatch', id, null);
        };
        window.__voiceboxGeoResolve = function(id, lat, lng, accuracy, altitude, altAccuracy, heading, speed, ts) {
          var cb = cbs[id];
          if (!cb) return;
          var position = {
            coords: {
              latitude: lat, longitude: lng, accuracy: accuracy,
              altitude: altitude, altitudeAccuracy: altAccuracy,
              heading: heading, speed: speed
            },
            timestamp: ts || Date.now()
          };
          try { if (cb.success) cb.success(position); } catch (e) {}
          if (cb.once) delete cbs[id];
        };
        window.__voiceboxGeoReject = function(id, code, message) {
          var cb = cbs[id];
          if (!cb) return;
          try {
            if (cb.error) cb.error({
              code: code, message: message || '',
              PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3
            });
          } catch (e) {}
          delete cbs[id];
        };
      } catch (e) {}
    })();
    """
}
