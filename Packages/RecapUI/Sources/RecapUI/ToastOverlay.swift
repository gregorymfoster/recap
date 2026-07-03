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

    private var isWarning: Bool { toast.style == .warning }

    var body: some View {
        HStack(spacing: 12) {
            // Standard toasts keep the original circle glyph (unchanged
            // visual for existing permission/error banners); the warning
            // style uses a triangle, matching mock 6c's "⚠" mic-loss toast.
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isWarning ? Tokens.warningAmberText : Tokens.warningAmber)
            Text(toast.message)
                .font(Tokens.body)
                // stays: white text on the dark toast surface for the
                // standard style in both modes; the warning style uses the
                // dynamic amber text token so it stays legible on its tint.
                .foregroundStyle(isWarning ? Tokens.warningAmberText : .white)
                .lineLimit(2)
            if let action = toast.action {
                Button(action.title) {
                    action.handler()
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(Tokens.body.weight(.semibold))
                .foregroundStyle(isWarning ? Tokens.warningAmberText : Tokens.accentBlue)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isWarning ? Tokens.warningAmberText.opacity(0.7) : .white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            if isWarning {
                RoundedRectangle(cornerRadius: Tokens.radiusButton)
                    .fill(Tokens.warningAmberTint)
            } else {
                RoundedRectangle(cornerRadius: Tokens.radiusCard)
                    .fill(Tokens.darkSurface)
            }
        }
        .overlay {
            if isWarning {
                RoundedRectangle(cornerRadius: Tokens.radiusButton)
                    .stroke(Tokens.warningAmber.opacity(0.25), lineWidth: 1)
            } else {
                // Separates the dark toast from an equally-dark window behind it.
                RoundedRectangle(cornerRadius: Tokens.radiusCard)
                    .stroke(Tokens.darkSurfaceStroke, lineWidth: 1)
            }
        }
        // stays: shadow stays black in both modes
        .shadow(color: .black.opacity(isWarning ? 0.12 : 0.25), radius: 12, y: 4)
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

#Preview("Warning (mic-loss)") {
    let toasts = ToastCenter()
    toasts.show(
        "Mic disconnected — switched to MacBook Pro Microphone",
        style: .warning, actionTitle: "Change…"
    ) {}
    return ToastOverlay(toasts: toasts)
        .frame(width: 700, height: 400)
        .background(Color.gray.opacity(0.2))
        .preferredColorScheme(.dark)
}
