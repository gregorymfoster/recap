import AppKit
import AVFoundation
import EventKit
import RecapAudio
import RecapCore
import SwiftUI

/// Privacy tab: permission rows (icon + name + status + at most one action,
/// re-checked whenever this window comes forward) and storage rows (meetings
/// folder + library size with a drill-in to the largest meetings).
struct SettingsPrivacyTab: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(SettingsStore.self) private var settings
    @State private var micStatus = AVAudioApplication.shared.recordPermission
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var calendarRequestStore: EKEventStore?
    @State private var sizeSummary: LibrarySizeSummary?

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    status: micStatus.permissionStatus,
                    kind: .microphone,
                    actionAXID: .settingsMicrophonePermissionButton
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
                    kind: .systemAudio,
                    actionAXID: .settingsSystemAudioPermissionButton
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
                        // This is the actionable system-audio permission
                        // control (macOS exposes no query API); keep the
                        // stable permission ID on the actual button rather
                        // than a wrapper so AX automation can invoke it.
                        .axID(.settingsSystemAudioPermissionButton)
                    }
                }
                PermissionRow(
                    icon: "calendar",
                    title: "Calendar",
                    status: calendarStatus.permissionStatus,
                    kind: .calendar,
                    actionAXID: .settingsCalendarPermissionButton
                ) {
                    switch $0 {
                    case .allow:
                        let store = EKEventStore()
                        calendarRequestStore = store
                        Task {
                            _ = try? await store.requestFullAccessToEvents()
                            calendarRequestStore = nil
                            refreshPermissionStatuses()
                            // Granting here never otherwise reaches the
                            // Library's Upcoming agenda — without this the
                            // agenda stays stuck on "Connect your calendar"
                            // until the next 30s poll or app foreground.
                            stores?.upcoming.refresh()
                        }
                    case .openSystemSettings:
                        PrivacyPane.open(PrivacyPane.calendars)
                    case .test, .none:
                        break
                    }
                }
                SettingsFootnote("Recap re-checks these whenever this window comes forward, so a change in System Settings shows up here right away.")
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshPermissionStatuses()
            }

            Section {
                storageSectionContent
            }
            .task(priority: .utility) {
                await refreshSizeSummary()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
    }

    @ViewBuilder private var storageSectionContent: some View {
        LabeledContent("Meetings folder") {
            HStack(spacing: 10) {
                Text(tildePath(settings.saveRootPath))
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textSecondary)
                Button("Change…") { pickFolder() }
                    .axID(.settingsMeetingsFolderChangeButton)
                    .controlSize(.small)
            }
        }
        LabeledContent("Library size") {
            if let sizeSummary {
                Text(librarySizeLabel(sizeSummary))
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
        SettingsFootnote("Notes and audio are plain files — Markdown, JSON, and m4a — readable by any app. A new folder takes effect the next time Recap opens.")
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

    /// "1.2 GB · 6 meetings" (design global #6 — never dev copy like
    /// "Zero kB"). An empty or size-less library reads as plain prose.
    private func librarySizeLabel(_ summary: LibrarySizeSummary) -> String {
        let count = stores?.library.meetings.count ?? 0
        let meetings = "\(count) meeting\(count == 1 ? "" : "s")"
        guard summary.totalBytes > 0 else {
            return count == 0 ? "Empty" : meetings
        }
        let size = summary.totalBytes.formatted(.byteCount(style: .file))
        return "\(size) · \(meetings)"
    }

    private func refreshSizeSummary() async {
        guard let records = stores?.library.meetings else { return }
        let storage = LibraryStorage(rootURL: settings.saveRootURL)
        let summary = await Task.detached(priority: .utility) {
            try? storage.sizeSummary(for: records)
        }.value
        sizeSummary = summary
    }

    private func openMeeting(_ id: UUID) {
        guard let stores else { return }
        stores.router.section = .library
        stores.library.selectedMeetingID = id
    }

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
    let actionAXID: AXID
    let onAction: (PermissionAction) -> Void
    @ViewBuilder var trailingContent: () -> TrailingContent

    init(
        icon: String,
        title: String,
        status: PermissionStatus,
        kind: PermissionKind,
        actionAXID: AXID,
        onAction: @escaping (PermissionAction) -> Void,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.status = status
        self.kind = kind
        self.actionAXID = actionAXID
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
                        Button("Request…") { onAction(.allow) }
                            .axID(actionAXID)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(Tokens.accentBlue)
                    case .openSystemSettings:
                        Button("Open System Settings…") { onAction(.openSystemSettings) }
                            .axID(actionAXID)
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
