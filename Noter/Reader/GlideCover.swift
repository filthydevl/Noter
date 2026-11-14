import UIKit

/// A smooth stand-in while the page area changes size (a side panel opening or closing
/// in landscape): a picture of the page as it looks now glides to its new size from the
/// top-left, while the real PDF / text view is resized and redrawn out of sight
/// underneath; then the picture fades into the real thing. Animating the live view
/// instead stutters — PDFKit redraws the whole page at every size.
@MainActor
final class GlideCover {
    private let cover: UIView
    private let picture: UIView

    /// Covers `view` with a picture of it as it is now (before the resize).
    init?(over view: UIView, background: UIColor) {
        guard view.window != nil, view.bounds.width > 1,
              let picture = view.snapshotView(afterScreenUpdates: false) else { return nil }
        let cover = UIView(frame: view.bounds)
        cover.backgroundColor = background // hides the half-drawn page underneath
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        picture.layer.anchorPoint = .zero
        picture.frame = view.bounds
        cover.addSubview(picture)
        view.addSubview(cover)
        self.cover = cover
        self.picture = picture
    }

    /// Glides the picture to `scale` (from the top-left) in step with the panel, then
    /// fades it away to show the real, redrawn page.
    func run(scale: CGFloat, duration: TimeInterval = 0.4, bounce: CGFloat = 0.12) {
        guard scale.isFinite, scale > 0 else { remove(); return }
        UIView.animate(springDuration: duration, bounce: bounce, options: [.allowUserInteraction]) {
            self.picture.transform = CGAffineTransform(scaleX: scale, y: scale)
        } completion: { _ in
            UIView.animate(withDuration: 0.2, delay: 0.06, options: [.allowUserInteraction]) {
                self.cover.alpha = 0
            } completion: { _ in
                self.remove()
            }
        }
    }

    private func remove() {
        cover.removeFromSuperview()
    }
}
