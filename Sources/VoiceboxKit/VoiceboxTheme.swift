import UIKit

/// Configures the visual appearance of the Voicebox presentation.
///
/// All properties are optional. A `nil` value means "use the SDK default"
/// — set only the properties you want to override.
///
/// ```swift
/// // Only override the close button background
/// let theme = VoiceboxTheme(
///     closeButtonBackgroundColor: .systemBlue
/// )
/// ```
public struct VoiceboxTheme {

    // MARK: - Sheet

    /// Corner radius applied to the sheet presentation.
    /// Default: `16`.
    public var cornerRadius: CGFloat?

    /// Background color behind the WebView.
    /// Default: `.systemBackground`.
    public var backgroundColor: UIColor?

    // MARK: - Close Button

    /// Color of the `×` icon inside the close button.
    /// Default: `.label`.
    public var closeButtonIconColor: UIColor?

    /// Background color of the close button. `nil` means transparent —
    /// just the `×` icon floats on the sheet.
    /// Default: `nil`.
    public var closeButtonBackgroundColor: UIColor?

    /// Diameter of the close button in points.
    /// Default: `32`.
    public var closeButtonSize: CGFloat?

    /// SF Symbol name used for the close icon.
    /// Default: `"xmark"`.
    ///
    /// Other nice options: `"xmark.circle.fill"`, `"multiply"`, `"chevron.down"`.
    public var closeButtonSymbolName: String?

    // MARK: - Init

    /// Creates a theme. Any property left `nil` uses the SDK default.
    ///
    /// - Parameters:
    ///   - cornerRadius: Corner radius for the sheet. Default `16`.
    ///   - backgroundColor: Background behind the WebView. Default `.systemBackground`.
    ///   - closeButtonIconColor: `×` icon color. Default `.label`.
    ///   - closeButtonBackgroundColor: Circle behind the `×`. `nil` = transparent.
    ///   - closeButtonSize: Close button diameter in points. Default `32`.
    ///   - closeButtonSymbolName: SF Symbol for the close icon. Default `"xmark"`.
    public init(
        cornerRadius: CGFloat? = nil,
        backgroundColor: UIColor? = nil,
        closeButtonIconColor: UIColor? = nil,
        closeButtonBackgroundColor: UIColor? = nil,
        closeButtonSize: CGFloat? = nil,
        closeButtonSymbolName: String? = nil
    ) {
        self.cornerRadius = cornerRadius
        self.backgroundColor = backgroundColor
        self.closeButtonIconColor = closeButtonIconColor
        self.closeButtonBackgroundColor = closeButtonBackgroundColor
        self.closeButtonSize = closeButtonSize
        self.closeButtonSymbolName = closeButtonSymbolName
    }

    // MARK: - Defaults (used when a property is nil)

    static let defaultCornerRadius: CGFloat = 16
    static let defaultBackgroundColor: UIColor = .systemBackground
    static let defaultCloseButtonIconColor: UIColor = .label
    static let defaultCloseButtonSize: CGFloat = 32
    static let defaultCloseButtonSymbolName = "xmark"

    // MARK: - Resolved Values (internal)

    /// Corner radius to apply, falling back to the SDK default.
    var resolvedCornerRadius: CGFloat {
        cornerRadius ?? Self.defaultCornerRadius
    }

    /// Background color to apply, falling back to the SDK default.
    var resolvedBackgroundColor: UIColor {
        backgroundColor ?? Self.defaultBackgroundColor
    }

    /// Close button icon color, falling back to the SDK default.
    var resolvedCloseButtonIconColor: UIColor {
        closeButtonIconColor ?? Self.defaultCloseButtonIconColor
    }

    /// Close button diameter, falling back to the SDK default.
    var resolvedCloseButtonSize: CGFloat {
        closeButtonSize ?? Self.defaultCloseButtonSize
    }

    /// Close button SF Symbol name, falling back to the SDK default.
    var resolvedCloseButtonSymbolName: String {
        closeButtonSymbolName ?? Self.defaultCloseButtonSymbolName
    }

    // MARK: - Presets

    /// Default light appearance: black `×` on transparent background.
    public static let plain = VoiceboxTheme()

    /// Filled circle: dark background, white `×` icon.
    public static let darkCircle = VoiceboxTheme(
        closeButtonIconColor: .white,
        closeButtonBackgroundColor: UIColor.label.withAlphaComponent(0.9)
    )

    /// Filled circle: light background, dark `×` icon.
    public static let lightCircle = VoiceboxTheme(
        closeButtonIconColor: .label,
        closeButtonBackgroundColor: UIColor.systemGray5
    )
}
