import UIKit

/// A shimmer loading skeleton shaped like the floating recorder **card**, used
/// only in `.floatingCard` mode.
///
/// Unlike `VoiceboxSkeletonView` (full-width bars + a mic circle, meant for an
/// opaque sheet), this draws a centered card placeholder with an **avatar-shaped
/// badge straddling its top edge** — matching where the real card + avatar appear
/// — so the load state reads as "the card is coming" instead of stray bars
/// floating over the transparent presentation.
final class VoiceboxCardSkeletonView: UIView {

    // MARK: - Layers

    private let cardLayer = CALayer()          // the card surface (light)
    private let avatarLayer = CALayer()        // avatar badge, above the card
    private let handleLine = CALayer()         // @handle
    private let urlLine = CALayer()            // vbx.to/@handle
    private let promptLine = CALayer()         // prompt
    private let languageBar = CALayer()        // language selector
    private let buttonBar = CALayer()          // "Tap to Talk"
    private let shimmerLayer = CAGradientLayer()

    private let cardColor = UIColor.systemBackground.cgColor
    private let placeholderColor = UIColor.systemGray5.cgColor

    /// Dim behind the card — set to match the floating card's `dimOpacity` so the
    /// skeleton's backdrop looks the same as the loaded state (avoids the "no dim
    /// while loading, dim once loaded" jump).
    var dimOpacity: CGFloat = 0 {
        didSet { backgroundColor = UIColor.black.withAlphaComponent(dimOpacity) }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupLayers()
        setupShimmer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupLayers() {
        cardLayer.backgroundColor = cardColor
        cardLayer.shadowColor = UIColor.black.cgColor
        cardLayer.shadowOpacity = 0.08
        cardLayer.shadowRadius = 24
        cardLayer.shadowOffset = CGSize(width: 0, height: 8)
        layer.addSublayer(cardLayer)

        // Avatar badge sits ON TOP of the card, so add it after.
        avatarLayer.backgroundColor = placeholderColor
        layer.addSublayer(avatarLayer)

        for line in [handleLine, urlLine, promptLine, languageBar, buttonBar] {
            line.backgroundColor = placeholderColor
            layer.addSublayer(line)
        }
    }

    private func setupShimmer() {
        shimmerLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.white.withAlphaComponent(0.45).cgColor,
            UIColor.clear.cgColor,
        ]
        shimmerLayer.locations = [0, 0.5, 1]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(shimmerLayer)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Disable CALayer implicit animations so the card/avatar/lines appear
        // directly in place. These are manually-added sublayers, so without this
        // the first layout animates each frame from its default (top-left, zero
        // size) to the centered position — the "skeleton flies in from the corner"
        // glitch. `defer` commits when layout returns.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let centerX = bounds.midX

        // Card: recorder-ish proportions, clamped to the screen width.
        let cardWidth = min(bounds.width - 96, 344)
        let cardHeight = min(cardWidth * 1.4, bounds.height * 0.62)
        let avatarSize = cardWidth * 0.26
        // Center the AVATAR + CARD group (the web page centers `#main`, which
        // includes the avatar straddling the card top) — not just the card, or
        // the skeleton rides high relative to the real card.
        let groupHeight = avatarSize / 2 + cardHeight
        let cardY = (bounds.height - groupHeight) / 2 + avatarSize / 2
        let cardX = centerX - cardWidth / 2
        cardLayer.frame = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
        cardLayer.cornerRadius = 40

        // Avatar badge: rounded square (squircle-ish), straddling the card's top edge.
        avatarLayer.frame = CGRect(
            x: centerX - avatarSize / 2,
            y: cardY - avatarSize / 2,
            width: avatarSize,
            height: avatarSize
        )
        avatarLayer.cornerRadius = avatarSize * 0.32

        // Text lines below the avatar.
        let lineHeight: CGFloat = 14
        let lineRadius: CGFloat = 6
        var y = avatarLayer.frame.maxY + 22
        func placeCenteredLine(_ line: CALayer, widthFraction: CGFloat, height: CGFloat = 14, gap: CGFloat = 18) {
            let w = cardWidth * widthFraction
            line.frame = CGRect(x: centerX - w / 2, y: y, width: w, height: height)
            line.cornerRadius = min(lineRadius, height / 2)
            y += height + gap
        }
        placeCenteredLine(handleLine, widthFraction: 0.42, height: lineHeight)
        placeCenteredLine(urlLine, widthFraction: 0.56, height: lineHeight)
        placeCenteredLine(promptLine, widthFraction: 0.70, height: lineHeight)

        // Language selector + "Tap to Talk" button pinned near the card bottom.
        let controlWidth = cardWidth - 48
        let buttonHeight: CGFloat = 52
        let langHeight: CGFloat = 40
        let bottomInset: CGFloat = 28
        buttonBar.frame = CGRect(
            x: centerX - controlWidth / 2,
            y: cardY + cardHeight - bottomInset - buttonHeight,
            width: controlWidth,
            height: buttonHeight
        )
        buttonBar.cornerRadius = buttonHeight / 2
        languageBar.frame = CGRect(
            x: centerX - controlWidth / 2,
            y: buttonBar.frame.minY - 16 - langHeight,
            width: controlWidth,
            height: langHeight
        )
        languageBar.cornerRadius = 12

        // Clip the shimmer to the card's rounded shape — otherwise the square
        // gradient paints into the card's transparent corner triangles, making
        // the corners read as square during the sweep.
        shimmerLayer.frame = cardLayer.frame
        shimmerLayer.cornerRadius = cardLayer.cornerRadius
        shimmerLayer.masksToBounds = true
    }

    // MARK: - Animation

    func startAnimating() {
        isHidden = false
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1.0, -0.5, 0.0]
        animation.toValue = [1.0, 1.5, 2.0]
        animation.duration = 1.4
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmerLayer.add(animation, forKey: "shimmer")
    }

    func stopAnimating() {
        UIView.animate(withDuration: 0.3) {
            self.alpha = 0
        } completion: { _ in
            self.isHidden = true
            self.alpha = 1
            self.shimmerLayer.removeAllAnimations()
        }
    }
}
