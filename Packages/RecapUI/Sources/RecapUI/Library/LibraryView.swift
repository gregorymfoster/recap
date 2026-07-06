import AppKit
import RecapCore
import RecapTranscription
import SwiftUI
import UniformTypeIdentifiers

/// The Library home screen (design mock 6a): unified window toolbar with
/// title/search/filter/Record, date-grouped rows in inset containers, quiet
/// status system, and a row context menu (open/copy/reveal/rename/
/// re-transcribe/trash).
struct LibraryView: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(LibraryStore.self) private var library
    @Environment(MeetingSessionStore.self) private var session
    @Environment(WhisperModelManager.self) private var models
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueStore.self) private var queue: QueueStore?
    @Environment(AppRouter.self) private var router
    /// Native Settings-window opener, used by the Upcoming agenda's
    /// "Connect your calendar" affordance to deep-link to Settings →
    /// Privacy (mirrors `RootView`'s `-open settings/<tab>` handling).
    @Environment(\.openSettings) private var openSettings

    /// Owned by `RootView`; the toolbar's search field opens the same ⌘K
    /// overlay the global shortcut does.
    @Binding var showSearch: Bool

    @State private var dropTargeted = false
    @State private var renameTarget: MeetingRecord?
    /// Drives the Upcoming section's countdown/pruning without a `.timer`
    /// Text or periodic `TimelineView` (both peg the CPU inside long-lived
    /// SwiftUI hierarchies — see `MenuBarLabel`). A plain 30s sleep loop,
    /// cancelled on disappear, calls `refresh()` directly instead.
    @State private var upcomingRefreshTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let agendaState {
                    agendaView(for: agendaState)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                }
                if library.meetings.isEmpty {
                    emptyState
                        .padding(.horizontal, 24)
                        .padding(.top, agendaState == nil ? 16 : 18)
                } else if library.displayMeetings.isEmpty {
                    filteredEmptyState
                        .padding(.horizontal, 24)
                        .padding(.top, agendaState == nil ? 16 : 18)
                } else {
                    content
                        .padding(.horizontal, 24)
                        .padding(.top, agendaState == nil ? 16 : 18)
                }
                Color.clear.frame(height: 24)
            }
        }
        .background(Tokens.surface)
        .axID(.libraryList)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropHighlight } }
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
    /// countdown and today-remaining pruning stay fresh without a per-frame
    /// timer.
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

    // MARK: Toolbar (design global #3 — unified toolbar, not an in-content header)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            searchField
        }
        if !library.meetings.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                sortFilterMenu
            }
        }
        ToolbarItem(placement: .primaryAction) {
            recordButton
        }
    }

    /// Styled like a compact search field, but it's a button — clicking (or
    /// ⌘K) opens the existing full-screen search overlay rather than typing
    /// inline. Deliberately no `Spacer()`/fixed-frame combination: SwiftUI
    /// toolbar items size themselves from intrinsic content, and a
    /// `Spacer()` inside a `.frame(width:)` here reliably produced a
    /// zero-width `NSToolbarItem` that AppKit silently dropped from the
    /// toolbar — fixed spacing avoids that failure mode.
    private var searchField: some View {
        Button {
            showSearch = true
        } label: {
            HStack(spacing: 34) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textTertiary)
                    Text("Search")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Text("⌘K")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(width: 220, height: 28)
            .background(Tokens.chipBackground, in: Capsule())
            .overlay(Capsule().stroke(Tokens.hairline, lineWidth: 1))
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

    private var sortFilterMenu: some View {
        @Bindable var library = library
        return Menu {
            Picker("Sort", selection: $library.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            Divider()
            Toggle("Ready only", isOn: $library.filter.readyOnly)
            Toggle("Longer than 15 minutes", isOn: Binding(
                get: { library.filter.minDuration != nil },
                set: { library.filter.minDuration = $0 ? 900 : nil }
            ))
        } label: {
            HStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(Tokens.chipBackground)
                        .overlay(Circle().stroke(Tokens.hairline, lineWidth: 1))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Tokens.textSecondary)
                        }
                    if library.filter.isActive {
                        Circle()
                            .fill(Tokens.accentBlue)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort and filter the library")
        .axID(.librarySortFilterMenu)
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

    // MARK: Upcoming agenda

    /// The agenda is lifted above `content`/`emptyState`/`filteredEmptyState`
    /// so it renders on a brand-new, zero-meeting library too (bug fix: it
    /// used to live only inside `content`, which never mounts while
    /// `library.meetings.isEmpty` — a new user who'd connected their
    /// calendar saw nothing). `nil` while a filter/search is narrowing the
    /// list or the sort is `.longest` (matches the old `showUpcomingSection`
    /// behavior); otherwise always one of the three `UpcomingAgendaState`
    /// cases, never silently absent.
    private var agendaState: UpcomingAgendaState? {
        guard let stores else { return nil }
        return UpcomingAgendaState.resolve(
            isAvailable: stores.upcoming.isAvailable,
            events: stores.upcoming.events,
            isFilterActive: library.filter.isActive,
            isLongestSort: library.sort == .longest
        )
    }

    @ViewBuilder
    private func agendaView(for state: UpcomingAgendaState) -> some View {
        switch state {
        case .hasEvents(let events):
            UpcomingSection(
                events: events,
                isRecording: session.isRecording,
                now: .now,
                onRecord: { event in
                    stores?.startRecording(title: event.title, attendees: event.otherAttendees)
                }
            )
        case .authorizedEmpty:
            UpcomingEmptyTodayView()
        case .unauthorized:
            UpcomingConnectCalendarView {
                router.pendingSettingsTab = .privacy
                openSettings()
            }
        }
    }

    // MARK: List content

    /// Grouped-with-headers for date sorts, a flat list (single container)
    /// for `.longest` (a duration ranking reads oddly split into date
    /// buckets). The Upcoming agenda itself now lives in `body`, not here.
    @ViewBuilder private var content: some View {
        if library.sort == .longest {
            groupCard(for: library.displayMeetings)
        } else {
            let sections = MeetingGrouping.sections(library.displayMeetings, now: .now, calendar: .current)
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                ForEach(sections, id: \.id) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        sectionHeader(section.title)
                        groupCard(for: section.records)
                    }
                }
            }
        }
    }

    /// One rounded, hairline-bordered container per date group (design mock
    /// 6a): subtle fill, radius 10, row separators inset past the icon tile.
    private func groupCard(for records: [MeetingRecord]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                if index > 0 {
                    Divider()
                        .overlay(Tokens.hairline)
                        .padding(.leading, 53)
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
        MeetingRow(record: record, onInstallModel: { router.section = .models })
            .contentShape(Rectangle())
            .onTapGesture { library.selectedMeetingID = record.meeting.id }
            .contextMenu {
                rowContextMenu(for: record)
            }
            .axID(.meetingRow(record.meeting.id.uuidString))
    }

    @ViewBuilder
    private func rowContextMenu(for record: MeetingRecord) -> some View {
        Button("Open") {
            library.selectedMeetingID = record.meeting.id
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No meetings yet", systemImage: "waveform")
                .font(Tokens.rowTitle)
                .foregroundStyle(Tokens.textPrimary)
        } description: {
            Text("Hit Record when your next call starts. Recap captures the audio, transcribes it on this Mac, and turns your rough notes into a clean summary.")
                .font(Tokens.meta)
                .foregroundStyle(Tokens.textSecondary)
        }
        .padding(.top, 120)
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label("No matching meetings", systemImage: "line.3.horizontal.decrease.circle")
                .font(Tokens.rowTitle)
                .foregroundStyle(Tokens.textPrimary)
        } description: {
            Text("Try loosening the filter — fewer conditions or a shorter minimum length.")
                .font(Tokens.meta)
                .foregroundStyle(Tokens.textSecondary)
        }
        .padding(.top, 120)
    }
}

/// A single Library row (design mock 6a): 28×28 neutral icon tile, title,
/// meta line, trailing quiet status. Ready rows show only a chevron on
/// hover; other statuses show their own indicator instead.
private struct MeetingRow: View {
    var record: MeetingRecord
    var onInstallModel: () -> Void
    @Environment(QueueStore.self) private var queue: QueueStore?
    @Environment(LibraryStore.self) private var library
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            iconTile
            VStack(alignment: .leading, spacing: 1) {
                Text(record.meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = record.meeting.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                }
                Text(record.meeting.metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? Tokens.chipBackground.opacity(0.6) : Color.clear)
        .onHover { hovering = $0 }
    }

    /// Ready rows are silent (design global #4) except for a hover chevron —
    /// no chip, no color. Every other status keeps its own indicator so
    /// hovering doesn't hide information the user needs (progress, retry).
    @ViewBuilder private var trailing: some View {
        if record.meeting.status == .ready {
            if hovering {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.textTertiary)
            }
        } else {
            MeetingStatusView(
                status: record.meeting.status,
                onInstallModel: onInstallModel,
                onRetry: { queue?.retranscribe(record, in: library) }
            )
        }
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Tokens.chipBackground)
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
            }
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
