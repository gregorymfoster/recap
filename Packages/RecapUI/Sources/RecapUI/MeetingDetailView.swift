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
    @State private var showingOriginal = false
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var deviceListListener: AudioObjectPropertyListenerBlock?

    private var isLiveMeeting: Bool {
        session.activeRecord?.meeting.id == record.meeting.id
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
                        onDownloadStreamingModel: { models.ensureStreamingModelDownloading() }
                    )
                    .frame(minWidth: 260, idealWidth: 420)
                }
                editor
                    .frame(minWidth: 320)
            }
            statusBar
        }
        .toolbar {
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
            showingOriginal = false
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
            header
                .padding(.horizontal, 40)
                .padding(.top, 26)
            if let enhancedNotes, !showingOriginal {
                EnhancedNotesView(markdown: enhancedNotes)
                    .padding(.top, 8)
            } else {
                TextEditor(text: $notes)
                    .font(Tokens.body)
                    .foregroundStyle(Tokens.textBody)
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
    /// summary markdown, or the raw notes.
    @ViewBuilder
    private var copyNotesButton: some View {
        let displayed = isShowingEnhanced ? (enhancedNotes ?? "") : notes
        if !displayed.isEmpty {
            CopyButton(help: isShowingEnhanced ? "Copy summary" : "Copy notes") {
                isShowingEnhanced ? (enhancedNotes ?? "") : notes
            }
        }
    }

    /// "✨ Enhanced / My original notes" switcher, shown once enhancement exists.
    @ViewBuilder
    private var notesModeToggle: some View {
        if enhancedNotes != nil {
            Button {
                showingOriginal.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingOriginal ? "sparkles" : "pencil")
                        .font(.system(size: 9))
                    Text(showingOriginal ? "View enhanced" : "My original notes")
                        .font(Tokens.microLabel)
                }
                .foregroundStyle(Tokens.accentBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Tokens.accentBlue.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.meeting.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textSecondary)
                OnDeviceBadge()
                if session.systemAudioUnavailable, isLiveMeeting {
                    Text(RecapCopy.systemAudioUnavailableMessage)
                        .font(Tokens.microLabel)
                        .foregroundStyle(Tokens.warningAmberText)
                }
            }
            HStack(spacing: 10) {
                Text(record.meeting.title)
                    .font(Tokens.pageTitle)
                    .kerning(-0.4)
                    .foregroundStyle(Tokens.textPrimary)
                notesModeToggle
                copyNotesButton
            }
            if !record.meeting.attendees.isEmpty {
                HStack(spacing: 6) {
                    ForEach(record.meeting.attendees, id: \.self) { attendee in
                        Text(attendee)
                            .font(Tokens.caption)
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

    /// Input-device selector + a transient note when a mid-recording switch
    /// lands, shown only in the live meeting's header.
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
            if let note = session.inputSwitchNote {
                Text(note)
                    .font(Tokens.microLabel)
                    .foregroundStyle(Tokens.successGreenText)
                    .transition(.opacity)
            } else if let name = session.activeInputDeviceName {
                Text(name)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.inputSwitchNote)
        .padding(.top, 2)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(models.activeModel.map { "\($0.displayName) · \($0.languages)" } ?? "No model installed")
            Text("·")
            Text("CPU: low-priority")
            Spacer()
            if case .ready = record.meeting.status {
                persistenceChips
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

    /// Once a meeting is `.ready`, the trailing "Saving to …" text upgrades to
    /// truthful chips: always a "Saved" chip (the folder exists on disk), plus
    /// "Backed up" only after the folder mirror actually succeeded. With
    /// backup disabled, a quiet "Local only" note — informative, not alarming.
    private var persistenceChips: some View {
        HStack(spacing: 8) {
            persistenceChip("Saved")
                .help("Saved in \(record.folderURL.path)")
            if let backupDate = record.meeting.lastBackupDate {
                persistenceChip("Backed up")
                    .help("Backed up to \(backupLocationLabel) · \(backupDate.formatted(.relative(presentation: .named)))")
            } else if !settings.mirrorBackupEnabled || settings.mirrorFolderPath.isEmpty {
                Text("Local only")
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
    }

    /// Green-check chip, styled after `MeetingStatusView`'s chips.
    private func persistenceChip(_ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9))
            Text(label)
                .font(Tokens.caption.weight(.semibold))
        }
        .foregroundStyle(Tokens.successGreenText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Tokens.successGreenTint, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
    }

    /// "~/…"-abbreviated mirror-backup destination, like `saveLocationLabel`.
    private var backupLocationLabel: String {
        let path = settings.mirrorFolderPath
        guard !path.isEmpty else { return "backup folder" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
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
