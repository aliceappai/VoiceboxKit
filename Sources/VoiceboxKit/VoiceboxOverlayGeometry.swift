import UIKit

/// Geometry of the recorder's head-and-shoulders silhouette, used by the
/// `.overlay` presentation to hit-test touches (and optionally mask).
///
/// The web page paints the shape itself (transparent `overlay=1` mode); native
/// only needs to know *where the shape is* so that taps landing on the
/// transparent corners beside the head pass through to the dimmed backdrop and
/// dismiss, exactly like tapping the backdrop directly.
///
/// Constants mirror the recorder CSS (`component/recorder.sass`): a 340pt-wide
/// content column, a ~114pt logo "head" (radius 57) centred near the top, and a
/// rounded card "body" (radius 48). They can be nudged if the recorder layout
/// changes — the hit-test is deliberately forgiving.
struct VoiceboxOverlaySilhouette: Equatable {

    /// Web recorder `#main` content width.
    static let contentWidth: CGFloat = 340

    var headRadius: CGFloat = 57
    /// Head-circle centre measured from the top of the content.
    /// ≈ `#main` padding-top (82) − logo overhang (57) + head radius (57).
    var headCenterY: CGFloat = 82
    /// Card top edge from the top of the content (coincides with the head centre).
    var cardTop: CGFloat = 82
    var cardCornerRadius: CGFloat = 48

    /// True when `point` (origin = top-left of the `size` box) is inside the
    /// head circle or the card body. Card corners are treated as square here —
    /// intentionally forgiving so small layout drift never dead-zones a real tap.
    func contains(_ point: CGPoint, in size: CGSize) -> Bool {
        if point.y >= cardTop, point.x >= 0, point.x <= size.width {
            return true
        }
        let cx = size.width / 2
        let dx = point.x - cx
        let dy = point.y - headCenterY
        return (dx * dx + dy * dy) <= (headRadius * headRadius)
    }

    /// Union path (head circle + rounded card) for an optional CAShapeLayer mask.
    func path(in size: CGSize) -> UIBezierPath {
        let cx = size.width / 2
        let head = UIBezierPath(
            ovalIn: CGRect(
                x: cx - headRadius, y: headCenterY - headRadius,
                width: headRadius * 2, height: headRadius * 2
            )
        )
        let card = UIBezierPath(
            roundedRect: CGRect(
                x: 0, y: cardTop,
                width: size.width, height: max(0, size.height - cardTop)
            ),
            cornerRadius: cardCornerRadius
        )
        head.append(card)
        head.usesEvenOddFillRule = false
        return head
    }
}

/// Hosts the overlay WebView and makes only the silhouette interactive: touches
/// outside the head/card return `false` from `point(inside:)`, so `hitTest`
/// yields `nil` and the touch falls through to the dimmed backdrop behind (which
/// dismisses). Inside the shape, the WebView receives touches normally.
final class VoiceboxOverlayContainerView: UIView {

    var silhouette = VoiceboxOverlaySilhouette()

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        silhouette.contains(point, in: bounds.size)
    }
}
