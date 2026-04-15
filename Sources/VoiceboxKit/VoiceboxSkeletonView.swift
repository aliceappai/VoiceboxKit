import UIKit

/// A shimmer loading skeleton shown while the Voicebox WebView loads.
///
/// Displays placeholder shapes mimicking the recorder layout (prompt text
/// bars and a mic button circle) with an animated gradient sweep.
final class VoiceboxSkeletonView: UIView {

    // MARK: - Placeholder Layers

    private let promptBar1 = CALayer()
    private let promptBar2 = CALayer()
    private let promptBar3 = CALayer()
    private let micCircle = CALayer()
    private let shimmerLayer = CAGradientLayer()

    private let placeholderColor = UIColor.systemGray5.cgColor
    private let barCornerRadius: CGFloat = 6
    private let barHeight: CGFloat = 14

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlaceholders()
        setupShimmer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPlaceholders()
        layoutShimmer()
    }

    // MARK: - Setup

    private func setupPlaceholders() {
        for bar in [promptBar1, promptBar2, promptBar3] {
            bar.backgroundColor = placeholderColor
            bar.cornerRadius = barCornerRadius
            layer.addSublayer(bar)
        }

        micCircle.backgroundColor = placeholderColor
        layer.addSublayer(micCircle)
    }

    private func setupShimmer() {
        shimmerLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.white.withAlphaComponent(0.4).cgColor,
            UIColor.clear.cgColor,
        ]
        shimmerLayer.locations = [0, 0.5, 1]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(shimmerLayer)
    }

    private func layoutPlaceholders() {
        let centerX = bounds.midX
        let contentTop = bounds.height * 0.25

        // Prompt text placeholder bars
        let barSpacing: CGFloat = 12
        let bar1Width = bounds.width * 0.7
        let bar2Width = bounds.width * 0.55
        let bar3Width = bounds.width * 0.4

        promptBar1.frame = CGRect(
            x: centerX - bar1Width / 2,
            y: contentTop,
            width: bar1Width,
            height: barHeight
        )
        promptBar2.frame = CGRect(
            x: centerX - bar2Width / 2,
            y: contentTop + barHeight + barSpacing,
            width: bar2Width,
            height: barHeight
        )
        promptBar3.frame = CGRect(
            x: centerX - bar3Width / 2,
            y: contentTop + 2 * (barHeight + barSpacing),
            width: bar3Width,
            height: barHeight
        )

        // Mic button circle placeholder
        let circleSize: CGFloat = 80
        let circleTop = promptBar3.frame.maxY + 40
        micCircle.frame = CGRect(
            x: centerX - circleSize / 2,
            y: circleTop,
            width: circleSize,
            height: circleSize
        )
        micCircle.cornerRadius = circleSize / 2
    }

    private func layoutShimmer() {
        shimmerLayer.frame = bounds
    }

    // MARK: - Animation

    /// Start the shimmer animation.
    func startAnimating() {
        isHidden = false

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1.0, -0.5, 0.0]
        animation.toValue = [1.0, 1.5, 2.0]
        animation.duration = 1.5
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        shimmerLayer.add(animation, forKey: "shimmer")
    }

    /// Stop the shimmer animation and fade out.
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
