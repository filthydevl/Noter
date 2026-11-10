import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Recognises Apple Pencil strokes only. Fingers are never seen by this recognizer,
/// so they keep scrolling / zooming as usual, and the pencil never scrolls.
/// Collects every coalesced sample (up to 240 Hz) for accurate snapping.
final class PencilStrokeRecognizer: UIGestureRecognizer {
    /// Stroke samples in the coordinate space of `view`.
    private(set) var points: [CGPoint] = []
    private var activeTouch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if activeTouch != nil {
            touches.forEach { ignore($0, for: event) }
            return
        }
        guard let touch = touches.first(where: { $0.type == .pencil }) else {
            state = .failed
            return
        }
        // A pencil tap on a button on the page (the ✓ next to a circled word) is a tap,
        // not a highlight stroke: let the button have it.
        if touch.view is UIControl {
            ignore(touch, for: event)
            state = .failed
            return
        }
        activeTouch = touch
        points = [touch.location(in: view)]
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        for s in samples { points.append(s.location(in: view)) }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        points.append(touch.location(in: view))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        state = .cancelled
    }

    override func reset() {
        super.reset()
        activeTouch = nil
        points = []
    }
}

/// Fingers (and trackpad) only — applied to every built-in gesture of the PDF view /
/// transcript so the pencil is reserved for highlighting.
let fingerTouchTypes: [NSNumber] = [
    NSNumber(value: UITouch.TouchType.direct.rawValue),
    NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
]
