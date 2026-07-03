import SwiftUI

/// Renders `ToastCenter.current` as a floating banner at the bottom of the
/// window, above the recording pill. Attached once in RootView.
struct ToastOverlay: View {
    var toasts: ToastCenter
    /// Extra bottom padding for the banner, so it can lift above the
    /// recording pill when one is showing. Defaults to the plain bottom
    /// inset used when no pill is on screen.
    var bottomInset: CGFloat = 12

    var body: some View {
        VStack {
            Spacer()
            if let toast = toasts.current {
                ToastBanner(toast: toast) {
                    toasts.dismissCurrent()
                }
                .padding(.bottom, bottomInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: toasts.current)
        .allowsHitTesting(toasts.current != nil)
    }
}

private struct ToastBanner: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Tokens.warningAmber)
            // stays: white text on the dark toast surface in both modes
            Text(toast.message)
                .font(Tokens.body)
                .foregroundStyle(.white)
                .lineLimit(2)
            if let action = toast.action {
                Button(action.title) {
                    action.handler()
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(Tokens.body.weight(.semibold))
                .foregroundStyle(Tokens.accentBlue)
            }
            Button {
                onDismiss()
            } label: {
                // stays: white-on-dark dismiss glyph in both modes
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Tokens.darkSurface, in: RoundedRectangle(cornerRadius: Tokens.radiusCard))
        .overlay {
            // Separates the dark toast from an equally-dark window behind it.
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .stroke(Tokens.darkSurfaceStroke, lineWidth: 1)
        }
        // stays: shadow stays black in both modes
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: 440)
    }
}

#Preview {
    let toasts = ToastCenter()
    toasts.show("Recording mic only — system audio unavailable", actionTitle: "Open Settings") {}
    return ToastOverlay(toasts: toasts)
        .frame(width: 700, height: 400)
        .background(Color.gray.opacity(0.2))
}

#Preview("Dark") {
    let toasts = ToastCenter()
    toasts.show("Recording mic only — system audio unavailable", actionTitle: "Open Settings") {}
    return ToastOverlay(toasts: toasts)
        .frame(width: 700, height: 400)
        .background(Color.gray.opacity(0.2))
        .preferredColorScheme(.dark)
}
