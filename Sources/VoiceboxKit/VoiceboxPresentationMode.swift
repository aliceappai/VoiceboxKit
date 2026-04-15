import CoreGraphics

/// Controls how the Voicebox recording experience is presented.
public enum VoiceboxPresentationMode: Equatable {

    /// Full-screen modal covering the entire screen.
    case fullScreen

    /// Bottom sheet starting at medium height, expandable to large.
    /// This is the default presentation mode.
    case bottomSheet

    /// Standard iOS sheet presented at large (full) height.
    case sheet

    /// Sheet that auto-sizes its height to match the web content.
    /// Falls back to `.sheet` on iOS 15 (custom detents require iOS 16+).
    case fitContent

    /// Sheet pinned to a fixed height in points.
    ///
    /// Use this when `.fitContent` doesn't give a clean result. Example:
    /// ```swift
    /// vb.presentationMode = .custom(height: 520)
    /// ```
    ///
    /// Requires iOS 16+. Falls back to `.sheet` on iOS 15.
    case custom(height: CGFloat)

    /// Sheet sized as a fraction of screen height (0.0 – 1.0).
    ///
    /// ```swift
    /// vb.presentationMode = .customFraction(0.6)  // 60% of screen
    /// ```
    ///
    /// Requires iOS 16+. Falls back to `.sheet` on iOS 15.
    case customFraction(CGFloat)
}
