import RecapAudio
import RecapCore
import SwiftUI

/// One capsule component family, two variants — Phase 3C's replacement for
/// the separate `RecordingPill` (docked, full window) and `FloatingIndicator`
/// (background NSPanel) implementations, which duplicated the same
/// dot/timer/pause/stop chrome with drifting details. `.docked` is the full
/// control surface (meter, device switcher, pause, stop) hosted inside
/// `RecordingView`; `.floating` is the compact glanceable version hosted by
/// `FloatingIndicatorController`'s NSPanel while Recap is backgrounded.
enum SessionCapsuleVariant {
    case docked
    case floating
}

struct SessionCapsule: View {
    var variant: SessionCapsuleVariant
    var clock: RecordingClock
    var isPaused: Bool
    var levels: [Float]
    /// Selectable input devices for the device menu (docked only).
    var inputDevices: [AudioInputDevice] = []
    var selectedDeviceUID: String?
    var onSelectDevice: (String?) -> Void = { _ in }
    var onPauseToggle: () -> Void
    var onStop: () -> Void

    var body: some View {
        switch variant {
        case .docked: Tokens.capsuleShadow(dockedContent)
        case .floating: Tokens.capsuleShadow(floatingContent)
        }
    }

    // MARK: Docked

    private var dockedContent: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                statusIndicator(dotSize: 8)
                timer(font: .system(size: 14, weight: .bold).monospacedDigit(), color: Tokens.textPrimary)
            }
            divider(height: 18)
            HStack(spacing: 8) {
                LevelMeter(levels: levels)
                    .opacity(isPaused ? 0.35 : 1)
                // The menu's own label carries the device name — a separate
                // deviceName Text here would show the same thing twice.
                InputDeviceMenu(
                    devices: inputDevices, selectedUID: selectedDeviceUID, onSelect: onSelectDevice,
                    axID: .capsuleDeviceMenu
                )
            }
            divider(height: 18)
            HStack(spacing: 10) {
                Button(action: onPauseToggle) {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(Tokens.chipBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: [.command, .option])
                .help(isPaused ? "Resume recording (⌥⌘P)" : "Pause recording (⌥⌘P)")
                .axID(.capsulePauseButton)

                Button(action: onStop) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                        Text("Stop")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    // stays: white text/glyph on the fixed recordRed fill in both modes
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Tokens.recordRed, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .axID(.capsuleStopButton)
            }
        }
        .padding(.top, 8)
        .padding(.trailing, 9)
        .padding(.bottom, 8)
        .padding(.leading, 19)
        .background(Tokens.capsuleFill, in: Capsule())
        .overlay { Capsule().stroke(Tokens.capsuleStroke, lineWidth: 1) }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .axID(.sessionCapsule)
    }

    // MARK: Floating

    // Intentionally no input-device menu here — per the 11f mock (design
    // decision 2026-07-10), this supersedes the handoff README's "every
    // recording surface" global rule. Device switching lives in the menu-bar
    // popover and the `.docked` in-window capsule; the floating background
    // capsule stays a compact glanceable status, not a full control surface.
    private var floatingContent: some View {
        HStack(spacing: 10) {
            statusIndicator(dotSize: 7)
            timer(font: .system(size: 12, weight: .semibold).monospacedDigit(), color: Tokens.textPrimary)
                .opacity(isPaused ? 0.5 : 1)
            Button(action: onPauseToggle) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .background(Tokens.chipBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .help(isPaused ? "Resume recording" : "Pause recording")
            .axID(.floatingPauseButton)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Tokens.recordRed, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop recording")
            .axID(.floatingStopButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Tokens.capsuleBackgroundFill, in: Capsule())
        .overlay { Capsule().stroke(Tokens.capsuleStroke, lineWidth: 1) }
        // No SwiftUI .shadow beyond `Tokens.capsuleShadow` here: the
        // NSPanel that hosts this view is sized exactly to its fitting
        // size, so unlike the old `FloatingIndicator` the shadow does need
        // to render — the panel background is transparent, not clipped.
        .fixedSize()
        .accessibilityElement(children: .contain)
        .axID(.floatingIndicator)
        .accessibilityLabel(isPaused ? "Recording paused" : "Recording in progress")
    }

    // MARK: Shared pieces

    /// Red pulsing dot while recording; a labeled amber "Paused" chip once
    /// paused — never color-only, per the design spec.
    @ViewBuilder
    private func statusIndicator(dotSize: CGFloat) -> some View {
        if isPaused {
            Text("Paused")
                .font(Tokens.microLabel)
                .foregroundStyle(Tokens.warningAmber)
                .fixedSize()
        } else {
            PulsingDot(color: Tokens.recordRed, pulsing: true, size: dotSize)
        }
    }

    /// Running: a `TimelineView` ticking from the clock's synthetic start
    /// date (folding in pauses already served). Paused: a static string — a
    /// ticking `Text(style: .timer)` cannot be frozen, so rendering switches
    /// to a plain `Text` instead.
    @ViewBuilder
    private func timer(font: Font, color: Color) -> some View {
        if isPaused {
            Text(ElapsedLabel.format(seconds: Int(clock.elapsed(at: .now))))
                .font(font)
                .foregroundStyle(color.opacity(0.7))
        } else {
            let start = clock.syntheticStartDate(at: .now)
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(ElapsedLabel.format(seconds: max(0, Int(context.date.timeIntervalSince(start)))))
                    .font(font)
                    .foregroundStyle(color)
            }
        }
    }

    private func divider(height: CGFloat) -> some View {
        Rectangle()
            .fill(Tokens.hairline)
            .frame(width: 1, height: height)
    }
}

#Preview("Docked") {
    VStack(spacing: 24) {
        SessionCapsule(
            variant: .docked, clock: RecordingClock(startedAt: .now.addingTimeInterval(-1453)),
            isPaused: false, levels: (0..<5).map { _ in Float.random(in: 0.1...0.9) },
            onPauseToggle: {}, onStop: {}
        )
        SessionCapsule(
            variant: .docked,
            clock: {
                var clock = RecordingClock(startedAt: .now.addingTimeInterval(-1453))
                clock.pause(at: .now)
                return clock
            }(),
            isPaused: true, levels: [Float](repeating: 0, count: 5),
            onPauseToggle: {}, onStop: {}
        )
    }
    .padding(40)
    .background(Tokens.surface)
}

#Preview("Floating") {
    VStack(spacing: 24) {
        SessionCapsule(
            variant: .floating, clock: RecordingClock(startedAt: .now.addingTimeInterval(-1453)),
            isPaused: false, levels: (0..<4).map { _ in Float.random(in: 0.2...0.9) },
            onPauseToggle: {}, onStop: {}
        )
        SessionCapsule(
            variant: .floating,
            clock: {
                var clock = RecordingClock(startedAt: .now.addingTimeInterval(-1453))
                clock.pause(at: .now)
                return clock
            }(),
            isPaused: true, levels: [Float](repeating: 0, count: 4),
            onPauseToggle: {}, onStop: {}
        )
    }
    .padding(40)
    .background(
        LinearGradient(colors: [Color(red: 0.24, green: 0.29, blue: 0.36), Color(red: 0.16, green: 0.19, blue: 0.25)], startPoint: .top, endPoint: .bottom)
    )
}
