import RecapCore
import SwiftUI

/// The meeting editor (design mock 1a). M2 ships the header + notes editing;
/// the recording pill and live transcript arrive with capture (M3+).
struct MeetingDetailView: View {
    var record: MeetingRecord
    @Environment(LibraryStore.self) private var library
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 40)
                .padding(.top, 26)
            TextEditor(text: $notes)
                .font(Tokens.body)
                .foregroundStyle(Tokens.textBody)
                .lineSpacing(7)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 34)
                .padding(.top, 16)
        }
        .background(.white)
        .task(id: record.meeting.id) {
            notes = library.loadNotes(for: record)
        }
        .onChange(of: notes) {
            library.notesChanged(notes, in: record)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.meeting.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textSecondary)
                OnDeviceBadge()
            }
            Text(record.meeting.title)
                .font(Tokens.pageTitle)
                .kerning(-0.4)
                .foregroundStyle(Tokens.textPrimary)
            if !record.meeting.attendees.isEmpty {
                HStack(spacing: 6) {
                    ForEach(record.meeting.attendees, id: \.self) { attendee in
                        Text(attendee)
                            .font(Tokens.caption)
                            .foregroundStyle(.black.opacity(0.6))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Tokens.chipBackground, in: Capsule())
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}
