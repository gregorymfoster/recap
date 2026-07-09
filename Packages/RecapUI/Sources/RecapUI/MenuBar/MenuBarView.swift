import AppKit
import Foundation
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
///   - Recording: a header block with the live elapsed label, pause, and
///     stop, then Open meeting / Settings.
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

    public init(stores: AppStores) {
        self.stores = stores
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if stores.session.isRecording {
                recordingHeader
                Divider().padding(.vertical, 5)
                menuRow("Open meeting") {
                    if let record = stores.session.activeRecord {
                        stores.showMeeting(record.meeting.id)
                    }
                    activateApp()
                }
                .axID(.menuBarOpenMeetingButton)
                menuRow("Settings…", trailing: "⌘,") {
                    openSettings()
                }
                .axID(.menuBarSettingsButton)
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
        .onAppear(perform: refreshUpNext)
    }

    // MARK: Recording header

    private var recordingHeader: some View {
        HStack(spacing: 9) {
            PulsingDot(
                color: stores.session.isPaused ? Tokens.warningAmber : Tokens.recordRed,
                pulsing: !stores.session.isPaused,
                size: 8
            )
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
            Button {
                stores.togglePause()
            } label: {
                Image(systemName: stores.session.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .axID(.menuBarPauseButton)
            Button {
                stores.stopRecording()
            } label: {
                Text("Stop")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .axID(.menuBarStopButton)
        }
        .padding(.horizontal, 4)
        .padding(.top, 3)
        .padding(.bottom, 2)
    }

    private var headerStatusLine: String {
        guard let elapsed = stores.session.menuBarElapsedLabel else { return "" }
        return stores.session.isPaused ? "Paused · \(elapsed)" : "Recording · \(elapsed)"
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
                if case .transcribing(let progress) = record.meeting.status {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Tokens.accentBlue)
                } else {
                    Text(Duration.seconds(record.meeting.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tokens.textSecondary)
                }
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
