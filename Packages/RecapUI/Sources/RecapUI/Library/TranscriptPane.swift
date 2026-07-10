import RecapCore
import SwiftUI

/// Full-width, time-ordered rendering of a saved meeting's transcript
/// interleaved with the user's timed notes (design mock 10b/11d: "the
/// transcript IS the page"). Embedded directly in `MeetingDetailView`'s
/// single page `ScrollView` — this view lays out its rows in a plain
/// `LazyVStack` rather than owning its own `ScrollView`.
///
/// Live-recording rendering (partial utterances, pipeline-health badges,
/// live empty states) moved out entirely: recording now routes to its own
/// screen, so this view only ever renders a finished meeting's saved
/// transcript.
struct TranscriptPane: View {
    /// Utterances and timed notes already interleaved by
    /// `TranscriptMerge.merged(utterances:notes:)`.
    var items: [TranscriptMerge.Item]
    /// Per-meeting speaker renames (design handoff v2 §8e), keyed by
    /// diarization label ("S1" → "Maya"). Defaults empty so previews just
    /// show "Speaker N".
    var speakerNames: [String: String] = [:]
    /// Meeting attendees, used to build rename-popover suggestion chips
    /// (alongside "Me"). Defaults empty — the popover still works, just
    /// without suggestions.
    var attendees: [String] = []
    /// Persists a rename for `speakerID` within this meeting. Nil disables
    /// the rename affordance entirely.
    var onRenameSpeaker: ((String, String) -> Void)?

    /// Speaker ID whose rename popover is currently open, if any.
    @State private var renamingSpeakerID: String?
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        if items.isEmpty {
            Text("No transcript yet")
                .font(Tokens.transcript)
                .foregroundStyle(Tokens.textTertiary)
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    switch item {
                    case .utterance(let utterance):
                        utteranceRow(utterance)
                    case .note(let note):
                        noteRow(note)
                    }
                }
            }
        }
    }

    private func utteranceRow(_ utterance: Utterance) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let speakerID = utterance.speakerID {
                    speakerNameLabel(for: speakerID)
                }
                Spacer(minLength: 8)
                Text(timestamp(utterance.start))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Tokens.textPrimary.opacity(0.3))
            }
            Text(utterance.text)
                .font(.system(size: 13.5))
                .lineSpacing(7)
                .foregroundStyle(Tokens.textPrimary.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A user note pinned at `note.offset`: a small tabular-figure timestamp
    /// chip plus the note's text, styled distinctly (italic, quieter) so it
    /// reads as an annotation rather than spoken dialogue.
    private func noteRow(_ note: TimedNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timestamp(note.offset))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Tokens.textPrimary.opacity(0.55))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: 4))
            Text(note.text)
                .font(.system(size: 13).italic())
                .foregroundStyle(Tokens.textPrimary.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Speaker name in a transcript row. When renaming is available, unnamed
    /// speakers get a dashed underline affordance and open the rename
    /// popover on click (§8e). Renamed speakers just show the custom name;
    /// the popover is still reachable so a rename can be corrected later.
    @ViewBuilder
    private func speakerNameLabel(for speakerID: String) -> some View {
        let name = displayName(for: speakerID)
        let isCustomName = speakerNames[speakerID]?.isEmpty == false
        let canRename = onRenameSpeaker != nil

        Text(name)
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(color(for: speakerID))
            .overlay(alignment: .bottom) {
                if canRename, !isCustomName {
                    Rectangle()
                        .fill(Tokens.textTertiary.opacity(0.5))
                        .frame(height: 1)
                        .mask(dashedLine)
                        .offset(y: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard canRename else { return }
                beginRenaming(speakerID)
            }
            .popover(isPresented: renamingBinding(for: speakerID), arrowEdge: .bottom) {
                renamePopover(for: speakerID)
            }
            .axID(.transcriptSpeakerLabel(speakerID))
    }

    /// Dashed-underline mask (design handoff v2 §8e: `1px dashed rgba(255,255,255,.3)`).
    private var dashedLine: some View {
        HStack(spacing: 2) {
            ForEach(0..<20, id: \.self) { _ in
                Rectangle().frame(width: 2, height: 1)
            }
        }
    }

    private func renamingBinding(for speakerID: String) -> Binding<Bool> {
        Binding(
            get: { renamingSpeakerID == speakerID },
            set: { isPresented in
                if !isPresented, renamingSpeakerID == speakerID {
                    renamingSpeakerID = nil
                }
            }
        )
    }

    private func beginRenaming(_ speakerID: String) {
        renameDraft = speakerNames[speakerID] ?? ""
        renamingSpeakerID = speakerID
        renameFieldFocused = true
    }

    /// "Rename Speaker N" popover (§8e): focused text field, suggestion chips
    /// from attendees + "Me", segment count, blue Rename button. Return
    /// submits the same as clicking Rename.
    private func renamePopover(for speakerID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename \(displayName(for: speakerID))")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)

            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .focused($renameFieldFocused)
                .onSubmit { commitRename(speakerID) }
                .axID(.transcriptSpeakerRenameField)

            if !suggestionChips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(suggestionChips, id: \.self) { suggestion in
                        Button {
                            renameDraft = suggestion
                        } label: {
                            Text(suggestion)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Tokens.textBody.opacity(0.85))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Tokens.chipBackground, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 6) {
                Text("Renames all \(segmentCount(for: speakerID)) segments")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                Spacer()
                Button("Rename") { commitRename(speakerID) }
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accentBlue)
                    .controlSize(.small)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .axID(.transcriptSpeakerRenameConfirm)
            }
        }
        .padding(13)
        .frame(width: 250)
    }

    private func commitRename(_ speakerID: String) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRenameSpeaker?(speakerID, trimmed)
        renamingSpeakerID = nil
    }

    /// Suggestion chips: meeting attendees + "Me" (design handoff v2 §8e).
    private var suggestionChips: [String] {
        var chips = attendees
        chips.append("Me")
        return chips
    }

    /// Number of utterances attributed to `speakerID` — shown in the popover
    /// caption so a rename's blast radius is clear before committing.
    private func segmentCount(for speakerID: String) -> Int {
        utterances.filter { $0.speakerID == speakerID }.count
    }

    private var utterances: [Utterance] {
        items.compactMap { item in
            if case .utterance(let utterance) = item { return utterance }
            return nil
        }
    }

    // Naming/timestamp conventions live in TranscriptFormatter (RecapCore) so
    // the on-screen transcript and clipboard copies never drift apart.

    private func displayName(for speakerID: String) -> String {
        TranscriptFormatter.speakerDisplayName(speakerID, speakerNames: speakerNames)
    }

    private func color(for speakerID: String) -> Color {
        guard let number = TranscriptFormatter.speakerNumber(speakerID), number >= 1 else {
            return Tokens.textSecondary
        }
        return Tokens.speakerPalette[(number - 1) % Tokens.speakerPalette.count]
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        TranscriptFormatter.timestamp(seconds)
    }
}

#Preview("Saved") {
    ScrollView {
        TranscriptPane(
            items: TranscriptMerge.merged(
                utterances: [
                    Utterance(speakerID: "S1", start: 0, end: 4, text: "Hello everyone, thanks for joining."),
                    Utterance(speakerID: "S1", start: 4, end: 9, text: "Today we're walking through the Q3 roadmap and the onboarding revamp."),
                    Utterance(speakerID: "S2", start: 9, end: 14, text: "Sounds good — I have the metrics from last week ready to share."),
                ],
                notes: [TimedNote(offset: 6, text: "Ask about the onboarding timeline.")]
            )
        )
        .padding(20)
    }
    .frame(width: 620, height: 500)
}

#Preview("Empty") {
    TranscriptPane(items: [])
        .padding(20)
        .frame(width: 620, height: 200)
}
