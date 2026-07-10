import SwiftUI

/// The Library's "update available" banner (layered update-available UX):
/// a single, high-signal full-width row shown above the meeting list when
/// `UpdateStatus.showsBanner` is true. Same visual grammar as
/// `NextMeetingBanner` — quiet blue treatment, an Install action, plus a
/// quiet xmark to dismiss without acting.
struct UpdateAvailableBanner: View {
    var version: String?
    var onInstall: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.accentBlueLight)
            Text(headline)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button("Install", action: onInstall)
                .buttonStyle(.quietBlueOutline)
                .axID(.libraryUpdateBannerInstallButton)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .axID(.libraryUpdateBannerDismissButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Tokens.accentBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Tokens.accentBlue.opacity(0.22), lineWidth: 1))
        .axID(.libraryUpdateBanner)
    }

    private var headline: String {
        if let version {
            "Recap \(version) is available"
        } else {
            "A new version of Recap is available"
        }
    }
}

#Preview {
    UpdateAvailableBanner(version: "1.4.0", onInstall: {}, onDismiss: {})
        .padding(24)
        .frame(width: 700)
        .background(Tokens.surface)
}

#Preview("No version") {
    UpdateAvailableBanner(version: nil, onInstall: {}, onDismiss: {})
        .padding(24)
        .frame(width: 700)
        .background(Tokens.surface)
}

#Preview("Dark") {
    UpdateAvailableBanner(version: "1.4.0", onInstall: {}, onDismiss: {})
        .padding(24)
        .frame(width: 700)
        .background(Tokens.surface)
        .preferredColorScheme(.dark)
}
