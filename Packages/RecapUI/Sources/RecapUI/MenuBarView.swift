import AppKit
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

/// Standard menu-style content for the extra.
public struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    private let stores: AppStores

    public init(stores: AppStores) {
        self.stores = stores
    }

    public var body: some View {
        if stores.session.isRecording {
            Button("Stop Recording") {
                stores.stopRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            Button(stores.session.isPaused ? "Resume Recording" : "Pause Recording") {
                stores.togglePause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            if let record = stores.session.activeRecord {
                Button("Open Meeting Notes") {
                    stores.showMeeting(record.meeting.id)
                    activateApp()
                }
            }
        } else {
            Button("Start Recording") {
                stores.startRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            let recent = stores.library.meetings.prefix(3)
            if !recent.isEmpty {
                Divider()
                ForEach(recent) { record in
                    Button(record.meeting.title) {
                        stores.showMeeting(record.meeting.id)
                        activateApp()
                    }
                }
            }
        }
        if stores.updateStatus.isAvailable {
            Divider()
            Button("Update Available — Install…") {
                stores.updateStatus.triggerInstall()
                activateApp()
            }
        }
        Divider()
        Button("Open Recap") {
            activateApp()
        }
        Button("Settings…") {
            stores.openMainWindow(section: .settings, openWindow: { openWindow(id: $0) })
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    /// Brings the main window forward (recreating it if it was closed).
    private func activateApp() {
        stores.openMainWindow(openWindow: { openWindow(id: $0) })
    }
}
