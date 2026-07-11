import SwiftUI

/// Reusable click-to-rename title: displays `text`, and on a click (or
/// double-click, per `activatesOnDoubleClick`) swaps in a real `TextField`
/// seeded with the current value. Commits on Return/focus-loss, cancels on
/// Escape without renaming — same semantics as `MeetingDetailView`'s
/// title-editing today.
///
/// Doc note: `MeetingDetailView` and the recording view still own their own
/// inline title-editing implementations; they adopt this component in a
/// later phase rather than being rewired here.
struct EditableTitle: View {
    var text: String
    var font: Font = .system(size: 22, weight: .bold)
    var foreground: Color = Tokens.textPrimary
    /// Dashed-underline styling (`Tokens.editableUnderline`) — used where the
    /// title needs a persistent "this is editable" affordance rather than
    /// relying on a hover tooltip.
    var showsDashedUnderline: Bool = false
    /// Hint shown as a tooltip on the read-only state; `nil` omits it.
    var hint: String? = "Click to rename"
    var activatesOnDoubleClick: Bool = false
    var onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var editedText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("Title", text: $editedText)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commit() }
                    }
            } else {
                Text(text)
                    .font(font)
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .overlay(alignment: .bottom) {
                        if showsDashedUnderline {
                            Rectangle()
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundStyle(Tokens.editableUnderline)
                                .frame(height: 1)
                                .offset(y: 2)
                        }
                    }
                    .modifier(OptionalHelp(hint: hint))
                    .contentShape(Rectangle())
                    .onTapGesture(count: activatesOnDoubleClick ? 2 : 1) { begin() }
            }
        }
    }

    private func begin() {
        editedText = text
        isEditing = true
        fieldFocused = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != text {
            onCommit(trimmed)
        }
    }

    private func cancel() {
        isEditing = false
    }
}

/// Applies `.help` only when a hint is provided, avoiding an empty-string
/// tooltip when the caller passes `hint: nil`.
private struct OptionalHelp: ViewModifier {
    var hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.help(hint)
        } else {
            content
        }
    }
}
