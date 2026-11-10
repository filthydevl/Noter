import SwiftUI
import UIKit

/// Keeps a floating panel's content above the on-screen keyboard: the panel shrinks so
/// its bottom sits on top of the keyboard, and grows back when the keyboard goes away.
/// (The reader's panels float over the page, so the system's own keyboard avoidance
/// doesn't reach them.)
struct KeyboardAvoiding: ViewModifier {
    @State private var keyboardTop: CGFloat?
    @State private var panelBottom: CGFloat = 0

    private var overlap: CGFloat {
        guard let keyboardTop else { return 0 }
        return max(0, panelBottom - keyboardTop + 8)
    }

    func body(content: Content) -> some View {
        content
            .padding(.bottom, overlap)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { panelBottom = g.frame(in: .global).maxY }
                    .onChange(of: g.frame(in: .global).maxY) { _, y in panelBottom = y }
            })
            .ignoresSafeArea(.keyboard)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
                guard let frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screen = UIScreen.main.bounds.height
                keyboardTop = frame.minY >= screen - 1 || frame.height < 60 ? nil : frame.minY
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardTop = nil
            }
            .animation(.easeOut(duration: 0.25), value: keyboardTop)
    }
}

extension View {
    func avoidingKeyboard() -> some View { modifier(KeyboardAvoiding()) }
}
