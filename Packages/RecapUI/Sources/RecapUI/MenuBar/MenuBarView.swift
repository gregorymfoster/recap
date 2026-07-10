import AppKit
import CoreAudio
import Foundation
import RecapAudio
import RecapCore
import SwiftUI

/// Menu bar extra: start/stop recording and jump to meetings without the app
/// frontmost. The label carries the live state — a red dot plus per-second
/// elapsed time while recording (a pause glyph plus frozen time while
/// paused), the waveform glyph otherwise. The elapsed time is a plain string
/// ticked once per second by `MeetingSessionStore` — never `.timer` Text or
/// `TimelineView`, which peg the CPU inside a MenuBarExtra label (see
/// `MenuBarLabel.body`).
public struct MenuBarLabel: View {
    private let stores: AppStores

    public init(stores: AppStores) {
        self.stores = stores
    }

    public var body: some View {
        // No time-varying SwiftUI content here — `.timer` Text AND periodic
        // TimelineView both degenerate into a zero-delay status-item render
        // loop inside a MenuBarExtra label (100% CPU, unbounded memory;
        // sampled live on macOS 26.4: MenuBarExtraHost.requestUpdate →
        // setImage in every stack). The label renders only plain state;
        // MeetingSessionStore mutates `menuBarElapsedLabel` once per second,
        // so the label re-renders exactly once per visible tick.
        if let elapsed = stores.session.menuBarElapsedLabel {
            HStack(spacing: 4) {
                Image(systemName: stores.session.isPaused ? "pause.circle.fill" : "record.circle.fill")
                Text(elapsed)
                    .monospacedDigit()
            }
        } else if stores.updateStatus.isAvailable {
            // Idle, but a new version is ready — signal it in the menu bar.
            Image(systemName: "arrow.down.circle.fill")
        } else {
            Image(systemName: "waveform")
        }
    }
}

/// Rich popover content for the menu bar extra (design mock 8a), for use
/// with `.menuBarExtraStyle(.window)`. Two layouts:
///   - Idle: start-recording row, an "Up next · Calendar" section (only when
///     calendar access is already granted and a meeting-shaped event starts
///     within 8h), a "Recent" section (up to 2 meetings), then the standard
///     Open/Settings/Quit rows.
///   - Recording (Phase 3C): a header block with the live elapsed label,
///     full-width Pause/Resume + Stop buttons, a device row sharing
///     `InputDeviceMenu` with `SessionCapsule`, then Open Recap.
/// Buttons in `.window`-style content don't auto-dismiss the popover the way
/// `.menu`-style items do, so every action dismisses explicitly via
/// `@Environment(\.dismiss)`.
public struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    private let stores: AppStores
    /// Not started/polled — only used for the one-shot, never-prompting
    /// `upNext()` query, refreshed each time the popover appears. Kept as
    /// `@State` (not re-created per body evaluation) so it isn't
    /// reconstructed every render.
    @State private var calendarQuery = CalendarWatcher(onMeetingStarting: { _ in })
    @State private var upNext: CalendarEventSnapshot?
    /// The device row's `InputDeviceMenu` options — refreshed the same way
    /// `MeetingDetailView`/`RecordingView` do (`onAppear` + a live device-list
    /// listener), since the popover can appear while a recording is already
    /// under way.
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var deviceListListener: AudioObjectPropertyListenerBlock?

    public init(stores: AppStores) {
        self.stores = stores
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if stores.session.isRecording {
                recordingHeader
                recordingButtons
                Divider().padding(.vertical, 5)
                deviceRow
                Divider().padding(.vertical, 5)
                menuRow("Open Recap") {
                    activateApp()
                }
                .axID(.menuBarOpenAppButton)
            } else {
                menuRow("Start recording", trailing: "⌥⌘R") {
                    stores.startRecording()
                    dismiss()
                }
                .axID(.menuBarStartRecordingButton)
                if let upNext {
                    Divider().padding(.vertical, 5)
                    microHeader("Up next · Calendar")
                    upNextRow(upNext)
                }
                let recent = stores.library.meetings.prefix(2)
                if !recent.isEmpty {
                    Divider().padding(.vertical, 5)
                    microHeader("Recent")
                    ForEach(recent) { record in
                        recentRow(record)
                    }
                }
                if stores.updateStatus.isAvailable {
                    Divider().padding(.vertical, 5)
                    menuRow("Update Available — Install…") {
                        stores.updateStatus.triggerInstall()
                        activateApp()
                    }
                    .axID(.menuBarUpdateAvailableButton)
                }
                Divider().padding(.vertical, 5)
                menuRow("Open Recap") {
                    activateApp()
                }
                .axID(.menuBarOpenAppButton)
                menuRow("Settings…", trailing: "⌘,") {
                    openSettings()
                }
                .axID(.menuBarSettingsButton)
                menuRow("Quit Recap", trailing: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .axID(.menuBarQuitButton)
            }
        }
        .padding(6)
        .frame(width: 270)
        .accessibilityElement(children: .contain)
        .axID(.menuBarContent)
        .onAppear {
            refreshUpNext()
            refreshInputDevices()
        }
        .onDisappear {
            if let deviceListListener {
                AudioInputDevices.removeDeviceListListener(deviceListListener)
            }
            deviceListListener = nil
        }
    }

    // MARK: Recording header

    private var recordingHeader: some View {
        HStack(spacing: 9) {
            if stores.session.isPaused {
                Text("Paused")
                    .font(Tokens.microLabel)
                    .foregroundStyle(Tokens.warningAmber)
                    .fixedSize()
            } else {
                PulsingDot(color: Tokens.recordRed, pulsing: true, size: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(stores.session.activeRecord?.meeting.title ?? "Recording")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(headerStatusLine)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 4)
        .padding(.top, 3)
        .padding(.bottom, 2)
    }

    /// Full-width, side-by-side Pause/Resume (ghost) + Stop (red) buttons —
    /// the popover's recording-state control surface, mirroring
    /// `SessionCapsule`'s pause/stop pairing.
    private var recordingButtons: some View {
        HStack(spacing: 8) {
            Button {
                stores.togglePause()
            } label: {
                Text(stores.session.isPaused ? "Resume" : "Pause")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusRow))
            }
            .buttonStyle(.plain)
            .axID(.menuBarPauseButton)

            Button {
                stores.stopRecording()
            } label: {
                Text("Stop")
                    // stays: white text on the fixed recordRed fill in both modes
                    .foregroundStyle(.white)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Tokens.recordRed, in: RoundedRectangle(cornerRadius: Tokens.radiusRow))
            }
            .buttonStyle(.plain)
            .axID(.menuBarStopButton)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }

    /// "Mic: <device>" plus the shared `InputDeviceMenu` — switching here
    /// goes through the same `settings.preferredInputUID`/
    /// `session.setPreferredInputUID` path as `RecordingView`'s capsule.
    private var deviceRow: some View {
        HStack(spacing: 6) {
            Text("Mic: \(stores.session.activeInputDeviceName ?? "System default")")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            InputDeviceMenu(
                devices: inputDevices, selectedUID: stores.settings.preferredInputUID,
                onSelect: { uid in
                    stores.settings.preferredInputUID = uid
                    stores.session.setPreferredInputUID(uid)
                },
                axID: .menuBarDeviceMenu
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var headerStatusLine: String {
        guard let elapsed = stores.session.menuBarElapsedLabel else { return "" }
        return stores.session.isPaused ? "Paused · \(elapsed)" : "Recording · \(elapsed)"
    }

    private func refreshInputDevices() {
        inputDevices = AudioInputDevices.inputDevices()
        deviceListListener = AudioInputDevices.addDeviceListListener(queue: .main) {
            Task { @MainActor in inputDevices = AudioInputDevices.inputDevices() }
        }
    }

    // MARK: Idle sections

    private func microHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(Tokens.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 3)
    }

    private func upNextRow(_ event: CalendarEventSnapshot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(UpNextEvent.timeLine(for: event))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            Button("Record") {
                stores.startRecording(title: event.title, attendees: event.otherAttendees)
                activateApp()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Tokens.recordRed)
            .fixedSize()
            .axID(.menuBarUpNextRecordButton)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusRow))
        .padding(.horizontal, 2)
    }

    private func recentRow(_ record: MeetingRecord) -> some View {
        Button {
            stores.showMeeting(record.meeting.id)
            activateApp()
        } label: {
            HStack(spacing: 8) {
                Text(record.meeting.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                // Deliberately no per-row processing percentage here (Phase
                // 3C) — a duration is a stable fact about the meeting, a
                // live progress number is churny state that doesn't belong
                // in this compact "Recent" list.
                Text(Duration.seconds(record.meeting.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .axID(.menuBarRecentRow(record.meeting.id.uuidString))
    }

    // MARK: Standard rows

    private func menuRow(_ title: String, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Tokens.textPrimary)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    /// Brings the main window forward (recreating it if it was closed), then
    /// dismisses the popover — `.window`-style MenuBarExtra content doesn't
    /// auto-dismiss on button taps the way `.menu`-style items do.
    private func activateApp() {
        stores.openMainWindow(openWindow: { openWindow(id: $0) })
        dismiss()
    }

    private func openSettings() {
        SettingsOpener.open()
        dismiss()
    }

    private func refreshUpNext() {
        upNext = calendarQuery.upNext()
    }
}

#Preview("Idle") {
    MenuBarContent(stores: AppStores(library: .fixture()))
        .background(Tokens.surface)
}

#Preview("Recording") {
    let stores = AppStores(library: .fixture())
    return MenuBarContent(stores: stores)
        .background(Tokens.surface)
        .task {
            guard let record = stores.library.startNewMeeting(title: "Weekly standup") else { return }
            await stores.session.start(record: record)
        }
}

#Preview("Idle — Dark") {
    MenuBarContent(stores: AppStores(library: .fixture()))
        .background(Tokens.surface)
        .preferredColorScheme(.dark)
}
