import AppKit
import SwiftUI

/// Menu bar extra: start/stop recording and jump to meetings without the app
/// frontmost. The label carries the live state — a red dot plus ticking
/// elapsed time while recording, the waveform glyph otherwise.
public struct MenuBarLabel: View {
    private let stores: AppStores

    public init(stores: AppStores) {
        self.stores = stores
    }

    public var body: some View {
        if let startedAt = stores.session.startedAt {
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                Text(startedAt, style: .timer)
                    .monospacedDigit()
            }
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
