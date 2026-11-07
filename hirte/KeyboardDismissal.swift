import SwiftUI
import UIKit

extension View {
    /// Closes the keyboard when the person taps anywhere that isn't a text field or text view.
    ///
    /// A tap recognizer on the window that doesn't cancel touches, so buttons, toggles and rows
    /// still get their taps.
    func dismissesKeyboardOnTapOutside() -> some View {
        background(KeyboardDismissal())
    }
}

private struct KeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {}

    static func dismantleUIView(_ view: Anchor, coordinator: ()) {
        view.detach()
    }

    final class Anchor: UIView, UIGestureRecognizerDelegate {
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(recognizer)
        }

        func detach() {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }

        @objc private func tapped() {
            window?.endEditing(true)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
