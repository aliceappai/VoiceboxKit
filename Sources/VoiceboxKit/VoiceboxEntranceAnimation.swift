/// Which entrance animation(s) play when a Voicebox is presented in
/// `.floatingCard` mode.
///
/// Combine freely:
/// ```swift
/// .voicebox(isPresented: $show, handle: "…",
///           presentationMode: .floatingCard(dimOpacity: 0.15),
///           entranceAnimation: [.backgroundReveal, .cardLiftIn]) // or .all / .none
/// ```
///
/// - `.backgroundReveal` — the full-screen background scales down slightly and
///   fades in.
/// - `.cardLiftIn` — the card assembly (logo + card) lifts up and scales into place.
///
/// The sheet-based presentation modes ignore this (it only affects `.floatingCard`).
public struct VoiceboxEntranceAnimation: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The full-screen background scales down slightly (1.08 → 1.0) and fades in.
    public static let backgroundReveal = VoiceboxEntranceAnimation(rawValue: 1 << 0)

    /// The card assembly (logo + card) lifts up and scales into place, a beat
    /// after the background.
    public static let cardLiftIn = VoiceboxEntranceAnimation(rawValue: 1 << 1)

    /// Both animations — the default.
    public static let all: VoiceboxEntranceAnimation = [.backgroundReveal, .cardLiftIn]

    /// No entrance animation — the card just appears.
    public static let none: VoiceboxEntranceAnimation = []
}
