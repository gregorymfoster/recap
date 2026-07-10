import AppKit
import SwiftUI

/// Design tokens from the Recap design handoff. Prefer semantic system colors and
/// materials where they visually match; these constants cover the bespoke values.
///
/// Recap follows the system appearance (no in-app light/dark picker). Every
/// token that needs to differ between modes is built with `dynamic(light:dark:)`,
/// which wraps an `NSColor(name:dynamicProvider:)` — the provider re-resolves
/// live when the system appearance flips, so nothing here may cache a
/// resolved `CGColor` or capture mutable state.
public enum Tokens {
    // MARK: Dynamic color helper

    /// Builds a `Color` that resolves `light` or `dark` based on the current
    /// drawing appearance. The provider closure must stay pure (Sendable-safe:
    /// no captured mutable state) so it can be invoked repeatedly and safely
    /// as the system appearance changes.
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        )
    }

    private static func dynamic(light: Color, dark: Color) -> Color {
        dynamic(light: NSColor(light), dark: NSColor(dark))
    }

    // MARK: Colors
    public static let textPrimary = dynamic(
        light: NSColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1),  // #1c1c1e
        dark: NSColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255, alpha: 1)  // #f2f2f4
    )
    public static let textBody = dynamic(
        light: NSColor(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1),  // #2c2c2e
        dark: NSColor(red: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE6 / 255, alpha: 1)  // #e4e4e6
    )
    public static let textSecondary = dynamic(light: NSColor.black.withAlphaComponent(0.45), dark: NSColor.white.withAlphaComponent(0.55))
    public static let textTertiary = dynamic(light: NSColor.black.withAlphaComponent(0.35), dark: NSColor.white.withAlphaComponent(0.38))
    /// Replaces `.background(.white)` across the app; the app's primary
    /// surface color, light window background → near-black in dark mode.
    public static let surface = dynamic(
        light: .white,
        dark: NSColor(red: 0x1E / 255, green: 0x1E / 255, blue: 0x20 / 255, alpha: 1)  // #1e1e20
    )
    public static let subtleBackground = dynamic(
        light: NSColor(red: 0xFA / 255, green: 0xFA / 255, blue: 0xF8 / 255, alpha: 1),  // #fafaf8
        dark: NSColor(red: 0x26 / 255, green: 0x26 / 255, blue: 0x28 / 255, alpha: 1)  // #262628
    )
    public static let hairline = dynamic(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.10))
    public static let accentBlue = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)  // #0a84ff
    /// Lighter accent used for icons/text against a blue-tinted background
    /// (e.g. `NextMeetingBanner`'s calendar glyph) — matches
    /// `QuietBlueOutlineButtonStyle`'s fixed blue. Not dynamic: reads
    /// correctly against a fixed blue-tint fill in both appearances.
    public static let accentBlueLight = Color(red: 109 / 255, green: 178 / 255, blue: 255 / 255)  // #6db2ff
    public static let recordRed = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)  // #ff453a
    public static let recordRedDark = Color(red: 0xD6 / 255, green: 0x3A / 255, blue: 0x30 / 255)  // #d63a30
    public static let successGreen = Color(red: 0x30 / 255, green: 0xB3 / 255, blue: 0x52 / 255)  // #30b352
    public static let successGreenText = dynamic(
        light: NSColor(red: 0x2A / 255, green: 0x7D / 255, blue: 0x43 / 255, alpha: 1),  // #2a7d43
        dark: NSColor(red: 0x4C / 255, green: 0xD0 / 255, blue: 0x74 / 255, alpha: 1)  // #4cd074
    )
    public static let successGreenTint = dynamic(light: successGreen.opacity(0.12), dark: successGreen.opacity(0.20))
    public static let warningAmber = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)  // #ff9f0a
    public static let warningAmberText = dynamic(
        light: NSColor(red: 0x9A / 255, green: 0x63 / 255, blue: 0x00 / 255, alpha: 1),  // #9a6300
        dark: NSColor(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x40 / 255, alpha: 1)  // #ffb340
    )
    public static let warningAmberTint = dynamic(light: warningAmber.opacity(0.14), dark: warningAmber.opacity(0.22))
    /// Fixed dark surface used by elements that stay dark-on-light-or-dark
    /// (the recording pill, toast banner): near-black in light mode, a
    /// slightly lighter near-black in dark mode so it still separates from
    /// the (now dark) window behind it.
    public static let darkSurface = dynamic(
        light: NSColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1).withAlphaComponent(0.96),
        dark: NSColor(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1).withAlphaComponent(0.96)
    )
    public static let chipBackground = dynamic(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.08))
    /// Solid fill for the session capsule (Phase 1 redesign) — a dark chip in
    /// dark mode, a light counterpart in light mode so the capsule still
    /// reads as a distinct surface rather than pinning to one appearance.
    public static let capsuleFill = dynamic(
        light: NSColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255, alpha: 1),  // light counterpart
        dark: NSColor(red: 0x2C / 255, green: 0x2C / 255, blue: 0x30 / 255, alpha: 1)  // #2c2c30
    )
    /// Translucent backing behind the session capsule — near-black at 96%
    /// opacity in dark mode, near-white counterpart in light mode.
    public static let capsuleBackgroundFill = dynamic(
        light: NSColor(red: 0xFC / 255, green: 0xFC / 255, blue: 0xFA / 255, alpha: 1).withAlphaComponent(0.96),
        dark: NSColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1).withAlphaComponent(0.96)  // rgba(28,28,30,.96)
    )
    /// 1pt stroke around the session capsule.
    public static let capsuleStroke = dynamic(light: NSColor.black.withAlphaComponent(0.12), dark: NSColor.white.withAlphaComponent(0.12))
    /// 1pt stroke that separates a `darkSurface` element from the window
    /// behind it — invisible-enough in light (a hairline on near-black) but
    /// load-bearing in dark, where the window can be nearly the same color.
    /// Applied unconditionally rather than only in dark mode.
    public static let darkSurfaceStroke = Color.white.opacity(0.12)
    /// Card/row hairline stroke — replaces ad hoc `Color.black.opacity(...)` strokes.
    public static let cardStroke = dynamic(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.10))
    /// Dimming scrim behind modal overlays (e.g. the search overlay).
    public static let scrim = dynamic(light: NSColor.black.withAlphaComponent(0.15), dark: NSColor.black.withAlphaComponent(0.45))
    /// Speaker-label colors for diarized transcripts, cycled by speaker index.
    public static let speakerPalette: [Color] = [
        accentBlue,
        successGreenText,
        Color(red: 0xAF / 255, green: 0x52 / 255, blue: 0xDE / 255),  // #af52de purple
        warningAmberText,
        dynamic(
            light: NSColor(red: 0x00 / 255, green: 0x7A / 255, blue: 0x8A / 255, alpha: 1),  // #007a8a teal
            dark: NSColor(red: 0x3F / 255, green: 0xB2 / 255, blue: 0xC4 / 255, alpha: 1)  // #3fb2c4
        ),
        recordRedDark,
    ]
    /// `LevelMeter`'s active-bar color — fixed, not dynamic (matches the
    /// system-green audio-level convention in both appearances).
    public static let meterActive = Color(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255)  // #32d74b
    /// `LevelMeter`'s inactive-bar color.
    public static let meterInactive = dynamic(light: NSColor.black.withAlphaComponent(0.18), dark: NSColor.white.withAlphaComponent(0.18))

    // MARK: Shadows

    /// Drop shadow used behind the session capsule — a plain `.shadow`
    /// modifier, since the capsule (unlike `FloatingIndicator`'s `NSPanel`)
    /// isn't clipped by a window boundary that would cut the shadow off.
    public static func capsuleShadow<V: View>(_ view: V) -> some View {
        view.shadow(color: .black.opacity(0.45), radius: 32, y: 12)
    }

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

    /// Toast fired when system audio started fine but goes silent mid-call
    /// (`RecorderEvent.systemAudioStalled`) — distinct from
    /// `systemAudioUnavailableMessage` because the tap looked healthy at
    /// start; this is a mid-recording dropout, not an unavailable source.
    public static let systemAudioStalledMessage =
        "System audio has gone quiet — the other participant may not be recording. Your microphone is still capturing."

    /// Toast fired when preflight finds no usable audio source at all — no
    /// meeting record is created for this attempt.
    public static let noAudioAccessMessage =
        "Can't record — Recap has no audio access. Allow Microphone or System Audio in Settings, then try again."

    /// Fix-it hint under the Microphone permission row when denied.
    static let microphoneDeniedHint =
        "Turn on Recap under Microphone, then come back — status updates automatically."

    /// Fix-it hint under the Calendar permission row when denied.
    static let calendarDeniedHint =
        "Turn on Recap under Calendars, then come back — status updates automatically."

    /// Fix-it hint under the System Audio row after a denied probe.
    static let systemAudioDeniedHint =
        "Turn on Recap under Screen & System Audio Recording, then test again."

    /// Caption under the System Audio row before it's ever been tested —
    /// sets expectations that testing may trigger a macOS prompt.
    static let systemAudioNotDeterminedHint =
        "macOS may ask for permission — click Allow."
}

/// The Recap logo: rounded dark square containing three waveform bars.
public struct RecapLogo: View {
    var size: CGFloat

    public init(size: CGFloat = 22) {
        self.size = size
    }

    // Pinned rather than following `Tokens.textPrimary` (which flips to a
    // near-white in dark mode) — the brand square should stay a dark chip in
    // both appearances rather than inverting to a light square.
    private static let fill = Color(
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)  // #3a3a3c
                : NSColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)  // #1c1c1e
        }
    )

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27)
            .fill(Self.fill)
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
            // stays: white bars read against the pinned-dark logo square in both modes
            .fill(.white)
            .frame(width: size * 0.09, height: size * fraction)
    }
}
