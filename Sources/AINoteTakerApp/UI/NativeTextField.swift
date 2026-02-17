import SwiftUI
import AppKit

struct NativeTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var isSearchField: Bool = false
    var isBorderless: Bool = false
    var onSubmit: (() -> Void)? = nil

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTextField
        var isProgrammaticUpdate = false

        init(parent: NativeTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            if isProgrammaticUpdate { return }
            guard let field = notification.object as? NSTextField else { return }
            let newValue = field.stringValue
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.text != newValue {
                    self.parent.text = newValue
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit?()
                return true
            }
            return false
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
                editor.insertionPointColor = .labelColor
                editor.textColor = .labelColor
            }
        }
    }

    private final class FocusTextField: NSTextField {
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
    }

    private final class FocusSearchField: NSSearchField {
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField
        if isSearchField {
            field = FocusSearchField(frame: .zero)
        } else {
            field = FocusTextField(frame: .zero)
        }

        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = !isBorderless
        field.isBordered = !isBorderless
        field.drawsBackground = !isBorderless
        field.textColor = .labelColor
        field.backgroundColor = isBorderless ? .clear : NSColor.windowBackgroundColor.withAlphaComponent(0.6)
        field.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.focusRingType = isBorderless ? .none : .default
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if nsView.stringValue != text {
            context.coordinator.isProgrammaticUpdate = true
            nsView.stringValue = text
            context.coordinator.isProgrammaticUpdate = false
        }
    }
}
