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
    @State private var playback = PlaybackStore()

    private var isLiveMeeting: Bool {
        session.activeRecord?.meeting.id == record.meeting.id
    }

    /// True once this meeting is done recording and its audio file is a real,
    /// playable file on disk (fixture records point at `/dev/null`, which
    /// exists but isn't a regular file — treated as "no audio").
    private var hasPlayableAudio: Bool {
        guard !isLiveMeeting else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.audioURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        let resourceValues = try? record.audioURL.resourceValues(forKeys: [.isRegularFileKey])
        return resourceValues?.isRegularFile ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
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
                    .frame(minWidth: 260, idealWidth: 420)
                }
                editor
                    .frame(minWidth: 320)
            }
            bottomBar
        }
        .environment(playback)
        .toolbar {
            ToolbarItem {
                copyNotesButton
            }
            ToolbarItem {
                Toggle(isOn: $showTranscript) {
                    Label("Transcript", systemImage: "text.quote")
                }
                .help("Show transcript")
            }
        }
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

            // Playback docking (design handoff v2 §8d): a finished meeting
            // with real audio on disk loads into the shared PlaybackStore so
            // the player bar can dock where the status bar sits; anything
            // else (still recording, or no audio file) unloads it.
            if hasPlayableAudio {
                playback.load(url: record.audioURL)
            } else {
                playback.unload()
            }
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
                // A meeting that finishes while open gains playable audio —
                // dock the player without requiring a navigate-away-and-back.
                if !playback.hasAudio, hasPlayableAudio {
                    playback.load(url: record.audioURL)
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
            header
                .padding(.horizontal, 40)
                .padding(.top, 26)
            if case .enhancing = record.meeting.status {
                enhancingBanner
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
            }
            if let enhancedNotes, !showingOriginal {
                EnhancedNotesView(markdown: enhancedNotes)
                    .padding(.top, 8)
                enhancedCaption
                    .padding(.horizontal, 40)
                    .padding(.bottom, 16)
            } else {
                TextEditor(text: $notes)
                    .font(Tokens.body)
                    .foregroundStyle(enhancedNotes != nil ? Tokens.textSecondary : Tokens.textBody)
                    .lineSpacing(7)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 34)
                    .padding(.top, 16)
            }
        }
        .background(Tokens.surface)
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
            CopyButton(help: isShowingEnhanced ? "Copy summary" : "Copy notes") {
                isShowingEnhanced ? (enhancedNotes ?? "") : notes
            }
        }
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
        }
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(record.meeting.title)
                    .font(.system(size: 22, weight: .bold))
                    .kerning(-0.3)
                    .foregroundStyle(Tokens.textPrimary)
                Spacer(minLength: 12)
                notesModeToggle
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
    /// transient input-switch note is now routed to a toast by another
    /// package; `session.inputSwitchNote` itself stays for that consumer.
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

    /// Docks the player bar where the status bar sits once this meeting has
    /// playable audio (design handoff v2 §8d); otherwise the quiet status
    /// bar. Both hide entirely while this meeting is actively recording —
    /// the in-window recording pill overlays that area.
    @ViewBuilder
    private var bottomBar: some View {
        if isLiveMeeting {
            EmptyView()
        } else if playback.hasAudio {
            PlayerBar(playback: playback)
                .background(Tokens.subtleBackground.opacity(0.9))
                .overlay(alignment: .top) { Divider() }
        } else {
            statusBar
        }
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
