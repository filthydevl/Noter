import SwiftUI
import UIKit

/// The page slider's touch handling: fingers only. The Apple Pencil never moves the
/// slider (writing near the left edge used to), and because this view takes no
/// touches itself, a pencil stroke that starts over the slider still reaches the page.
struct FingerTrack: UIViewRepresentable {
    /// Finger position inside the track (its coordinates), while it's down or moving.
    var onChange: (CGPoint, CGSize) -> Void
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TrackView {
        let view = TrackView()
        view.isUserInteractionEnabled = false // touches go to what's underneath
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        context.coordinator.area = view
        return view
    }

    func updateUIView(_ view: TrackView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    static func dismantleUIView(_ view: TrackView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class TrackView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: ((CGPoint, CGSize) -> Void)?
        var onEnd: (() -> Void)?
        weak var area: UIView?
        private var recognizer: UILongPressGestureRecognizer?
        /// A finger is on the slider right now.
        private var tracking = false

        /// The recognizer lives on the window, so it sees touches over the track
        /// without a view having to sit in their way.
        func attach(to window: UIWindow?) {
            detach()
            guard let window else { return }
            let g = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            g.minimumPressDuration = 0
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)] // no pencil
            g.cancelsTouchesInView = true
            g.delegate = self
            window.addGestureRecognizer(g)
            recognizer = g
        }

        func detach() {
            if let g = recognizer { g.view?.removeGestureRecognizer(g) }
            recognizer = nil
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard touch.type == .direct, let area, area.window != nil, !area.isHidden else { return false }
            // Only when the slider itself is what's under the finger (not a sheet or
            // menu shown over it).
            guard touch.view?.window === area.window, area.bounds.contains(touch.location(in: area)),
                  area.window?.rootViewController?.presentedViewController == nil else { return false }
            var v: UIView? = touch.view
            while let view = v {
                if view is UIControl { return false } // the Fit button, etc.
                v = view.superview
            }
            tracking = true
            return true
        }

        /// Scrolling the page must wait for the slider: they never both move.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            tracking
        }

        @objc private func handle(_ g: UILongPressGestureRecognizer) {
            guard let area else { return }
            switch g.state {
            case .began, .changed:
                onChange?(g.location(in: area), area.bounds.size)
            case .ended, .cancelled, .failed:
                tracking = false
                onEnd?()
            default:
                break
            }
        }
    }
}
