import RecapCore
import RecapTranscription
import SwiftUI

/// The Library home screen (design mock 1c): header with Record button,
/// meeting cards with processing status, summary preview for the latest
/// enhanced meeting.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(MeetingSessionStore.self) private var session
    @Environment(WhisperModelManager.self) private var models

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 20)
                LazyVStack(spacing: 10) {
                    ForEach(library.meetings) { record in
                        MeetingRow(record: record)
                            .onTapGesture { library.selectedMeetingID = record.meeting.id }
                    }
                }
            }
            .padding(28)
        }
        .background(.white)
    }

    private var header: some View {
        HStack {
            Text("Library")
                .font(Tokens.sectionTitle)
                .foregroundStyle(Tokens.textPrimary)
                .kerning(-0.3)
            Spacer()
            Button {
                guard !session.isRecording, let record = library.startNewMeeting() else { return }
                Task {
                    await session.start(record: record, engine: models.activeEngine())
                    if session.permissionDenied {
                        library.markError(record, message: "Microphone access denied")
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text("Record")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Tokens.recordRed, in: RoundedRectangle(cornerRadius: Tokens.radiusButton))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

private struct MeetingRow: View {
    var record: MeetingRecord
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            iconTile
            VStack(alignment: .leading, spacing: 2) {
                Text(record.meeting.title)
                    .font(Tokens.rowTitle)
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                Text(record.meeting.metaLine)
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer(minLength: 12)
            MeetingStatusView(status: record.meeting.status)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .fill(hovering ? Tokens.subtleBackground : .white)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusCard))
        .onHover { hovering = $0 }
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(tint.opacity(0.12))
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: record.meeting.attendees.count > 1 ? "person.2.fill" : "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
            }
    }

    private var tint: Color {
        let palette: [Color] = [Tokens.accentBlue, Color(red: 0x8E / 255, green: 0x7C / 255, blue: 0xC3 / 255), Tokens.successGreen, .orange]
        return palette[abs(record.meeting.id.hashValue) % palette.count]
    }
}

#Preview {
    LibraryView()
        .environment(LibraryStore.fixture())
        .frame(width: 820, height: 620)
}
