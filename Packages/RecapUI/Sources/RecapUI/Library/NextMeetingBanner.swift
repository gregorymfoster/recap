import RecapCore
import SwiftUI

/// The Library's "next meeting starting soon" banner (design mock 10a/11c):
/// a single, high-signal full-width row shown only when calendar access is
/// authorized and the next event starts within 30 minutes
/// (`UpcomingStore.imminentEvent(now:)`). Replaces the old always-present
/// "Upcoming" agenda section (`UpcomingSection`, deleted) — never an empty
/// section, hidden entirely when access is denied or nothing is imminent.
struct NextMeetingBanner: View {
    var event: CalendarEventSnapshot
    var now: Date
    var onRecord: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.accentBlueLight)
            metaLine
            Spacer(minLength: 12)
            Button("Record", action: onRecord)
                .buttonStyle(.quietBlueOutline)
                .axID(.bannerRecordButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Tokens.accentBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Tokens.accentBlue.opacity(0.22), lineWidth: 1))
        .axID(.nextMeetingBanner)
    }

    /// "Design crit — mobile · 3:48 PM · in 18m" built as an
    /// `AttributedString` (not `Text` `+` concatenation, deprecated in macOS
    /// 26) so the countdown segment alone can carry the blue/semibold
    /// treatment and the clock segment can sit at 50% opacity.
    private var metaLine: some View {
        var title = AttributedString(event.title)
        title.foregroundColor = Tokens.textPrimary
        title.font = .system(size: 12.5, weight: .semibold)

        var mid = AttributedString(" · \(UpNextEvent.clockTime(for: event)) · ")
        mid.foregroundColor = Tokens.textPrimary.opacity(0.5)
        mid.font = .system(size: 12)

        var countdown = AttributedString(UpNextEvent.relativeTime(for: event, now: now))
        countdown.foregroundColor = Tokens.accentBlue
        countdown.font = .system(size: 12, weight: .semibold)

        return Text(title + mid + countdown)
            .lineLimit(1)
    }
}

#Preview {
    NextMeetingBanner(
        event: CalendarEventSnapshot(
            id: "preview", title: "Design crit — mobile",
            start: Date.now.addingTimeInterval(18 * 60), end: Date.now.addingTimeInterval(18 * 60 + 45 * 60),
            otherAttendees: ["Maya Chen", "Priya Patel"], hasConferenceURL: true, conferenceProvider: "Zoom"
        ),
        now: .now,
        onRecord: {}
    )
    .padding(24)
    .frame(width: 700)
    .background(Tokens.surface)
}
