import SwiftUI
import UIKit

/// Apple Pencil double-tap (Pencil 2 / Pro) and squeeze (Pencil Pro) switch between
/// highlighter and eraser, respecting the action chosen in iPad Settings › Apple Pencil.
struct PencilInteractionHost: UIViewRepresentable {
    var onToggle: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onToggle = onToggle
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var onToggle: () -> Void

        init(onToggle: @escaping () -> Void) {
            self.onToggle = onToggle
        }

        // iPadOS 17.0–17.4
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            if UIPencilInteraction.preferredTapAction != .ignore { onToggle() }
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            if UIPencilInteraction.preferredTapAction != .ignore { onToggle() }
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            if UIPencilInteraction.preferredSqueezeAction != .ignore { onToggle() }
        }
    }
}
