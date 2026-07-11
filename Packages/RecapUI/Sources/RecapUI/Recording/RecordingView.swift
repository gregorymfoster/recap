import CoreAudio
import RecapAudio
import RecapCore
import SwiftUI

/// Full-window content for `router.screen == .recording` (design spec 11a):
/// an editable meeting title, a meta line, a running list of timestamped
/// notes, and a note-input field anchored under that list whose placeholder
/// ticks with the live elapsed time. There is deliberately no live-transcript
/// pane here — the docked `SessionCapsule` floating at the bottom of the
/// window is the one pause/stop/device control surface; this view owns no
/// recording controls of its own. Replaces the Phase 0
/// `RecordingHostPlaceholderView` placeholder.
struct RecordingView: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(AppRouter.self) private var router
    @Environment(MeetingSessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings

    @State private var noteText = ""
    @State private var notes: [TimedNote] = []
    /// Bumped once a second (see `noteInput`) purely to force
    /// `notePlaceholder` to recompute — the note `TextField` itself lives
    /// outside this tick so it isn't rebuilt (and doesn't lose focus).
    @State private var placeholderTick = 0
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var deviceListListener: AudioObjectPropertyListenerBlock?
    @FocusState private var noteFieldFocused: Bool
    /// Shows the green checkmark confirmation for the first 5s of the
    /// screen, then settles into a quiet, checkmark-free label — the
    /// confirmation matters right after hitting Record, not for the rest of
    /// a long meeting.
    @State private var showingSavingConfirmation = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var record: MeetingRecord? { session.activeRecord }

    var body: some View {
        Group {
            if let record {
                recordingContent(for: record)
            } else {
                // Shouldn't happen — `RootView` only mounts `RecordingView`
                // while `session.activeRecord != nil` — but stay inert
                // rather than crash if the recording ends mid-frame.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.surface)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Library", systemImage: "chevron.left") {
                    // Back to the Library while the session keeps recording —
                    // the toolbar there swaps Record for a quiet
                    // "● Recording · MM:SS" pill that returns here.
                    router.screen = .library
                }
                .help("Back to Library")
                .axID(.libraryBackButton)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                savingStatus
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .overlay(alignment: .bottom) {
            if session.activeRecord != nil, let clock = session.clock {
                SessionCapsule(
                    variant: .docked,
                    clock: clock,
                    isPaused: session.isPaused,
                    levels: WaveformDownsample.bars(from: session.levels, count: 5),
                    inputDevices: inputDevices,
                    selectedDeviceUID: settings.preferredInputUID,
                    onSelectDevice: { uid in
                        settings.preferredInputUID = uid
                        session.setPreferredInputUID(uid)
                    },
                    onPauseToggle: { stores?.togglePause() },
                    onStop: { stores?.stopRecording() }
                )
                .padding(.bottom, 16)
            }
        }
        .task {
            if let record {
                notes = library.timedNotes(for: record)
            }
            refreshInputDevices()
        }
        .onDisappear {
            if let deviceListListener {
                AudioInputDevices.removeDeviceListListener(deviceListListener)
            }
            deviceListListener = nil
        }
        .accessibilityElement(children: .contain)
        .axID(.recordingView)
    }

    // MARK: Content column

    private func recordingContent(for record: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(for: record)
                notesList
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 48)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            noteInput(for: record)
        }
    }

    private func header(for record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                EditableTitle(
                    text: record.meeting.title,
                    font: .system(size: 22, weight: .bold),
                    foreground: Tokens.textPrimary,
                    showsDashedUnderline: true,
                    hint: "Click to rename",
                    onCommit: { newTitle in library.rename(record, to: newTitle) }
                )
                .axID(.recordingTitleField)
            }
            Text(metaLine(for: record))
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textPrimary.opacity(0.45))
        }
    }

    private var notesList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(notes) { note in
                HStack(alignment: .top, spacing: 10) {
                    Text(ElapsedLabel.format(seconds: Int(note.offset)))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Tokens.textPrimary.opacity(0.85))
                        .padding(.vertical, 1)
                        .padding(.horizontal, 6)
                        .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                    Text(note.text)
                        .font(.system(size: 13.5))
                        .lineSpacing(7)
                        .foregroundStyle(Tokens.textPrimary.opacity(0.88))
                }
            }
        }
    }

    private func noteInput(for record: MeetingRecord) -> some View {
        // Only the placeholder string needs to tick with elapsed time; the
        // field itself must stay outside any per-second-rebuilt view so a
        // focused TextField (and its cursor/selection) survives every tick.
        // `placeholderTick` is a plain @State counter bumped once a second by
        // the `.task` below, which only forces `notePlaceholder` to
        // recompute — it doesn't touch the TextField's identity.
        TextField("", text: $noteText, prompt: Text(notePlaceholder))
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(Tokens.textPrimary)
            .focused($noteFieldFocused)
            .onSubmit { commitNote(for: record) }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusRow))
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 40)
            .padding(.top, 10)
            .padding(.bottom, 96)
            .background(Tokens.surface)
            .axID(.recordingNotesField)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    placeholderTick &+= 1
                }
            }
    }

    private var notePlaceholder: String {
        _ = placeholderTick // dependency only — forces recompute once a second
        let offset = session.currentOffset ?? 0
        return "Type a note — it lands at \(ElapsedLabel.format(seconds: Int(offset))) in the transcript…"
    }

    private func commitNote(for record: MeetingRecord) {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let offset = session.currentOffset ?? 0
        library.addTimedNote(trimmed, at: offset, in: record)
        notes.append(TimedNote(offset: offset, text: trimmed))
        noteText = ""
    }

    // MARK: Meta line

    private func metaLine(for record: MeetingRecord) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let dateText = dateFormatter.string(from: record.meeting.date)
        let timeText = timeFormatter.string(from: record.meeting.date)
        return "\(dateText) · started \(timeText) · \(sourcesText)"
    }

    /// "mic" / "mic + system audio" per the session's live capture flags.
    /// There's no per-meeting record of which call app was detected today,
    /// so unlike the design spec's "name the call app when known" this
    /// always reads "system audio" for the combined case.
    private var sourcesText: String {
        if session.micUnavailable { return "system audio" }
        if session.systemAudioUnavailable { return "mic" }
        return "mic + system audio"
    }

    // MARK: Saving status

    private var savingStatus: some View {
        Group {
            if showingSavingConfirmation {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Audio saving to \(savingFolderLabel)")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Tokens.successGreen.opacity(0.45))
            } else {
                Text("Saving to \(savingFolderLabel)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .help("Audio is saved to disk continuously while recording — nothing is lost if Recap quits.")
        .task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                showingSavingConfirmation = false
            }
        }
    }

    private var savingFolderLabel: String {
        let path = settings.saveRootPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tildePath = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        if tildePath == "~/Recap" { return "~/Recap" }
        return (path as NSString).lastPathComponent
    }

    // MARK: Input devices

    private func refreshInputDevices() {
        inputDevices = AudioInputDevices.inputDevices()
        deviceListListener = AudioInputDevices.addDeviceListListener(queue: .main) {
            Task { @MainActor in inputDevices = AudioInputDevices.inputDevices() }
        }
    }
}
