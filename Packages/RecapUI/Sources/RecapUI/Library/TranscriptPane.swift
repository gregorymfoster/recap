import RecapCore
import SwiftUI

/// Left pane of the split meeting view (design mock 1b): live or saved
/// transcript with the in-progress utterance at 40% opacity.
///
/// Playback follow, click-to-seek, and speaker avatars (design handoff v2
/// §6b/§8d) read `PlaybackStore` and `LibraryStore` from the environment
/// rather than as init parameters — the initializer is a pinned surface
/// another package's `MeetingDetailView` builds against, so it must not
/// change shape. Both environment values are optional-tolerant: previews (or
/// any future host) that don't inject them just get the pre-playback look.
struct TranscriptPane: View {
    var utterances: [Utterance]
    var partial: Utterance?
    var isLive: Bool
    /// Health of the live pipeline, when `isLive` — nil for saved meetings.
    var liveState: LiveState?
    var onDownloadStreamingModel: (() -> Void)?
    /// Per-meeting speaker renames (design handoff v2 §8e), keyed by
    /// diarization label ("S1" → "Maya"). Defaults empty so previews and any
    /// host that doesn't load renames just show "Speaker N".
    var speakerNames: [String: String] = [:]
    /// Meeting attendees, used to build rename-popover suggestion chips
    /// (alongside "Me"). Defaults empty — the popover still works, just
    /// without suggestions.
    var attendees: [String] = []
    /// Persists a rename for `speakerID` within this meeting. Nil (the
    /// default) disables the rename affordance entirely — used for live
    /// transcripts, where renaming isn't offered.
    var onRenameSpeaker: ((String, String) -> Void)?

    @Environment(PlaybackStore.self) private var playback: PlaybackStore?
    @Environment(LibraryStore.self) private var library: LibraryStore?

    /// Row currently under the pointer — swaps its avatar for a ▶ glyph and
    /// tints the row (§8d), only meaningful when `playback?.hasAudio` is true.
    @State private var hoveredUtteranceID: Utterance.ID?
    /// Debounces auto-scroll after a manual scroll so playback-follow doesn't
    /// fight the user. Simple wall-clock check rather than a running timer —
    /// no per-frame work, just a timestamp compared on the next position tick.
    @State private var lastManualScrollAt: Date?
    /// Stamped by `followPlayback` right before its own `scrollTo`, so the
    /// offset change *we* cause isn't misread as the user scrolling away.
    @State private var lastAutoScrollAt: Date?
    /// Speaker ID whose rename popover is currently open, if any.
    @State private var renamingSpeakerID: String?
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool

    private static let manualScrollGrace: TimeInterval = 3
    private static let autoScrollSettle: TimeInterval = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 10)

            if utterances.isEmpty && partial == nil {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcriptList
            }

            transcribingFooter
        }
        .background(Tokens.subtleBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(isLive ? "LIVE TRANSCRIPT" : "TRANSCRIPT")
                .font(Tokens.microLabel)
                .kerning(0.5)
                .foregroundStyle(Tokens.textTertiary)
            if isLive {
                liveStatusBadge
            } else {
                OnDeviceBadge(label: "on-device")
            }
            Spacer()
            if !utterances.isEmpty {
                // Confirmed utterances only — the in-progress partial is
                // deliberately excluded from copies.
                CopyButton(help: "Copy transcript") {
                    TranscriptFormatter.plainText(utterances: utterances, speakerNames: speakerNames)
                }
                .axID(.transcriptCopyButton)
            }
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // No standalone speaker-change label — every row carries
                    // its own avatar + name per design handoff v2 §6b.
                    ForEach(Array(utterances.enumerated()), id: \.element.id) { index, utterance in
                        row(utterance, isCurrent: index == currentUtteranceIndex)
                            .id(utterance.id)
                    }
                    if let partial {
                        // Left at 0.4 for both modes (see Milestone K plan §4);
                        // flagged for the visual dark-mode pass — may need a
                        // dark-only bump toward 0.5 if it reads too faint.
                        row(partial, isCurrent: false)
                            .opacity(0.4)
                            .id("partial")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .background(scrollDetector)
            }
            .coordinateSpace(name: "transcriptScroll")
            .onChange(of: utterances.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: partial?.text) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: currentUtteranceIndex) { _, newIndex in
                followPlayback(to: newIndex, proxy: proxy)
            }
        }
    }

    /// Invisible probe that flips `lastManualScrollAt` when the scroll offset
    /// moves for a reason other than our own `scrollTo` calls. SwiftUI has no
    /// direct "user scrolled" signal on macOS `ScrollView`, so this uses a
    /// `GeometryReader` position read — cheap (one geometry read per layout
    /// pass, no timer) and only feeds a stored timestamp, never a loop.
    private var scrollDetector: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.frame(in: .named("transcriptScroll")).minY) { oldValue, newValue in
                    guard isFollowingPlayback, abs(newValue - oldValue) > 1 else { return }
                    // Offset moved because followPlayback just scrolled —
                    // not the user; don't start the manual-scroll grace.
                    if let lastAutoScrollAt, Date.now.timeIntervalSince(lastAutoScrollAt) < Self.autoScrollSettle {
                        return
                    }
                    lastManualScrollAt = .now
                }
        }
    }

    /// True once we've established the transcript is being driven by
    /// playback (auto-scroll only happens then, per §8d: "only auto-scroll
    /// while playing").
    private var isFollowingPlayback: Bool {
        playback?.isPlaying == true
    }

    private func followPlayback(to index: Int?, proxy: ScrollViewProxy) {
        guard isFollowingPlayback, let index, utterances.indices.contains(index) else { return }
        if let lastManualScrollAt, Date.now.timeIntervalSince(lastManualScrollAt) < Self.manualScrollGrace {
            return
        }
        lastAutoScrollAt = .now
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(utterances[index].id, anchor: .center)
        }
    }

    /// Small header badge showing exactly where the live pipeline stands —
    /// replaces the plain "on-device" badge while recording so loading,
    /// live, missing-model, and failure states are visually distinct instead
    /// of all reading as an indefinite "Listening…".
    @ViewBuilder
    private var liveStatusBadge: some View {
        switch liveState {
        case .live, nil:
            HStack(spacing: 4) {
                Circle()
                    .fill(Tokens.successGreen)
                    .frame(width: 6, height: 6)
                Text("Live")
                    .font(Tokens.microLabel)
            }
            .foregroundStyle(Tokens.successGreenText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Tokens.successGreenTint, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
        case .loadingModel:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Loading live transcription…")
                    .font(Tokens.microLabel)
            }
            .foregroundStyle(Tokens.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
        case .noModelInstalled:
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 9, weight: .semibold))
                Text("No transcription model installed")
                    .font(Tokens.microLabel)
            }
            .foregroundStyle(Tokens.warningAmberText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Tokens.warningAmberTint, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Live transcription unavailable")
                    .font(Tokens.microLabel)
            }
            .foregroundStyle(Tokens.warningAmberText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Tokens.warningAmberTint, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch (isLive, liveState) {
        case (true, .noModelInstalled):
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Tokens.textTertiary)
                Text("No transcription model installed")
                    .font(Tokens.transcript)
                    .foregroundStyle(Tokens.textSecondary)
                Text("The full transcript will still be created after the meeting once a model is installed.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
                if let onDownloadStreamingModel {
                    Button("Download") { onDownloadStreamingModel() }
                        .buttonStyle(.borderedProminent)
                        .tint(Tokens.accentBlue)
                        .controlSize(.small)
                        .axID(.transcriptDownloadModelButton)
                }
            }
        case (true, .failed):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Tokens.textTertiary)
                Text("Live transcription unavailable")
                    .font(Tokens.transcript)
                    .foregroundStyle(Tokens.textSecondary)
                Text("The full transcript will still be created after the meeting.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        case (true, .loadingModel):
            VStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading live transcription…")
                    .font(Tokens.transcript)
                    .foregroundStyle(Tokens.textTertiary)
            }
        case (true, .live), (true, nil):
            VStack(spacing: 6) {
                Text("Listening…")
                    .font(Tokens.transcript)
                    .foregroundStyle(Tokens.textTertiary)
                Text("Transcript appears a few seconds behind the conversation.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        case (false, _):
            Text("No transcript yet")
                .font(Tokens.transcript)
                .foregroundStyle(Tokens.textTertiary)
        }
    }

    private func row(_ utterance: Utterance, isCurrent: Bool) -> some View {
        let isHovered = hoveredUtteranceID == utterance.id
        let seekable = playback?.hasAudio == true

        return HStack(alignment: .top, spacing: 10) {
            avatar(for: utterance, isHovered: isHovered && seekable)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let speakerID = utterance.speakerID {
                        speakerNameLabel(for: speakerID)
                    }
                    Spacer()
                    Text(timestamp(utterance.start))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(isCurrent ? Tokens.accentBlue : Tokens.textTertiary)
                }
                Text(utterance.text)
                    .font(Tokens.transcript)
                    .lineSpacing(4)
                    .foregroundStyle(Tokens.textBody.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .padding(.leading, isCurrent ? 6 : 8)
        .background(rowBackground(isCurrent: isCurrent, isHovered: isHovered && seekable))
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle()
                    .fill(Tokens.accentBlue)
                    .frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusRow))
        .contentShape(Rectangle())
        .onHover { hovering in
            guard seekable else { return }
            hoveredUtteranceID = hovering ? utterance.id : nil
        }
        .onTapGesture {
            guard seekable else { return }
            playback?.seek(to: utterance.start)
        }
    }

    @ViewBuilder
    private func rowBackground(isCurrent: Bool, isHovered: Bool) -> some View {
        if isCurrent {
            Tokens.accentBlue.opacity(0.1)
        } else if isHovered {
            Tokens.chipBackground.opacity(0.6)
        } else {
            Color.clear
        }
    }

    /// 22pt round avatar with speaker initials, colored from
    /// `Tokens.speakerPalette`. Swaps to a ▶ glyph on hover when the row is
    /// seekable (§8d).
    @ViewBuilder
    private func avatar(for utterance: Utterance, isHovered: Bool) -> some View {
        let tint = utterance.speakerID.map(color(for:)) ?? Tokens.textTertiary
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
            if isHovered {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                Text(initials(for: utterance.speakerID))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 22, height: 22)
    }

    /// "S1" → "S1" — first letters of the display name ("Speaker 1"),
    /// uppercased, max two characters.
    private func initials(for speakerID: String?) -> String {
        guard let speakerID else { return "?" }
        let name = displayName(for: speakerID)
        let letters = name
            .split(separator: " ")
            .compactMap { $0.first }
            .map(String.init)
            .joined()
            .uppercased()
        if letters.isEmpty { return "?" }
        return String(letters.prefix(2))
    }

    /// "S1" → "Speaker 1", colored consistently per speaker (mock 1b).
    private func speakerLabel(_ speakerID: String) -> some View {
        Text(displayName(for: speakerID))
            .font(Tokens.microLabel)
            .kerning(0.4)
            .foregroundStyle(color(for: speakerID))
            .padding(.leading, 40)  // aligns with the text column (22pt avatar + spacing)
    }

    /// Speaker name in a transcript row. When renaming is available (saved
    /// transcripts only — never live), unnamed speakers get a dashed
    /// underline affordance and open the rename popover on click (§8e).
    /// Renamed speakers just show the custom name; the popover is still
    /// reachable so a rename can be corrected later.
    @ViewBuilder
    private func speakerNameLabel(for speakerID: String) -> some View {
        let name = displayName(for: speakerID)
        let isCustomName = speakerNames[speakerID]?.isEmpty == false
        let canRename = !isLive && onRenameSpeaker != nil

        Text(name)
            .font(.system(size: 11.5, weight: .semibold))
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

    /// Footer shown only while the meeting behind this pane is actively
    /// transcribing: "Transcribing · N%" + a thin progress bar (§6b).
    ///
    /// `TranscriptPane`'s initializer can't grow a new parameter (pinned API
    /// another package builds against), so progress is read from
    /// `LibraryStore` — `selectedMeetingID` cross-referenced against
    /// `meetings` gives the per-meeting `.transcribing(progress:)` fraction
    /// that's already live-updated by the processing queue. If the pane is
    /// hosted without a `LibraryStore` in the environment (e.g. an isolated
    /// preview), the footer simply doesn't show — no crash, no stale guess.
    @ViewBuilder
    private var transcribingFooter: some View {
        if let progress = transcribingProgress {
            VStack(spacing: 6) {
                HStack {
                    Text("Transcribing · \(Int((progress * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Tokens.accentBlue)
                    Spacer()
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Tokens.accentBlue)
                    .frame(height: 3)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var transcribingProgress: Double? {
        guard let library, let id = library.selectedMeetingID,
              let record = library.record(for: id),
              case .transcribing(let progress) = record.meeting.status
        else { return nil }
        return progress
    }

    /// Index of the utterance currently under the playhead, or nil when
    /// there's no audio loaded or position precedes the first utterance.
    private var currentUtteranceIndex: Int? {
        guard let playback, playback.hasAudio else { return nil }
        return TranscriptPlaybackIndex.currentIndex(for: playback.position, in: utterances)
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

#Preview("Live") {
    TranscriptPane(
        utterances: [
            Utterance(speakerID: "S1", start: 0, end: 4, text: "Hello everyone, thanks for joining."),
            Utterance(speakerID: "S1", start: 4, end: 9, text: "Today we're walking through the Q3 roadmap and the onboarding revamp."),
            Utterance(speakerID: "S2", start: 9, end: 14, text: "Sounds good — I have the metrics from last week ready to share."),
        ],
        partial: Utterance(start: 14, end: 16, text: "Maya, do you want to start with"),
        isLive: true,
        liveState: .live
    )
    .environment(PlaybackStore())
    .environment(LibraryStore.fixture())
    .frame(width: 420, height: 500)
}

#Preview("Saved with playback") {
    let playback = PlaybackStore()
    return TranscriptPane(
        utterances: [
            Utterance(speakerID: "S1", start: 0, end: 4, text: "Hello everyone, thanks for joining."),
            Utterance(speakerID: "S1", start: 4, end: 9, text: "Today we're walking through the Q3 roadmap and the onboarding revamp."),
            Utterance(speakerID: "S2", start: 9, end: 14, text: "Sounds good — I have the metrics from last week ready to share."),
        ],
        partial: nil,
        isLive: false,
        liveState: nil
    )
    .environment(playback)
    .environment(LibraryStore.fixture())
    .frame(width: 420, height: 500)
}

#Preview("No model installed") {
    TranscriptPane(utterances: [], partial: nil, isLive: true, liveState: .noModelInstalled, onDownloadStreamingModel: {})
        .environment(PlaybackStore())
        .environment(LibraryStore.fixture())
        .frame(width: 420, height: 500)
}

#Preview("Loading") {
    TranscriptPane(utterances: [], partial: nil, isLive: true, liveState: .loadingModel)
        .environment(PlaybackStore())
        .environment(LibraryStore.fixture())
        .frame(width: 420, height: 500)
}

#Preview("Failed") {
    TranscriptPane(utterances: [], partial: nil, isLive: true, liveState: .failed(reason: "load error"))
        .environment(PlaybackStore())
        .environment(LibraryStore.fixture())
        .frame(width: 420, height: 500)
}
