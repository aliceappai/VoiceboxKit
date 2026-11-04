import UIKit
import VoiceboxKit

/// Defaults the harness launches with.
enum Harness {
    static let defaultHandle = "p-test"
    static let stagingBaseURL = "https://vbxstaging.com"
    static let productionBaseURL = "https://vbx.to"

    /// Params a real host app would attach. Mirrors the Android example's user.
    static let userParams: [String: String] = [
        "email": "jane@example.com",
        "userID": "usr_abc123",
        "prompt": "How are you finding the new dashboard?",
        "screen": "harness",
    ]
}

/// Every presentation mode the SDK exposes, as a pickable list.
///
/// `VoiceboxPresentationMode` carries associated values, so the harness keeps a
/// parallel enum it can iterate, label, and assert against.
enum ModeChoice: String, CaseIterable, Identifiable {
    case bottomSheet
    case sheet
    case fullScreen
    case fitContent
    case customHeight
    case customFraction
    case floatingCard

    var id: String { rawValue }

    /// Button label — same wording as the Android example where the mode exists there.
    var title: String {
        switch self {
        case .bottomSheet:    return "Bottom Sheet"
        case .sheet:          return "Sheet (Full Height)"
        case .fullScreen:     return "Full Screen"
        case .fitContent:     return "Fit Content"
        case .customHeight:   return "Custom Height (500 pt)"
        case .customFraction: return "Custom Fraction (70%)"
        case .floatingCard:   return "Floating Card"
        }
    }

    var mode: VoiceboxPresentationMode {
        switch self {
        case .bottomSheet:    return .bottomSheet
        case .sheet:          return .sheet
        case .fullScreen:     return .fullScreen
        case .fitContent:     return .fitContent
        case .customHeight:   return .custom(height: 500)
        case .customFraction: return .customFraction(0.7)
        case .floatingCard:   return .floatingCard(dimOpacity: 0.35)
        }
    }

    /// Custom detents need iOS 16; on iOS 15 the SDK silently falls back to
    /// `.sheet`, so the harness says which modes that applies to.
    var fallsBackOniOS15: Bool {
        switch self {
        case .fitContent, .customHeight, .customFraction: return true
        default: return false
        }
    }
}

/// The three shipped presets plus one hand-rolled theme, so the custom path is
/// exercised too.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case standard
    case darkCircle
    case lightCircle
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:    return "Default"
        case .darkCircle:  return "Dark"
        case .lightCircle: return "Light"
        case .custom:      return "Custom"
        }
    }

    var theme: VoiceboxTheme {
        switch self {
        case .standard:
            return .plain
        case .darkCircle:
            return .darkCircle
        case .lightCircle:
            return .lightCircle
        case .custom:
            return VoiceboxTheme(
                cornerRadius: 28,
                closeButtonIconColor: .white,
                closeButtonBackgroundColor: .systemBlue,
                closeButtonSize: 40,
                closeButtonSymbolName: "xmark.circle"
            )
        }
    }
}

/// Which host the SDK talks to. Staging by default so harness recordings never
/// land in a production voicebox.
enum BaseURLChoice: String, CaseIterable, Identifiable {
    case staging
    case production

    var id: String { rawValue }

    var title: String { self == .staging ? "Staging" : "Production" }

    var urlString: String {
        self == .staging ? Harness.stagingBaseURL : Harness.productionBaseURL
    }
}
