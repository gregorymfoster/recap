import CoreAudio
import Foundation
import RecapAudio
import RecapCore
import RecapTranscription
import SwiftUI

/// The meeting editor (design mocks 1a/1b): notes-first, with a toggleable
/// transcript pane — live while recording, saved afterwards.
struct MeetingDetailView: View {
    var record: MeetingRecord
    @Environment(LibraryStore.self) private var library
    @Environment(MeetingSessionStore.self) private var session
    @Environment(WhisperModelManager.self) private var models
    @Environment(SettingsStore.self) private var settings
    @State private var notes = ""
    @State private var showTranscript = false
    @State private var savedTranscript: Transcript?
    @State private var enhancedNotes: String?
    @State private var speakerNames: [String: String] = [:]
    @State private var showingOriginal = false
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var deviceListListener: AudioObjectPropertyListenerBlock?
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @FocusState private var titleFieldFocused: Bool

    private var isLiveMeeting: Bool {
        session.activeRecord?.meeting.id == record.meeting.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                editor
                    .frame(minWidth: 320)
                // Right-side inspector per design handoff v2 §6b.
                if showTranscript {
                    TranscriptPane(
                        utterances: isLiveMeeting ? session.liveUtterances : savedTranscript?.utterances ?? [],
                        partial: isLiveMeeting ? session.partialUtterance : nil,
                        isLive: isLiveMeeting,
                        liveState: isLiveMeeting ? session.liveState : nil,
                        onDownloadStreamingModel: { models.ensureStreamingModelDownloading() },
                        speakerNames: speakerNames,
                        attendees: record.meeting.attendees,
                        onRenameSpeaker: isLiveMeeting ? nil : { speakerID, name in
                            library.renameSpeaker(speakerID, to: name, in: record)
                            speakerNames[speakerID] = name
                        }
                    )
                    .frame(minWidth: 260, idealWidth: 340)
                    .axID(.transcriptPane)
                }
            }
            bottomBar
        }
        .navigationTitle(record.meeting.title)
        .task(id: record.meeting.id) {
            notes = library.loadNotes(for: record)
            savedTranscript = library.loadTranscript(for: record)
            enhancedNotes = library.loadEnhancedNotes(for: record)
            speakerNames = library.loadSpeakerNames(for: record)
            showingOriginal = record.meeting.preferredNotesView == .original
            // Default to the split view whenever there's a transcript to show —
            // live meetings (text appears as it's spoken) and finished ones
            // (transcript lands next to the summary without hunting for the
            // toggle). The toolbar toggle still hides it.
            showTranscript = isLiveMeeting || savedTranscript?.utterances.isEmpty == false
        }
        .task(id: record.meeting.status) {
            // Refresh once the pipeline lands results (status flips to ready).
            if case .ready = record.meeting.status {
                if savedTranscript == nil {
                    savedTranscript = library.loadTranscript(for: record)
                }
                if enhancedNotes == nil {
                    enhancedNotes = library.loadEnhancedNotes(for: record)
                }
                if savedTranscript?.utterances.isEmpty == false {
                    showTranscript = true
                }
            }
        }
        .onChange(of: notes) {
            library.notesChanged(notes, in: record)
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
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailControls
            detailPaneContent
        }
        .background(Tokens.surface)
    }

    /// Copy + transcript-toggle chips on their own top row, right-aligned so
    /// they never compete for width with the date/badge row (which matters when
    /// the transcript pane is open and this editor pane is narrow). Kept OUTSIDE
    /// `detailPaneContent`'s `.axID(.detailPane)` subtree so each chip retains
    /// its own AXID (`detail-copy-notes-button` / `transcript-toggle-button`)
    /// instead of being absorbed into `library-detail-pane`. They used to sit in
    /// the window `.toolbar`, but macOS 26 wraps toolbar items in a shared Liquid
    /// Glass capsule — the outer "bubble" the design doesn't want behind these
    /// already-styled chips.
    private var detailControls: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            copyNotesButton
            transcriptToggle
        }
        .padding(.horizontal, 40)
        .padding(.top, 18)
    }

    private var detailPaneContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 40)
                .padding(.top, 10)
            if case .enhancing = record.meeting.status {
                enhancingBanner
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
            }
            if let enhancedNotes, !showingOriginal {
                EnhancedNotesView(markdown: enhancedNotes)
                    .axID(.enhancedNotesView)
                    .padding(.top, 8)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        enhancedCaption
                            .padding(.horizontal, 40)
                            .padding(.top, 10)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Tokens.surface)
                    }
            } else {
                TextEditor(text: $notes)
                    .font(Tokens.body)
                    .foregroundStyle(enhancedNotes != nil ? Tokens.textSecondary : Tokens.textBody)
                    .lineSpacing(7)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .axID(.notesEditor)
            }
        }
        .axID(.detailPane)
    }

    /// True when the editor pane is currently showing the enhanced summary
    /// rather than the user's raw notes.
    private var isShowingEnhanced: Bool {
        enhancedNotes != nil && !showingOriginal
    }

    /// Copies whatever the editor pane is showing right now: the enhanced
    /// summary markdown, or the raw notes. Lives in the window toolbar next
    /// to the transcript toggle (design handoff v2 §6b).
    @ViewBuilder
    private var copyNotesButton: some View {
        let displayed = isShowingEnhanced ? (enhancedNotes ?? "") : notes
        if !displayed.isEmpty {
            CopyButton(help: isShowingEnhanced ? "Copy summary" : "Copy notes", toolbarStyle: true) {
                isShowingEnhanced ? (enhancedNotes ?? "") : notes
            }
            .axID(.detailCopyNotesButton)
        }
    }

    /// Circular toolbar bubble matching the Library toolbar family; filled
    /// with the accent color while the transcript inspector is visible.
    private var transcriptToggle: some View {
        Button {
            showTranscript.toggle()
        } label: {
            Image(systemName: "text.quote")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(showTranscript ? Color.white : Tokens.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    showTranscript ? AnyShapeStyle(Tokens.accentBlue) : AnyShapeStyle(Tokens.chipBackground),
                    in: Circle()
                )
                .overlay {
                    if !showTranscript {
                        Circle().stroke(Tokens.hairline, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(showTranscript ? "Hide transcript" : "Show transcript")
        .axID(.transcriptToggleButton)
    }

    /// Blue-tinted banner shown while this meeting's notes are being
    /// enhanced on-device; raw notes remain visible/editable below at
    /// reduced emphasis. Design handoff v2 §8c.
    private var enhancingBanner: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Enhancing your notes from the transcript")
                    .font(Tokens.caption.weight(.semibold))
                    .foregroundStyle(Tokens.accentBlue)
                Text("On-device · your notes stay untouched below")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Tokens.accentBlue.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Tokens.accentBlue.opacity(0.2))
        }
    }

    /// "✨ Enhanced from the transcript" + Undo, shown under the enhanced
    /// content. Undo is non-destructive — it only switches the active view
    /// back to My notes; the enhanced notes stay one click away.
    private var enhancedCaption: some View {
        HStack(spacing: 6) {
            Text("✨ Enhanced from the transcript")
                .font(.system(size: 10.5))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: true, vertical: false)
            Button {
                setNotesView(.original)
            } label: {
                Text("Undo")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Tokens.accentBlue)
            }
            .buttonStyle(.plain)
            .axID(.enhancedNotesUndoButton)
        }
    }

    /// "✨ Enhanced / My notes" native segmented control, top-right of the
    /// notes column once enhanced notes exist. Design handoff v2 §8c.
    @ViewBuilder
    private var notesModeToggle: some View {
        if enhancedNotes != nil {
            Picker("", selection: Binding(
                get: { showingOriginal ? NotesViewPreference.original : .enhanced },
                set: { setNotesView($0) }
            )) {
                Text("✨ Enhanced").tag(NotesViewPreference.enhanced)
                Text("My notes").tag(NotesViewPreference.original)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .axID(.notesModeToggle)
        }
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

    /// Switches the active notes view and persists the choice per meeting
    /// (nil default means "prefer Enhanced whenever available" — selecting
    /// Enhanced explicitly stores nil rather than `.enhanced` so a later
    /// meeting without enhancement doesn't inherit a stale "original" habit
    /// while still recording today's explicit choice).
    private func setNotesView(_ preference: NotesViewPreference) {
        showingOriginal = preference == .original
        library.setPreferredNotesView(preference == .original ? .original : nil, for: record.meeting.id)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.meeting.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                OnDeviceBadge()
                    .fixedSize()
                if session.systemAudioUnavailable, isLiveMeeting {
                    Text(RecapCopy.systemAudioUnavailableMessage)
                        .font(Tokens.microLabel)
                        .foregroundStyle(Tokens.warningAmberText)
                }
            }
            // Title and mode toggle share a row only when the title actually
            // fits beside it; in a narrow editor pane the toggle drops below
            // instead of squeezing the title into letter-per-line wrapping.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleText
                    Spacer(minLength: 12)
                    notesModeToggle
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleText
                    notesModeToggle
                }
            }
            if let subtitle = record.meeting.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(2)
            }
            if !record.meeting.attendees.isEmpty {
                HStack(spacing: 6) {
                    ForEach(record.meeting.attendees, id: \.self) { attendee in
                        Text(attendee)
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Tokens.chipBackground, in: Capsule())
                    }
                }
                .padding(.top, 4)
            }
            if isLiveMeeting {
                liveInputRow
            }
        }
    }

    /// Input-device selector, shown only in the live meeting's header. The
    /// transient input-switch note is routed to a toast via `onInputRebuilt`
    /// instead of being rendered here.
    private var liveInputRow: some View {
        @Bindable var settings = settings
        return HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 10))
                .foregroundStyle(Tokens.textTertiary)
            Picker("", selection: $settings.preferredInputUID) {
                Text("System default").tag(String?.none)
                ForEach(inputDevices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .axID(.liveInputDevicePicker)
            .onChange(of: settings.preferredInputUID) {
                session.setPreferredInputUID(settings.preferredInputUID)
            }
            if let name = session.activeInputDeviceName {
                Text(name)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .padding(.top, 2)
    }

    /// Shows the quiet status bar for a finished meeting; hides entirely
    /// while this meeting is actively recording — the in-window recording
    /// pill overlays that area.
    @ViewBuilder
    private var bottomBar: some View {
        if isLiveMeeting { EmptyView() } else { statusBar }
    }

    /// Quiet single-line status bar (global decision #5): active model name
    /// + priority on the left, save location on the right. No status chips.
    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(models.activeModel.map { "\($0.displayName) · low priority" } ?? "No model installed")
            Spacer()
            if case .ready = record.meeting.status {
                Text("Saved · \(library.saveLocationLabel)")
            } else {
                Text("Saving to \(library.saveLocationLabel)")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Tokens.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Tokens.subtleBackground.opacity(0.9))
        .overlay(alignment: .top) { Divider() }
    }
}

#if DEBUG
private func previewRecord() -> MeetingRecord {
    MeetingRecord(
        meeting: Meeting(
            title: "Design sync — Q3 roadmap",
            date: .now.addingTimeInterval(-3600),
            duration: 1_453,
            attendees: ["Maya", "Sam", "Priya"],
            status: .ready
        ),
        folderURL: URL(filePath: "/dev/null")
    )
}

#Preview("Light") {
    MeetingDetailView(record: previewRecord())
        .environment(LibraryStore.fixture())
        .environment(MeetingSessionStore())
        .environment(WhisperModelManager())
        .environment(SettingsStore())
        .frame(width: 900, height: 640)
}

#Preview("Dark") {
    MeetingDetailView(record: previewRecord())
        .environment(LibraryStore.fixture())
        .environment(MeetingSessionStore())
        .environment(WhisperModelManager())
        .environment(SettingsStore())
        .frame(width: 900, height: 640)
        .preferredColorScheme(.dark)
}
#endif
