import SwiftUI
import UIKit

/// A scrolling text view for pasted keys.
///
/// SwiftUI's `TextEditor` showed only part of a long key on a device (the text was cut off
/// halfway down the box), and it hyphenated base64 lines where it wrapped them. This uses
/// TextKit 1 and wraps at any character, without hyphens.
struct KeyTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.dataDetectorTypes = []
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.hyphenationFactor = 0
        view.typingAttributes = [
            .font: UIFontMetrics(forTextStyle: .caption1)
                .scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular)),
            .foregroundColor: UIColor.label,
            .paragraphStyle: style,
        ]
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        view.attributedText = NSAttributedString(string: text, attributes: view.typingAttributes)
        view.setContentOffset(.zero, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
        }
    }
}
