import SwiftUI

/// Design tokens from the Recap design handoff. Prefer semantic system colors and
/// materials where they visually match; these constants cover the bespoke values.
public enum Tokens {
    // MARK: Colors
    public static let textPrimary = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)  // #1c1c1e
    public static let textBody = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)  // #2c2c2e
    public static let textSecondary = Color.black.opacity(0.45)
    public static let textTertiary = Color.black.opacity(0.35)
    public static let subtleBackground = Color(red: 0xFA / 255, green: 0xFA / 255, blue: 0xF8 / 255)  // #fafaf8
    public static let hairline = Color.black.opacity(0.07)
    public static let accentBlue = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)  // #0a84ff
    public static let recordRed = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)  // #ff453a
    public static let recordRedDark = Color(red: 0xD6 / 255, green: 0x3A / 255, blue: 0x30 / 255)  // #d63a30
    public static let successGreen = Color(red: 0x30 / 255, green: 0xB3 / 255, blue: 0x52 / 255)  // #30b352
    public static let successGreenText = Color(red: 0x2A / 255, green: 0x7D / 255, blue: 0x43 / 255)  // #2a7d43
    public static let successGreenTint = successGreen.opacity(0.12)
    public static let warningAmber = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)  // #ff9f0a
    public static let warningAmberText = Color(red: 0x9A / 255, green: 0x63 / 255, blue: 0x00 / 255)  // #9a6300
    public static let warningAmberTint = warningAmber.opacity(0.14)
    public static let darkSurface = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255).opacity(0.96)
    public static let chipBackground = Color.black.opacity(0.05)
    /// Speaker-label colors for diarized transcripts, cycled by speaker index.
    public static let speakerPalette: [Color] = [
        accentBlue,
        successGreenText,
        Color(red: 0xAF / 255, green: 0x52 / 255, blue: 0xDE / 255),  // #af52de purple
        warningAmberText,
        Color(red: 0x00 / 255, green: 0x7A / 255, blue: 0x8A / 255),  // #007a8a teal
        recordRedDark,
    ]

    // MARK: Radii
    public static let radiusChip: CGFloat = 5
    public static let radiusRow: CGFloat = 7
    public static let radiusButton: CGFloat = 8
    public static let radiusCard: CGFloat = 12

    // MARK: Type
    public static let pageTitle = Font.system(size: 24, weight: .bold)
    public static let sectionTitle = Font.system(size: 21, weight: .bold)
    public static let rowTitle = Font.system(size: 14, weight: .semibold)
    public static let body = Font.system(size: 14)
    public static let transcript = Font.system(size: 13)
    public static let meta = Font.system(size: 12)
    public static let caption = Font.system(size: 11)
    public static let microLabel = Font.system(size: 10.5, weight: .semibold)
    public static let timer = Font.system(size: 13, weight: .semibold).monospacedDigit()
}

/// Shared copy strings that appear in more than one place, so wording stays
/// in sync instead of drifting into near-duplicate phrasings.
public enum RecapCopy {
    /// Shown in the live meeting header and the toast fired when a
    /// recording starts without system audio.
    public static let systemAudioUnavailableMessage =
        "System audio isn't being captured — only your microphone is recording."
}

/// The Recap logo: rounded dark square containing three waveform bars.
public struct RecapLogo: View {
    var size: CGFloat

    public init(size: CGFloat = 22) {
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27)
            .fill(Tokens.textPrimary)
            .frame(width: size, height: size)
            .overlay {
                HStack(alignment: .bottom, spacing: size * 0.07) {
                    bar(height: 5 / 22)
                    bar(height: 10 / 22)
                    bar(height: 7 / 22)
                }
            }
            .accessibilityLabel("Recap")
    }

    private func bar(height fraction: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.white)
            .frame(width: size * 0.09, height: size * fraction)
    }
}
