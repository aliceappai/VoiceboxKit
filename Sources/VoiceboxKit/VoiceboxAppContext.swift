import Foundation
import UIKit

/// Collects non-PII app and device context for inclusion in the Voicebox URL.
///
/// The purpose is **feedback triage**: when a user submits feedback, the
/// Voicebox backend user can immediately see which app, version, and OS the
/// feedback came from — without the host app having to manually pass these
/// params on every call.
///
/// Collection is controlled by `VoiceboxKit.autoCollectAppContext` (default `true`).
/// App-provided params always override auto-collected values.
///
/// **Collected:**
/// - `bundleID`, `appName`, `appVersion`, `buildNumber` — app identity
/// - `platform`, `osVersion`, `deviceModel` — device context
/// - `locale` — user region
/// - `sdkVersion` — VoiceboxKit SDK version
///
/// **Not collected** (privacy):
/// - Device name (often PII like "John's iPhone")
/// - IDFA (requires ATT prompt)
/// - `identifierForVendor` (stable tracking ID)
/// - Location, contacts, or any permission-gated data
enum VoiceboxAppContext {

    /// Returns all auto-collectable context params as a dictionary.
    static func collect() -> [String: String] {
        var params: [String: String] = [:]

        // MARK: App identity
        let info = Bundle.main.infoDictionary

        if let bundleID = Bundle.main.bundleIdentifier {
            params["bundleID"] = bundleID
        }

        // Prefer display name (user-visible) over internal bundle name
        if let displayName = info?["CFBundleDisplayName"] as? String {
            params["appName"] = displayName
        } else if let bundleName = info?["CFBundleName"] as? String {
            params["appName"] = bundleName
        }

        if let version = info?["CFBundleShortVersionString"] as? String {
            params["appVersion"] = version
        }

        if let build = info?["CFBundleVersion"] as? String {
            params["buildNumber"] = build
        }

        // MARK: Platform + OS
        params["platform"] = "ios"
        params["osVersion"] = UIDevice.current.systemVersion
        params["deviceModel"] = deviceModelIdentifier()

        // MARK: Locale
        params["locale"] = Locale.current.identifier

        // MARK: SDK self-identification
        params["sdkVersion"] = VoiceboxKit.version

        return params
    }

    /// Returns the hardware model identifier (e.g., `iPhone16,2`).
    ///
    /// This is more useful than `UIDevice.current.model` (which just returns
    /// `"iPhone"`) because it identifies the specific hardware generation.
    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier
    }
}
