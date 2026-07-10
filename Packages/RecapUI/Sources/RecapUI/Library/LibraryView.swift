import AppKit
import RecapCore
import RecapTranscription
import SwiftUI
import UniformTypeIdentifiers

/// The Library home screen (design mock 10a/11c): unified window toolbar
/// with title/search/Record, an optional "next meeting soon" banner,
/// date-grouped rows in inset containers, a quiet status system, a pinned
/// footer, and a row context menu (open/copy/reveal/rename/re-transcribe/
/// trash).
struct LibraryView: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(LibraryStore.self) private var library
    @Environment(MeetingSessionStore.self) private var session
    @Environment(WhisperModelManager.self) private var models
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueStore.self) private var queue: QueueStore?
    @Environment(AppRouter.self) private var router

    /// Owned by `RootView`; the toolbar's search field opens the same ⌘K
    /// overlay the global shortcut does.
    @Binding var showSearch: Bool

    @State private var dropTargeted = false
    @State private var renameTarget: MeetingRecord?
    /// Drives the next-meeting banner's countdown/visibility without a
    /// `.timer` Text or periodic `TimelineView` (both peg the CPU inside
    /// long-lived SwiftUI hierarchies — see `MenuBarLabel`). A plain 30s
    /// sleep loop, cancelled on disappear, calls `refresh()` directly instead.
    @State private var upcomingRefreshTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let imminentEvent {
                    NextMeetingBanner(event: imminentEvent, now: .now) {
                        stores?.startRecording(title: imminentEvent.title, attendees: imminentEvent.otherAttendees)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }
                if library.meetings.isEmpty {
                    emptyState
                        .padding(.horizontal, 24)
                        .padding(.top, imminentEvent == nil ? 16 : 18)
                } else {
                    content
                        .padding(.horizontal, 24)
                        .padding(.top, imminentEvent == nil ? 16 : 18)
                }
                Color.clear.frame(height: 16)
            }
        }
        .background(Tokens.surface)
        .axID(.libraryList)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropHighlight } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryFooter(
                meetingCount: library.meetings.count,
                backupState: stores?.backup.state ?? .disabled,
                onFixBackup: {
                    router.pendingSettingsSection = .storage
                    SettingsOpener.open()
                }
            )
        }
        .navigationTitle("Library")
        .toolbar { toolbarContent }
        .renameSheet(target: $renameTarget) { record, newTitle in
            library.rename(record, to: newTitle)
        }
        .onAppear {
            stores?.upcoming.refresh()
            startUpcomingRefreshLoop()
        }
        .onDisappear {
            upcomingRefreshTask?.cancel()
            upcomingRefreshTask = nil
        }
    }

    /// Re-queries the calendar every 30s while the Library is visible, so the
    /// banner's countdown and imminence window stay fresh without a
    /// per-frame timer.
    private func startUpcomingRefreshLoop() {
        guard upcomingRefreshTask == nil else { return }
        upcomingRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                stores?.upcoming.refresh()
            }
        }
    }

    /// The next calendar event starting within 30 minutes, if calendar
    /// access is authorized — drives `NextMeetingBanner` (design mock
    /// 10a/11c). Never an empty section: `nil` hides the banner entirely
    /// rather than rendering something with nothing to show.
    private var imminentEvent: CalendarEventSnapshot? {
        stores?.upcoming.imminentEvent()
    }

    // MARK: Toolbar (design global #3 — unified toolbar, not an in-content header)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // One group, not two ToolbarItems: separate `.primaryAction` items
        // can get collapsed into toolbar overflow, which drops the search
        // field entirely (found via ui-smoke — search-field missing from AX).
        ToolbarItemGroup(placement: .primaryAction) {
            searchField
            if session.isRecording {
                recordingIndicatorButton
            } else {
                recordButton
            }
        }
    }

    /// Styled like a compact search field, but it's a button — clicking (or
    /// ⌘K) opens the existing full-screen search overlay rather than typing
    /// inline.
    private var searchField: some View {
        Button {
            showSearch = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
                Text("Search")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                // No Spacer here: an infinitely-flexible Spacer inside a
                // toolbar button label collapses the whole item out of the
                // toolbar on macOS 26 — pin the ⌘K hint with a frame instead.
                Text("⌘K")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Tokens.textPrimary.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(width: 180, height: 28)
            // stays: fixed white tint per the design handoff — reads as a
            // subtle field fill against both the light and dark toolbar.
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Tokens.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Search titles, notes, and transcripts")
        .axID(.searchField)
    }

    private var recordButton: some View {
        Button {
            stores?.startRecording()
        } label: {
            HStack(spacing: 7) {
                // stays: white dot/text on the red Record button in both modes
                Circle().fill(.white).frame(width: 7, height: 7)
                Text("Record")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            // stays: white text on the red Record button in both modes
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Tokens.recordRed, in: Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .axID(.libraryRecordButton)
    }

    /// Swapped in for `recordButton` while a recording is in progress
    /// (design note: recording now lives on its own full-window screen —
    /// `router.screen == .recording` — so navigating back to the Library
    /// while it's running needs a quiet way back in). Tapping it returns to
    /// the recording screen; the docked `RecordingPill` overlay stays the
    /// actual pause/stop control everywhere, including here.
    private var recordingIndicatorButton: some View {
        Button {
            router.screen = .recording
        } label: {
            HStack(spacing: 7) {
                Circle().fill(Tokens.recordRed).frame(width: 7, height: 7)
                Text(session.menuBarElapsedLabel.map { "Recording · \($0)" } ?? "Recording")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Tokens.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Tokens.chipBackground, in: Capsule())
            .overlay(Capsule().stroke(Tokens.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .axID(.libraryRecordingIndicatorButton)
    }

    // MARK: Drag & drop import

    /// Files dragged from Finder: audio-conforming ones import; anything
    /// else gets a toast instead of silently vanishing.
    private func handleDrop(_ urls: [URL]) -> Bool {
        let audio = urls.filter {
            UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true
        }
        for url in urls where !audio.contains(url) {
            stores?.toasts.show("Couldn't import \(url.lastPathComponent) — not an audio file")
        }
        guard !audio.isEmpty else { return false }
        stores?.importAudioFiles(audio)
        return true
    }

    private var dropHighlight: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .fill(Tokens.accentBlue.opacity(0.06))
                .stroke(Tokens.accentBlue, lineWidth: 2)
            Label("Drop audio to import", systemImage: "square.and.arrow.down")
                .font(Tokens.rowTitle)
                .foregroundStyle(Tokens.accentBlue)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Tokens.surface, in: Capsule())
                // stays: shadow stays black in both modes (drop shadows read fine on dark surfaces)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    // MARK: List content

    /// Grouped-with-headers date sections (Today, Yesterday, ...) —
    /// `MeetingGrouping` sorts any `.recovered` meeting to the top of Today.
    private var content: some View {
        let sections = MeetingGrouping.sections(library.displayMeetings, now: .now, calendar: .current)
        return LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
            ForEach(sections, id: \.id) { section in
                VStack(alignment: .leading, spacing: 7) {
                    sectionHeader(section.title)
                    groupCard(for: section.records)
                }
            }
        }
    }

    /// One rounded, hairline-bordered container per date group (design mock
    /// 10a/11c): subtle fill, radius 10, row separators inset past the
    /// title (no more icon tile to clear).
    private func groupCard(for records: [MeetingRecord]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                if index > 0 {
                    Divider()
                        .overlay(Tokens.hairline)
                        .padding(.leading, 14)
                }
                row(for: record)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Tokens.subtleBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Tokens.cardStroke, lineWidth: 1)
        )
    }

    private func row(for record: MeetingRecord) -> some View {
        // The manual Models screen is gone — model install/selection is now
        // fully automatic (`TranscriptionSetupStore`, driven by the
        // transcription-quality preference). Tapping "Retry" just re-kicks
        // setup rather than navigating anywhere.
        MeetingRow(
            record: record,
            setupPhase: stores?.setup.phase,
            onInstallModel: { stores?.setup.retry() },
            onTranscribeRecovered: { queue?.transcribeRecovered(record, in: library) }
        )
        .contentShape(Rectangle())
        .onTapGesture { openMeeting(record) }
        .contextMenu {
            rowContextMenu(for: record)
        }
        .axID(.meetingRow(record.meeting.id.uuidString))
    }

    /// Routes to the meeting's screen: the `.recording` placeholder when it's
    /// the live recording, otherwise its `.detail` screen. `selectedMeetingID`
    /// is kept in sync because `TranscriptPane` (pinned API) still reads it
    /// for per-meeting transcription progress.
    private func openMeeting(_ record: MeetingRecord) {
        library.selectedMeetingID = record.meeting.id
        if session.activeRecord?.meeting.id == record.meeting.id {
            router.screen = .recording
        } else {
            router.screen = .detail(meetingID: record.meeting.id)
        }
    }

    @ViewBuilder
    private func rowContextMenu(for record: MeetingRecord) -> some View {
        Button("Open") {
            openMeeting(record)
        }
        .axID(.libraryRowOpen)
        Button("Copy notes as Markdown") {
            copyNotes(for: record)
        }
        .axID(.libraryRowCopyNotes)
        Button("Reveal in Finder") {
            revealInFinder(record)
        }
        .disabled(!isOnDisk(record))
        .axID(.libraryRowReveal)
        Divider()
        Button("Rename…") {
            renameTarget = record
        }
        .axID(.libraryRowRename)
        Button("Re-transcribe") {
            queue?.retranscribe(record, in: library)
        }
        .axID(.libraryRowRetranscribe)
        Divider()
        Button("Move to Trash", role: .destructive) {
            stores?.moveToTrash(record)
        }
        .disabled(!isOnDisk(record) || isActivelyRecording(record))
        .axID(.libraryRowTrash)
    }

    /// Fixture records live at `/dev/null` — Reveal/Trash have nothing real
    /// to act on, so those items are disabled rather than silently failing.
    private func isOnDisk(_ record: MeetingRecord) -> Bool {
        record.folderURL.path != "/dev/null"
    }

    private func isActivelyRecording(_ record: MeetingRecord) -> Bool {
        session.activeRecord?.meeting.id == record.meeting.id
    }

    /// Mirrors the detail view's copy behavior: enhanced notes when present,
    /// otherwise the raw notes.
    private func copyNotes(for record: MeetingRecord) {
        let enhanced = library.loadEnhancedNotes(for: record)
        let notes = enhanced ?? library.loadNotes(for: record)
        guard !notes.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(notes, forType: .string)
    }

    private func revealInFinder(_ record: MeetingRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.folderURL])
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Tokens.textTertiary)
            .padding(.horizontal, 4)
    }

    /// No illustration, no button (design mock 10a/11c) — the toolbar's
    /// Record button is already the call to action.
    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No meetings yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text("Click Record, or press ⌥⌘R from any app.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textPrimary.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

/// A single Library row (design mock 10a/11c): title + trailing content that
/// is EITHER a processing status OR — once `.ready` — a quiet
/// start-time · duration line with a hover chevron. Never both.
/// `.recovered` gets its own two-line layout with a ghost "Transcribe"
/// action instead of a trailing status.
private struct MeetingRow: View {
    var record: MeetingRecord
    var setupPhase: TranscriptionSetupStore.SetupPhase?
    var onInstallModel: () -> Void
    var onTranscribeRecovered: () -> Void
    @Environment(QueueStore.self) private var queue: QueueStore?
    @Environment(LibraryStore.self) private var library
    @State private var hovering = false

    var body: some View {
        Group {
            if record.meeting.status == .recovered {
                recoveredRow
            } else {
                standardRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(hovering ? Tokens.chipBackground.opacity(0.6) : Color.clear)
        .onHover { hovering = $0 }
    }

    private var standardRow: some View {
        HStack(spacing: 11) {
            Text(record.meeting.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            trailing
        }
    }

    /// Audio was salvaged from a crash spool: still the meeting's real
    /// title, plus a reassuring sub-line and a one-tap way to kick off
    /// transcription (`queue.transcribeRecovered`).
    private var recoveredRow: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("Recap quit unexpectedly — audio is safe")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer(minLength: 12)
            Button("Transcribe", action: onTranscribeRecovered)
                .buttonStyle(.quietBlueOutline)
        }
    }

    /// Ready rows are silent (design global #4) except for the start ·
    /// duration line and a hover chevron — no chip, no color. Every other
    /// status keeps its own indicator so hovering doesn't hide information
    /// the user needs (progress, retry).
    @ViewBuilder private var trailing: some View {
        if !record.meeting.processingIssues.isEmpty {
            Text("Needs attention")
                .font(Tokens.caption.weight(.semibold))
                .foregroundStyle(Tokens.warningAmberText)
                .help("Open this meeting for recovery actions.")
        } else if record.meeting.status == .ready {
            readyTrailing
        } else {
            MeetingStatusView(
                status: record.meeting.status,
                setupPhase: setupPhase,
                onInstallModel: onInstallModel,
                onRetry: { queue?.retranscribe(record, in: library) }
            )
        }
    }

    /// "9:29 AM · 15m" — start time · duration, tabular figures at reduced
    /// opacity, plus a chevron shown only on hover.
    @ViewBuilder private var readyTrailing: some View {
        HStack(spacing: 6) {
            Text(readySummary)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(Tokens.textPrimary.opacity(0.45))
            if hovering {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
    }

    private var readySummary: String {
        let time = record.meeting.date.formatted(.dateTime.hour().minute())
        guard record.meeting.duration > 0 else { return time }
        let duration = Duration.seconds(record.meeting.duration)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return "\(time) · \(duration)"
    }
}

/// "Rename Speaker"-style alert-driven rename for a meeting title. A plain
/// `.alert` with a text field is the smallest correct native surface for a
/// single-field rename — no bespoke popover to hand-roll.
private struct RenameSheetModifier: ViewModifier {
    @Binding var target: MeetingRecord?
    var onRename: (MeetingRecord, String) -> Void
    @State private var title = ""

    func body(content: Content) -> some View {
        content.alert(
            "Rename Meeting",
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            presenting: target
        ) { record in
            TextField("Title", text: $title)
                .axID(.libraryRenameField)
            Button("Cancel", role: .cancel) { target = nil }
            Button("Rename") {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { onRename(record, trimmed) }
                target = nil
            }
            .axID(.libraryRenameConfirm)
        } message: { record in
            Text("Choose a new title for \"\(record.meeting.title)\".")
        }
        .onChange(of: target) { _, newValue in
            title = newValue?.meeting.title ?? ""
        }
    }
}

extension View {
    fileprivate func renameSheet(
        target: Binding<MeetingRecord?>, onRename: @escaping (MeetingRecord, String) -> Void
    ) -> some View {
        modifier(RenameSheetModifier(target: target, onRename: onRename))
    }
}

#Preview {
    LibraryView(showSearch: .constant(false))
        .environment(LibraryStore.fixture())
        .environment(AppRouter())
        .frame(width: 820, height: 620)
}

#Preview("Dark") {
    LibraryView(showSearch: .constant(false))
        .environment(LibraryStore.fixture())
        .environment(AppRouter())
        .frame(width: 820, height: 620)
        .preferredColorScheme(.dark)
}
