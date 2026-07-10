import RecapCore
import SwiftUI

/// The meeting detail page (design mock 10b/11d): "the transcript IS the
/// page" — a single centered column with the title, a collapsed-by-default
/// summary/notes disclosure, and the full transcript rendered inline below
/// it. Recording now routes to its own screen, so this view only ever shows
/// a saved (or still-processing) meeting — there is no live-recording branch
/// here anymore.
struct MeetingDetailView: View {
    var record: MeetingRecord
    @Environment(LibraryStore.self) private var library
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(QueueStore.self) private var queue: QueueStore?
    @State private var notes = ""
    @State private var savedTranscript: Transcript?
    @State private var enhancedNotes: String?
    @State private var speakerNames: [String: String] = [:]
    @State private var timedNotes: [TimedNote] = []
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @FocusState private var titleFieldFocused: Bool

    /// Column width for the whole page — title, summary disclosure, and
    /// transcript all share this single centered column (design mock 10b/11d).
    private static let columnWidth: CGFloat = 620

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !record.meeting.processingIssues.isEmpty {
                    issuesSection
                }
                SummaryDisclosure(enhancedNotes: enhancedNotes, notes: $notes, isEnhancing: isEnhancing)
                transcriptSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 40)
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            // On the inner stack, not the ScrollView: RootView's `.axID(.rootView)`
            // lands on the same AXScrollArea and would clobber this id there.
            .accessibilityElement(children: .contain)
            .axID(.detailPane)
        }
        .background(Tokens.surface)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    backedUpStatus
                    copyTranscriptButton
                }
            }
        }
        .task(id: record.meeting.id) {
            notes = library.loadNotes(for: record)
            savedTranscript = library.loadTranscript(for: record)
            enhancedNotes = library.loadEnhancedNotes(for: record)
            speakerNames = library.loadSpeakerNames(for: record)
            timedNotes = library.timedNotes(for: record)
        }
        .task(id: record.meeting.status) {
            // Refresh once the pipeline lands results (status flips to ready)
            // so the pretranscript skeleton swaps for the real transcript in
            // place without a manual reload.
            if case .ready = record.meeting.status {
                if savedTranscript?.utterances.isEmpty != false {
                    savedTranscript = library.loadTranscript(for: record)
                }
                if enhancedNotes == nil {
                    enhancedNotes = library.loadEnhancedNotes(for: record)
                }
                timedNotes = library.timedNotes(for: record)
            }
        }
        .onChange(of: notes) {
            library.notesChanged(notes, in: record)
        }
        // Catches every in-app screen swap away from this detail page
        // (library back button already flushes explicitly, but a window
        // close, launch-route jump, or direct `router.screen` change all
        // tear this view down without going through that button) — without
        // this, a note edit still sitting inside the 1s autosave debounce
        // is lost.
        .onDisappear {
            library.flushNotes(for: record)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleText
            Text(metaLine)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textPrimary.opacity(0.45))
                .lineLimit(1)
        }
    }

    /// "Thu, Jul 9 · 9:29 AM · 15 min · 3 speakers · on-device" — date,
    /// start time, duration, speaker count (once known from the transcript),
    /// and a plain "on-device" badge-as-text (design mock 10b/11d).
    private var metaLine: String {
        var parts = [
            record.meeting.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
            record.meeting.date.formatted(.dateTime.hour().minute()),
        ]
        if record.meeting.duration > 0 {
            parts.append(Duration.seconds(record.meeting.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if let speakerCount, speakerCount > 0 {
            parts.append(speakerCount == 1 ? "1 speaker" : "\(speakerCount) speakers")
        }
        parts.append("on-device")
        return parts.joined(separator: " · ")
    }

    private var speakerCount: Int? {
        guard let utterances = savedTranscript?.utterances, !utterances.isEmpty else { return nil }
        return Set(utterances.compactMap(\.speakerID)).count
    }

    /// Click-to-edit title (Granola-like): a double-click on the read-only
    /// title reveals a real `TextField` seeded with the current title, styled
    /// identically so the swap doesn't jump. Commits on Return/focus loss via
    /// `commitTitleEdit()`; Escape cancels without renaming. Reuses
    /// `RenameSheetModifier`'s trim/empty semantics and `library.rename`'s
    /// existing persistence (disk + fixture branches, search index, change bus).
    @ViewBuilder
    private var titleText: some View {
        if isEditingTitle {
            TextField("Title", text: $editedTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.3)
                .foregroundStyle(Tokens.textPrimary)
                .lineLimit(1)
                .focused($titleFieldFocused)
                .onSubmit { commitTitleEdit() }
                .onExitCommand { cancelTitleEdit() }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused { commitTitleEdit() }
                }
                .axID(.detailTitleField)
        } else {
            Text(record.meeting.title)
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.3)
                .foregroundStyle(Tokens.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .help("Double-click to rename")
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginTitleEdit() }
                .axID(.detailTitleText)
        }
    }

    private func beginTitleEdit() {
        editedTitle = record.meeting.title
        isEditingTitle = true
        titleFieldFocused = true
    }

    private func commitTitleEdit() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != record.meeting.title {
            library.rename(record, to: trimmed)
        }
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
    }

    // MARK: Processing issues

    private var issuesSection: some View {
        VStack(spacing: 8) {
            ForEach(record.meeting.processingIssues) { issue in
                ProcessingIssueCard(issue: issue) { retry(issue) }
            }
        }
    }

    private func retry(_ issue: ProcessingIssue) {
        switch issue {
        case .recordingFileMissing, .transcriptionFailed:
            queue?.retranscribe(record, in: library)
        case .enhancementFailed:
            queue?.retryEnhancement(record, in: library)
        case .mirrorBackupFailed:
            queue?.retryExport(record, in: library)
        }
    }

    private var isEnhancing: Bool {
        if case .enhancing = record.meeting.status { return true }
        return false
    }

    // MARK: Transcript

    /// The transcript, or — before one exists yet — the pretranscript state
    /// (design mock 11d): status copy, a progress bar when known, and
    /// skeleton lines.
    @ViewBuilder
    private var transcriptSection: some View {
        if let savedTranscript, !savedTranscript.utterances.isEmpty {
            TranscriptPane(
                items: TranscriptMerge.merged(utterances: savedTranscript.utterances, notes: timedNotes),
                speakerNames: speakerNames,
                attendees: record.meeting.attendees,
                onRenameSpeaker: { speakerID, name in
                    library.renameSpeaker(speakerID, to: name, in: record)
                    speakerNames[speakerID] = name
                }
            )
            .axID(.transcriptPane)
        } else {
            pretranscriptState
        }
    }

    private var pretranscriptState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if case .transcribing = record.meeting.status {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(pretranscriptStatusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pretranscriptStatusColor)
            }
            if let transcribingProgress {
                ProgressView(value: transcribingProgress)
                    .progressViewStyle(.linear)
                    .tint(Tokens.accentBlue)
                    .frame(height: 4)
            }
            skeletonLines
        }
        .padding(.top, 4)
        .axID(.detailSkeleton)
    }

    private var pretranscriptStatusLabel: String {
        switch record.meeting.status {
        case .transcribing(let progress):
            "Transcribing · \(Int((progress * 100).rounded()))%"
        case .needsModel:
            "Waiting for setup"
        case .recovered:
            "Recovered — press Transcribe in the Library"
        case .error:
            "Transcription needs another try"
        default:
            "Waiting to transcribe"
        }
    }

    private var pretranscriptStatusColor: Color {
        if case .error = record.meeting.status { return Tokens.warningAmberText }
        return Tokens.accentBlue
    }

    private var transcribingProgress: Double? {
        if case .transcribing(let progress) = record.meeting.status { return progress }
        return nil
    }

    private var skeletonLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            skeletonLine(widthFraction: 0.88)
            skeletonLine(widthFraction: 0.72)
            skeletonLine(widthFraction: 0.80)
        }
    }

    private func skeletonLine(widthFraction: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4)
                .fill(Tokens.chipBackground)
                .frame(width: proxy.size.width * widthFraction, height: 9)
        }
        .frame(height: 9)
    }

    // MARK: Toolbar

    /// Quiet "✓ Backed up" status, hidden while the mirror backup for this
    /// meeting is still pending — `stores` is optional (previews/tests) so
    /// this simply doesn't show without a real backup store.
    @ViewBuilder
    private var backedUpStatus: some View {
        if case .backedUp = stores?.backup.backupStatus(for: record.meeting.id) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.successGreenText)
                Text("Backed up")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textPrimary.opacity(0.45))
            }
            .axID(.detailBackedUpStatus)
        }
    }

    /// The page's one copy affordance — copies the full transcript, since
    /// the transcript is the page's primary content now.
    @ViewBuilder
    private var copyTranscriptButton: some View {
        if let savedTranscript, !savedTranscript.utterances.isEmpty {
            CopyButton(help: "Copy transcript", toolbarStyle: true) {
                TranscriptFormatter.plainText(utterances: savedTranscript.utterances, speakerNames: speakerNames)
            }
            .axID(.transcriptCopyButton)
        }
    }
}

#if DEBUG
private func previewRecord(status: MeetingStatus = .ready) -> MeetingRecord {
    MeetingRecord(
        meeting: Meeting(
            title: "Design sync — Q3 roadmap",
            date: .now.addingTimeInterval(-3600),
            duration: 1_453,
            attendees: ["Maya", "Sam", "Priya"],
            status: status
        ),
        folderURL: URL(filePath: "/dev/null")
    )
}

#Preview("Light") {
    MeetingDetailView(record: previewRecord())
        .environment(LibraryStore.fixture())
        .frame(width: 900, height: 640)
}

#Preview("Dark") {
    MeetingDetailView(record: previewRecord())
        .environment(LibraryStore.fixture())
        .frame(width: 900, height: 640)
        .preferredColorScheme(.dark)
}

#Preview("Pretranscript") {
    MeetingDetailView(record: previewRecord(status: .transcribing(progress: 0.42)))
        .environment(LibraryStore.fixture())
        .frame(width: 900, height: 640)
}
#endif
