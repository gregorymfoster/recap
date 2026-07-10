import AppKit
import AVFoundation
import CoreAudio
import RecapAudio
import RecapCore
import RecapTranscription
import SwiftUI

/// Native Settings window (design handoff turn 11e): a single fixed-width
/// page — no tabs. Three grouped-form sections (Audio, Transcription,
/// Storage), a Launch at Login row, and one page-level footnote. Meant to
/// live inside a SwiftUI `Settings { }` scene, where the window title tracks
/// `.navigationTitle` automatically.
///
/// This view only supplies content — the call site (the app shell's
/// `Settings { }` scene) is responsible for injecting every environment
/// value it reads: `AppStores`, `SettingsStore`, `AppRouter`, and a
/// `LaunchAtLoginController`.
public struct SettingsWindowView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(SettingsStore.self) private var settings
    @Environment(LaunchAtLoginController.self) private var launchAtLogin

    static let width: CGFloat = 560
    static let footnoteText = "Recordings never leave this Mac. Battery, priority, and speaker labeling are handled automatically."

    public init() {}

    public var body: some View {
        @Bindable var settings = settings
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                Form {
                    audioSection
                        .id(AppRouter.SettingsSection.audio)
                    calendarSection(settings: $settings)
                        .id(AppRouter.SettingsSection.calendar)
                    transcriptionSection(settings: $settings)
                        .id(AppRouter.SettingsSection.transcription)
                    storageSection(settings: $settings)
                        .id(AppRouter.SettingsSection.storage)
                    launchAtLoginSection
                }
                .formStyle(.grouped)
                SettingsFootnote(Self.footnoteText)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `-open settings/<tab>` (`LaunchRouteApplier`) stages a section
            // on `router.pendingSettingsSection` and opens this window;
            // consuming it here (once, then clearing it) means a later
            // manual ⌘, doesn't keep reapplying a stale launch route.
            .task {
                if let pending = router.pendingSettingsSection {
                    withAnimation {
                        proxy.scrollTo(pending, anchor: .top)
                    }
                    router.pendingSettingsSection = nil
                }
            }
        }
        .axID(.settingsPage)
        // Fixed height too: the Settings scene's default window height clips
        // the last group and lets the footnote overlap the backup rows.
        .frame(width: Self.width, height: 640)
        .navigationTitle("Settings")
    }

    // MARK: - Audio

    @ViewBuilder private var audioSection: some View {
        Section {
            MicrophonePermissionAwareRow(settings: settings, stores: stores)
            Toggle("Capture other participants", isOn: Binding(
                get: { settings.includeSystemAudio },
                set: { settings.includeSystemAudio = $0 }
            ))
            .axID(.settingsSystemAudioToggle)
            SettingsFootnote("Records system audio from Zoom, Meet, Teams")
            LabeledContent("Start or stop from anywhere") {
                Text("⌥⌘R")
                    .font(Tokens.meta.monospacedDigit())
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusButton))
            }
        }
    }

    // MARK: - Calendar

    /// Auto-record picker for calendar-shaped meetings (the "Meeting
    /// started?" nudge, design mock 9b): off / ask-before-recording /
    /// record-automatically, backed by `SettingsStore.calendarAutoRecord`.
    /// This was previously a dead setting — `AutoRecordCoordinator` only
    /// ever applied it once at launch, so there was no UI and no live
    /// effect from a change — the picker's `set` now calls
    /// `stores?.applyCalendarAutoRecordSetting()` to restart the watcher
    /// immediately, matching how `disabledCallAppIDs` already reapplies.
    @ViewBuilder
    private func calendarSection(settings: Bindable<SettingsStore>) -> some View {
        Section {
            Picker("Auto-record from Calendar", selection: Binding(
                get: { settings.wrappedValue.calendarAutoRecord },
                set: { newValue in
                    settings.wrappedValue.calendarAutoRecord = newValue
                    stores?.applyCalendarAutoRecordSetting()
                }
            )) {
                ForEach(CalendarAutoRecordMode.allCases, id: \.self) { mode in
                    Text(SettingsCalendarCopy.modeLabel(mode)).tag(mode)
                }
            }
            .axID(.settingsCalendarModePicker)
            SettingsFootnote(SettingsCalendarCopy.modeFootnote(settings.wrappedValue.calendarAutoRecord))

            if settings.wrappedValue.calendarAutoRecord != .off, stores?.calendarAccessDenied == true {
                CalendarAccessDeniedRow()
            }
        }
    }

    // MARK: - Transcription

    @ViewBuilder
    private func transcriptionSection(settings: Bindable<SettingsStore>) -> some View {
        Section {
            switch stores?.setup.phase ?? .done {
            case .downloading(let progress):
                downloadingRow(progress: progress)
            case .failed:
                failedRow
            case .done:
                Picker("Transcription quality", selection: Binding(
                    get: { settings.wrappedValue.transcriptionQuality },
                    set: { stores?.setup.setQuality($0) }
                )) {
                    Text("Best quality").tag(TranscriptionQuality.bestQuality)
                    Text("Faster").tag(TranscriptionQuality.faster)
                }
                .axID(.settingsQualityPicker)
                SettingsFootnote("Runs entirely on this Mac")
            }
        }
    }

    private func downloadingRow(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Transcription quality") {
                Text("Downloading · \(Int(progress * 100))%")
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textSecondary)
            }
            ProgressView(value: progress)
                .controlSize(.small)
        }
        .axID(.settingsDownloadingRow)
    }

    private var failedRow: some View {
        LabeledContent("Transcription quality") {
            HStack(spacing: 10) {
                Text("Couldn't download model")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.warningAmberText)
                Button("Retry") { stores?.setup.retry() }
                    .controlSize(.small)
            }
        }
        .axID(.settingsDownloadingRow)
    }

    // MARK: - Storage

    @ViewBuilder
    private func storageSection(settings: Bindable<SettingsStore>) -> some View {
        Section {
            LabeledContent("Meetings folder") {
                HStack(spacing: 10) {
                    Text(tildePath(settings.wrappedValue.saveRootPath))
                        .font(Tokens.meta)
                        .foregroundStyle(Tokens.textSecondary)
                    Button("Change…") { pickMeetingsFolder(settings: settings.wrappedValue) }
                        .axID(.settingsMeetingsFolderChangeButton)
                        .controlSize(.small)
                }
            }
            SettingsFootnote("Plain files — Markdown and m4a")

            Toggle("Back up automatically", isOn: Binding(
                get: { settings.wrappedValue.mirrorBackupEnabled },
                set: { newValue in
                    guard newValue else {
                        settings.wrappedValue.mirrorBackupEnabled = false
                        return
                    }
                    guard settings.wrappedValue.mirrorFolderPath.isEmpty else {
                        // A folder is already configured — nothing to pick,
                        // just (re-)enable and backfill.
                        settings.wrappedValue.mirrorBackupEnabled = true
                        stores?.backfillMirrorBackup()
                        return
                    }
                    // Don't flip the toggle on until a folder is actually
                    // chosen — cancelling the picker must leave the setting
                    // untouched, not stuck "on" with no folder (and a
                    // misleadingly OK-looking status). `pickMirrorFolder`
                    // already runs `backfillMirrorBackup()` on success, so
                    // there's no second call here.
                    if pickMirrorFolder(settings: settings.wrappedValue) {
                        settings.wrappedValue.mirrorBackupEnabled = true
                    }
                }
            ))
            .axID(.settingsBackupToggle)
            SettingsFootnote("Copies finished meetings to iCloud Drive")

            if settings.wrappedValue.mirrorBackupEnabled {
                backupStatusRow(settings: settings.wrappedValue)
            }
        }
    }

    @ViewBuilder
    private func backupStatusRow(settings: SettingsStore) -> some View {
        switch stores?.backup.state ?? .disabled {
        case .disabled:
            EmptyView()
        case .stuck(let reason, let since):
            HStack(spacing: 10) {
                Label(SettingsBackupCopy.stuckMessage(reason: reason, since: since), systemImage: "exclamationmark.triangle.fill")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.warningAmberText)
                Spacer()
                Button("Choose folder…") { pickMirrorFolder(settings: settings) }
                    .controlSize(.small)
            }
            .axID(.settingsBackupStatusRow)
        case .working(let completed, let total):
            Label("Backing up · \(completed)/\(total)", systemImage: "arrow.triangle.2.circlepath")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.textSecondary)
                .axID(.settingsBackupStatusRow)
        case .ok(let lastBackupAt):
            let figures = stores?.backup.figures
            Label(
                SettingsBackupCopy.statusLine(
                    lastBackupAt: lastBackupAt,
                    meetingCount: figures?.meetingCount ?? 0,
                    totalBytes: figures?.totalBytes ?? 0
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(Tokens.caption)
            .foregroundStyle(Tokens.successGreenText)
            .axID(.settingsBackupStatusRow)
        }
    }

    // MARK: - Launch at Login

    @ViewBuilder private var launchAtLoginSection: some View {
        Section {
            Toggle(
                "Launch Recap at login",
                isOn: Binding(
                    get: { launchAtLogin.status.isOn },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            .axID(.settingsLaunchAtLoginToggle)
            if let footnote = launchAtLogin.status.footnote {
                SettingsFootnote(footnote)
            } else if let error = launchAtLogin.lastErrorMessage {
                SettingsFootnote(error)
            }
        }
        .onAppear { launchAtLogin.refresh() }
    }

    // MARK: - Folder pickers (shared Storage-group logic)

    private func pickMeetingsFolder(settings: SettingsStore) {
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

    /// Returns whether a folder was actually chosen — `false` on cancel, so
    /// the toggle above can stay off rather than committing to "on" with no
    /// folder configured.
    @discardableResult
    private func pickMirrorFolder(settings: SettingsStore) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a backup destination folder"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        settings.mirrorFolderPath = url.path
        stores?.backfillMirrorBackup()
        return true
    }

    private func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The Microphone row: an `InputDeviceMenu` with a live-input `LevelMeter`
/// underneath when the app has mic permission, or an inline "No access" +
/// "Open System Settings…" fix-it when it doesn't (design handoff #11e —
/// fixed in place, no alert). There is no standalone microphone-preview tap
/// in `RecapAudio` today — level metering only exists while a real
/// `MeetingRecorder` session is active — so outside a recording this shows
/// the same `LevelMeter` component with idle (silent) bars rather than
/// standing up new capture just for this row.
private struct MicrophonePermissionAwareRow: View {
    let settings: SettingsStore
    let stores: AppStores?

    @State private var micStatus = AVAudioApplication.shared.recordPermission
    @State private var inputDevices: [AudioInputDevice] = AudioInputDevices.inputDevices()
    @State private var deviceListListener: AudioObjectPropertyListenerBlock?

    private static let idleLevels = [Float](repeating: 0, count: 16)

    /// Reuses `PermissionsModel`'s shared status→action mapping (the same
    /// one Onboarding drives) rather than re-deriving a denied check here —
    /// `.openSystemSettings` is only returned for `.denied`, so this is
    /// equivalent to the old `PrivacyRow`'s microphone-denied branch.
    private var permissionAction: PermissionAction {
        micStatus.permissionStatus.action(for: .microphone)
    }

    var body: some View {
        Group {
            if permissionAction == .openSystemSettings {
                LabeledContent("Microphone") {
                    HStack(spacing: 10) {
                        Label("No access", systemImage: "xmark.circle.fill")
                            .font(Tokens.caption)
                            .foregroundStyle(Tokens.recordRed)
                        Button("Open System Settings…") { PrivacyPane.open(PrivacyPane.microphone) }
                            .axID(.settingsMicrophonePermissionButton)
                            .controlSize(.small)
                    }
                }
            } else {
                LabeledContent("Microphone") {
                    VStack(alignment: .trailing, spacing: 4) {
                        InputDeviceMenu(
                            devices: inputDevices,
                            selectedUID: settings.preferredInputUID,
                            onSelect: { uid in
                                settings.preferredInputUID = uid
                                stores?.session.setPreferredInputUID(uid)
                            },
                            axID: .settingsInputDevicePicker
                        )
                        LevelMeter(levels: liveLevels)
                    }
                }
            }
        }
        .onAppear {
            refreshMicStatus()
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMicStatus()
        }
    }

    /// The recording session's live levels while a meeting is actively
    /// recording, otherwise a flat idle bar — see the type doc above.
    private var liveLevels: [Float] {
        guard let session = stores?.session, session.isRecording else { return Self.idleLevels }
        return session.levels
    }

    private func refreshMicStatus() {
        micStatus = AVAudioApplication.shared.recordPermission
    }
}

/// Inline warning row shown under the Calendar picker when auto-record is on
/// but macOS calendar access was denied (`AppStores.calendarAccessDenied`,
/// surfaced via `AutoRecordCoordinator`) — otherwise the denial was
/// completely silent (bug: calendar auto-record had no UI at all). Mirrors
/// `MicrophonePermissionAwareRow`'s fix-it shape: a deep link to System
/// Settings, refreshed on `didBecomeActive` by re-applying the setting (which
/// re-derives `calendarAccessDenied` from a fresh `CalendarWatcher.start()`).
private struct CalendarAccessDeniedRow: View {
    @Environment(AppStores.self) private var stores: AppStores?

    var body: some View {
        HStack(spacing: 10) {
            Label("No access to Calendar", systemImage: "xmark.circle.fill")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.recordRed)
            Spacer()
            Button("Open System Settings…") { PrivacyPane.open(PrivacyPane.calendars) }
                .axID(.settingsCalendarPermissionButton)
                .controlSize(.small)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            stores?.applyCalendarAutoRecordSetting()
        }
    }
}

/// Thin, single-purpose wrapper so a group Section has exactly one footnote
/// (design handoff #7c: "One footnote per group ... not per row"). Every
/// group in this file builds with this helper instead of scattering
/// `Text(...).font(Tokens.caption)` calls after individual controls.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Tokens.caption)
            .foregroundStyle(Tokens.textTertiary)
    }
}
