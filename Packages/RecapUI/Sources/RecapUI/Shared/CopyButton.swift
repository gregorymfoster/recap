import AppKit
import SwiftUI

/// Small "copy to clipboard" chip used next to the transcript and notes: one
/// click writes the provided text to the general pasteboard and shows a
/// transient "Copied" confirmation before reverting.
struct CopyButton: View {
    /// Tooltip describing what gets copied, e.g. "Copy transcript".
    var help: String
    /// Window-toolbar scale: 28pt-tall stroked capsule matching the toolbar
    /// bubble family (search field, Record). The default stays chip-sized
    /// for in-content use next to the transcript.
    var toolbarStyle = false
    /// Produces the text at click time, so callers don't rebuild strings on
    /// every render.
    var text: () -> String

    @State private var copied = false
    @State private var revertTask: Task<Void, Never>?

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text(), forType: .string)
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            revertTask?.cancel()
            revertTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: toolbarStyle ? 6 : 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: toolbarStyle ? 11 : 9, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(toolbarStyle ? .system(size: 12.5, weight: .medium) : Tokens.microLabel)
            }
            .foregroundStyle(copied ? Tokens.successGreenText : Tokens.textSecondary)
            .padding(.horizontal, toolbarStyle ? 14 : 8)
            .padding(.vertical, toolbarStyle ? 0 : 3)
            .frame(height: toolbarStyle ? 28 : nil)
            .background(
                copied ? Tokens.successGreenTint : Tokens.chipBackground,
                in: Capsule()
            )
            .overlay {
                if toolbarStyle {
                    Capsule().stroke(Tokens.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .onDisappear { revertTask?.cancel() }
    }
}

#Preview {
    HStack(spacing: 12) {
        CopyButton(help: "Copy transcript") { "sample" }
        CopyButton(help: "Copy summary") { "sample" }
    }
    .padding(30)
}
