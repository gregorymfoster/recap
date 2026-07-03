import AppKit
import AVFoundation
import CoreAudio
import EventKit
import RecapAudio
import RecapCore
import SwiftUI

/// The Settings section: permissions, save location, recording sources, processing.
struct SettingsView: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueStore.self) private var queue: QueueStore?
    @State private var micStatus = AVAudioApplication.shared.recordPermission
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var calendarRequestStore: EKEventStore?
    @State private var inputDevices: [AudioInputDevice] = AudioInputDevices.inputDevices()
    @State private var deviceListListener: AudioObjectPropertyListenerBlock?
    @State private var sizeSummary: LibrarySizeSummary?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Permissions") {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    status: micStatus.permissionStatus,
                    kind: .microphone
                ) {
                    switch $0 {
                    case .allow:
                        Task {
                            _ = await MeetingRecorder.requestMicPermission()
                            refreshPermissionStatuses()
                        }
                    case .openSystemSettings:
                        PrivacyPane.open(PrivacyPane.microphone)
                    case .test, .none:
                        break
                    }
                }
                PermissionRow(
                    icon: "speaker.wave.2.fill",
                    title: "System Audio",
                    status: systemAudioStatus,
                    kind: .systemAudio
                ) {
                    if $0 == .openSystemSettings {
                        PrivacyPane.open(PrivacyPane.systemAudio)
                    }
                } trailingContent: {
                    if systemAudioStatus.showsSystemAudioProbe {
                        SystemAudioProbeButton(label: systemAudioStatus.systemAudioProbeLabel) { result in
                            switch result {
                            case .captured:
                                settings.lastSystemAudioTapFailed = false
                            case .denied, .failed:
                                settings.lastSystemAudioTapFailed = true
                            }
                        }
                    }
                }
                PermissionRow(
                    icon: "calendar",
                    title: "Calendar",
                    status: calendarStatus.permissionStatus,
                    kind: .calendar
                ) {
                    switch $0 {
                    case .allow:
                        let store = EKEventStore()
                        calendarRequestStore = store
                        Task {
                            _ = try? await store.requestFullAccessToEvents()
                            calendarRequestStore = nil
                            refreshPermissionStatuses()
                        }
                    case .openSystemSettings:
                        PrivacyPane.open(PrivacyPane.calendars)
                    case .test, .none:
                        break
                    }
                }
                Text("Recap re-checks these whenever this window comes forward, so a change in System Settings shows up here right away.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshPermissionStatuses()
            }

            Section("Storage") {
                storageSectionContent
            }
            .task(priority: .utility) {
                await refreshSizeSummary()
            }

            Section("Recording") {
                Picker("Input device", selection: $settings.preferredInputUID) {
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

            Section("Sync & Backup") {
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

                Toggle("Back up meeting folders to another location", isOn: $settings.mirrorBackupEnabled)
                    .onChange(of: settings.mirrorBackupEnabled) {
                        if settings.mirrorBackupEnabled {
                            if settings.mirrorFolderPath.isEmpty { pickMirrorFolder() }
                            stores?.backfillMirrorBackup()
                        }
                    }
                if settings.mirrorBackupEnabled {
                    LabeledContent("Backup folder") {
                        HStack(spacing: 10) {
                            Text(settings.mirrorFolderPath.isEmpty
                                ? "None selected"
                                : tildePath(settings.mirrorFolderPath))
                                .font(Tokens.meta)
                                .foregroundStyle(Tokens.textSecondary)
                            Button("Change…") { pickMirrorFolder() }
                                .controlSize(.small)
                        }
                    }
                }
                Text("A complete, one-way copy of each meeting folder — including audio — is kept in sync here. Picking a folder inside iCloud Drive keeps an extra copy in iCloud automatically.")
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
                Picker("Transcription language", selection: $settings.transcriptionLanguage) {
                    Text("Auto-detect").tag(String?.none)
                    ForEach(TranscriptionLanguages.common) { language in
                        Text(language.displayName).tag(String?.some(language.code))
                    }
                }
                Text("Auto-detect works well for most meetings. Forcing a language helps short or heavily accented recordings.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .formStyle(.grouped)
    }

    /// Split out of the "Storage" `Section` body — folded into the giant
    /// `Form` inline, this combination of `LabeledContent`/`DisclosureGroup`/
    /// `ForEach` blew past the type checker's time budget ("failed to
    /// produce diagnostic for expression").
    @ViewBuilder private var storageSectionContent: some View {
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

        LabeledContent("Library size") {
            if let sizeSummary {
                Text(sizeSummary.totalBytes, format: .byteCount(style: .file))
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textSecondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        if let sizeSummary, !sizeSummary.largest.isEmpty {
            DisclosureGroup("Largest meetings") {
                ForEach(sizeSummary.largest) { entry in
                    LargestMeetingRow(entry: entry) { openMeeting(entry.id) }
                }
            }
        }
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

    private func pickMirrorFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a backup destination folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.mirrorFolderPath = url.path
            stores?.backfillMirrorBackup()
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

    /// Computes the on-disk footprint of the library off the main actor, so
    /// opening Settings never blocks on a folder walk. `LibraryStorage` and
    /// `MeetingRecord` are both `Sendable`, so the detached task can capture
    /// them directly.
    private func refreshSizeSummary() async {
        guard let records = stores?.library.meetings else { return }
        let storage = LibraryStorage(rootURL: settings.saveRootURL)
        let summary = await Task.detached(priority: .utility) {
            try? storage.sizeSummary(for: records)
        }.value
        sizeSummary = summary
    }

    /// Jumps to a meeting from the "Largest meetings" list — same navigation
    /// as the menu bar extra's recent-meetings items and the search overlay.
    private func openMeeting(_ id: UUID) {
        guard let stores else { return }
        stores.router.section = .library
        stores.library.selectedMeetingID = id
    }

    /// There's no query API for the system-audio tap's permission — only the
    /// outcome of the last attempt, persisted by `AppStores.startRecording()`
    /// or the Settings "Test" button.
    private var systemAudioStatus: PermissionStatus {
        .systemAudio(lastTapFailed: settings.lastSystemAudioTapFailed)
    }

    private func refreshPermissionStatuses() {
        micStatus = AVAudioApplication.shared.recordPermission
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
    }
}

/// One row in the Permissions section: icon, title, live status, a primary
/// action button driven by `PermissionAction`, and a fix-it hint when the
/// user needs to go to System Settings. `onAction` handles `.allow` and
/// `.openSystemSettings`; `.test` is rendered by the caller via
/// `trailingContent` since it needs its own local spinner state
/// (`SystemAudioProbeButton`), not just a fire-and-forget closure.
private struct PermissionRow<TrailingContent: View>: View {
    let icon: String
    let title: String
    let status: PermissionStatus
    let kind: PermissionKind
    let onAction: (PermissionAction) -> Void
    @ViewBuilder var trailingContent: () -> TrailingContent

    init(
        icon: String,
        title: String,
        status: PermissionStatus,
        kind: PermissionKind,
        onAction: @escaping (PermissionAction) -> Void,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.status = status
        self.kind = kind
        self.onAction = onAction
        self.trailingContent = trailingContent
    }

    private var action: PermissionAction { status.action(for: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 10) {
                    Label(status.label, systemImage: status.systemImage)
                        .font(Tokens.caption)
                        .foregroundStyle(status.color)
                    switch action {
                    case .allow:
                        Button("Allow") { onAction(.allow) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(Tokens.accentBlue)
                    case .openSystemSettings:
                        Button("Open System Settings") { onAction(.openSystemSettings) }
                            .controlSize(.small)
                        trailingContent()
                    case .test, .none:
                        trailingContent()
                    }
                }
            } label: {
                Label(title, systemImage: icon)
            }
            if let hint = status.fixItHint(for: kind) {
                Text(hint)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
    }
}

/// One row in the "Largest meetings" disclosure group: title, size, and a
/// tap that navigates to the meeting (same pattern as the search overlay
/// and menu bar extra's recent-meetings items).
private struct LargestMeetingRow: View {
    let entry: LibrarySizeSummary.Entry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(entry.title)
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text(entry.bytes, format: .byteCount(style: .file))
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
