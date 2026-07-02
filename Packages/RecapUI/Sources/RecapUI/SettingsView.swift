import AppKit
import AVFoundation
import CoreAudio
import EventKit
import RecapAudio
import SwiftUI

/// The Settings section: permissions, save location, recording sources, processing.
struct SettingsView: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueStore.self) private var queue: QueueStore?
    @State private var micStatus = AVAudioApplication.shared.recordPermission
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var inputDevices: [AudioInputDevice] = AudioInputDevices.inputDevices()
    @State private var deviceListListener: AudioObjectPropertyListenerBlock?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Permissions") {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    status: micStatus.permissionStatus
                ) {
                    PrivacyPane.open(PrivacyPane.microphone)
                }
                PermissionRow(
                    icon: "speaker.wave.2.fill",
                    title: "System Audio",
                    status: systemAudioStatus
                ) {
                    PrivacyPane.open(PrivacyPane.systemAudio)
                }
                PermissionRow(
                    icon: "calendar",
                    title: "Calendar",
                    status: calendarStatus.permissionStatus
                ) {
                    PrivacyPane.open(PrivacyPane.calendars)
                }
                Text("Recap re-checks these whenever this window comes forward, so a change in System Settings shows up here right away.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshPermissionStatuses()
            }

            Section("Storage") {
                LabeledContent("Meetings folder") {
                    HStack(spacing: 10) {
                        Text(tildePath(settings.saveRootPath))
                            .font(Tokens.meta)
                            .foregroundStyle(Tokens.textSecondary)
                        Button("Change…") { pickFolder() }
                            .controlSize(.small)
                    }
                }
                Text("Notes and audio are plain files — Markdown, JSON, and m4a — readable by any app. A new folder takes effect the next time Recap opens.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }

            Section("Recording") {
                Picker("Microphone", selection: $settings.preferredInputUID) {
                    Text("System default").tag(String?.none)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .onChange(of: settings.preferredInputUID) {
                    stores?.session.setPreferredInputUID(settings.preferredInputUID)
                }
                Text("Switching mid-recording keeps the file writing — expect a brief gap.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
                Toggle("Capture system audio (other participants)", isOn: $settings.includeSystemAudio)
                Text("Uses macOS's System Audio Recording permission. Turn off to record only your microphone.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
                LabeledContent("Start or stop recording anywhere", value: "⌥⌘R")
                Text("Works even when Recap isn't the active app — also available from the menu bar icon.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
            .onAppear {
                inputDevices = AudioInputDevices.inputDevices()
                deviceListListener = AudioInputDevices.addDeviceListListener(queue: .main) {
                    Task { @MainActor in inputDevices = AudioInputDevices.inputDevices() }
                }
            }
            .onDisappear {
                if let deviceListListener {
                    AudioInputDevices.removeDeviceListListener(deviceListListener)
                }
                deviceListListener = nil
            }

            Section("Calendar") {
                Picker("When a calendar meeting starts", selection: $settings.calendarAutoRecord) {
                    Text("Do nothing").tag(CalendarAutoRecordMode.off)
                    Text("Ask to record").tag(CalendarAutoRecordMode.prompt)
                    Text("Record automatically").tag(CalendarAutoRecordMode.auto)
                }
                .onChange(of: settings.calendarAutoRecord) {
                    stores?.applyCalendarAutoRecordSetting()
                }
                if stores?.calendarAccessDenied == true {
                    Text("Calendar access is off. Allow it in System Settings → Privacy & Security → Calendars.")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.warningAmberText)
                } else {
                    Text("Detects events with a video-call link or invitees. The recording is titled after the event, with attendees attached.")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.textTertiary)
                }
            }

            Section("Sync") {
                Toggle("Copy finished meetings into an Obsidian vault", isOn: $settings.syncsToObsidian)
                    .onChange(of: settings.syncsToObsidian) {
                        if settings.syncsToObsidian {
                            if settings.obsidianVaultPath.isEmpty { pickVaultFolder() }
                            stores?.exportAllReadyMeetingsToObsidian()
                        }
                    }
                if settings.syncsToObsidian {
                    LabeledContent("Vault folder") {
                        HStack(spacing: 10) {
                            Text(settings.obsidianVaultPath.isEmpty
                                ? "None selected"
                                : tildePath(settings.obsidianVaultPath))
                                .font(Tokens.meta)
                                .foregroundStyle(Tokens.textSecondary)
                            Button("Change…") { pickVaultFolder() }
                                .controlSize(.small)
                        }
                    }
                }
                Text("Each meeting becomes one Markdown note — enhanced notes plus the speaker-labeled transcript. Notes are copies; the meetings folder stays the source of truth.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
                TextField("Webhook URL", text: $settings.webhookURL, prompt: Text("https://example.com/hook"))
                    .textFieldStyle(.roundedBorder)
                    .font(Tokens.meta)
                Text("Finished meetings are also POSTed to this URL as JSON (title, notes, transcript). Leave empty to disable.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }

            Section("Processing") {
                Toggle("Pause transcription on battery", isOn: $settings.pausesOnBattery)
                    .onChange(of: settings.pausesOnBattery) {
                        queue?.setPausesOnBattery(settings.pausesOnBattery)
                    }
                Text("Transcription and note enhancement always run at low priority; on battery they wait until you're plugged in.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
                Toggle("Label speakers in transcripts", isOn: $settings.labelsSpeakers)
                Text("Tells apart who spoke, on-device. The first labeled transcript downloads a small model (~50 MB); if it isn't available yet, transcripts are simply unlabeled.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder inside your Obsidian vault"
        if panel.runModal() == .OK, let url = panel.url {
            settings.obsidianVaultPath = url.path
            stores?.exportAllReadyMeetingsToObsidian()
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveRootURL
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveRootPath = url.path
        }
    }

    private func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// There's no query API for the system-audio tap's permission — only the
    /// outcome of the last attempt, persisted by `AppStores.startRecording()`.
    private var systemAudioStatus: PermissionStatus {
        switch settings.lastSystemAudioTapFailed {
        case .some(true): .unavailable
        case .some(false): .granted
        case nil: .notDetermined
        }
    }

    private func refreshPermissionStatuses() {
        micStatus = AVAudioApplication.shared.recordPermission
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
    }
}

/// A permission's status as shown in the Permissions section. Distinct from
/// the raw system enums, since the system-audio tap has no query API and
/// needs a third "last attempt failed" state the others don't.
private enum PermissionStatus {
    case granted
    case denied
    case notDetermined
    /// System-audio only: the tap failed the last time a recording started.
    case unavailable

    var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not yet asked"
        case .unavailable: "Unavailable at last recording"
        }
    }

    var color: Color {
        switch self {
        case .granted: Tokens.successGreenText
        case .denied, .unavailable: Tokens.warningAmberText
        case .notDetermined: Tokens.textTertiary
        }
    }

    var systemImage: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied, .unavailable: "exclamationmark.triangle.fill"
        case .notDetermined: "circle.dashed"
        }
    }

    /// Whether the row's "Open System Settings" button is worth showing.
    var showsSettingsButton: Bool {
        switch self {
        case .denied, .unavailable: true
        case .granted, .notDetermined: false
        }
    }
}

private extension AVAudioApplication.recordPermission {
    var permissionStatus: PermissionStatus {
        switch self {
        case .granted: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }
}

private extension EKAuthorizationStatus {
    var permissionStatus: PermissionStatus {
        switch self {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// One row in the Permissions section: icon, title, live status, and a deep
/// link to the relevant System Settings pane when action is needed.
private struct PermissionRow: View {
    let icon: String
    let title: String
    let status: PermissionStatus
    let openSettings: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Label(status.label, systemImage: status.systemImage)
                    .font(Tokens.caption)
                    .foregroundStyle(status.color)
                if status.showsSettingsButton {
                    Button("Open System Settings") { openSettings() }
                        .controlSize(.small)
                }
            }
        } label: {
            Label(title, systemImage: icon)
        }
    }
}
