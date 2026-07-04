import RecapCore
import SwiftUI

/// Pure display helpers for the Library's "Upcoming" section (design mock
/// 9a). Extracted so meta-line assembly and the date-tile strings are
/// testable without going through the view.
public enum UpcomingRowFormatting {
    /// Uppercase month abbreviation for the date tile ("JUL").
    public static func monthAbbreviation(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date).uppercased()
    }

    /// Day-of-month number for the date tile ("9").
    public static func dayNumber(for date: Date, calendar: Calendar = .current) -> String {
        String(calendar.component(.day, from: date))
    }

    /// "5 attendees" (`otherAttendees.count + 1`, including the user) — nil
    /// when the event has no other attendees, so the meta line omits the
    /// segment entirely rather than reading "1 attendee" for a solo block.
    public static func attendeeSummary(for event: CalendarEventSnapshot) -> String? {
        guard !event.otherAttendees.isEmpty else { return nil }
        let count = event.otherAttendees.count + 1
        return "\(count) attendee\(count == 1 ? "" : "s")"
    }

    /// One meta-line segment per non-nil component, joined with " · ":
    /// clock time, relative time, conference provider, attendee count.
    public static func metaLineComponents(for event: CalendarEventSnapshot, now: Date) -> [String] {
        [
            UpNextEvent.clockTime(for: event),
            UpNextEvent.relativeTime(for: event, now: now),
            event.conferenceProvider,
            attendeeSummary(for: event),
        ].compactMap(\.self)
    }
}

/// The Library's "Upcoming" section (design mock 9a): today's remaining
/// calendar events, rendered above the date-grouped meeting sections so each
/// is recordable in one click. Hidden entirely by the caller when calendar
/// access isn't available, there are no events, or a filter is active.
struct UpcomingSection: View {
    var events: [CalendarEventSnapshot]
    var isRecording: Bool
    var now: Date
    var onRecord: (CalendarEventSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            card
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("UPCOMING")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Tokens.textTertiary)
            Text("from Calendar")
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(Tokens.textTertiary.opacity(0.8))
        }
        .padding(.horizontal, 4)
    }

    /// Mirrors `LibraryView.groupCard`: rounded hairline-bordered container,
    /// divider inset past the leading tile.
    private var card: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index > 0 {
                    Divider()
                        .overlay(Tokens.hairline)
                        .padding(.leading, 53)
                }
                UpcomingRow(
                    event: event,
                    isImminent: UpcomingEvents.isImminent(event, now: now),
                    isRecording: isRecording,
                    now: now,
                    onRecord: { onRecord(event) }
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Tokens.subtleBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Tokens.cardStroke, lineWidth: 1)
        )
    }
}

/// A single Upcoming row (design mock 9a): 28×28 date tile, title, meta
/// line, trailing Record affordance. Geometry mirrors `LibraryView`'s
/// `MeetingRow`; the imminent event (< 30 min out) gets a blue-tinted
/// background, a blue countdown segment, and a solid Record pill instead of
/// the quiet text button.
private struct UpcomingRow: View {
    var event: CalendarEventSnapshot
    var isImminent: Bool
    var isRecording: Bool
    var now: Date
    var onRecord: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            dateTile
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                metaLine
            }
            Spacer(minLength: 12)
            if !isRecording {
                trailing
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(rowBackground)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isImminent {
            Tokens.accentBlue.opacity(hovering ? 0.13 : 0.08)
        } else if hovering {
            Tokens.chipBackground.opacity(0.6)
        } else {
            Color.clear
        }
    }

    private var dateTile: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(isImminent ? AnyShapeStyle(Tokens.accentBlue) : AnyShapeStyle(Tokens.chipBackground))
            .frame(width: 28, height: 28)
            .overlay {
                VStack(spacing: 0) {
                    Text(UpcomingRowFormatting.monthAbbreviation(for: event.start))
                        .font(.system(size: 6.5, weight: .semibold))
                        .kerning(0.3)
                    Text(UpcomingRowFormatting.dayNumber(for: event.start))
                        .font(.system(size: 12.5, weight: .semibold))
                }
                // stays: white tile text reads against both the blue
                // imminent fill and the neutral chip fill in both modes.
                .foregroundStyle(isImminent ? .white : Tokens.textSecondary)
            }
    }

    /// Clock time + relative time (the relative segment tinted blue and
    /// semibold when imminent) + optional conference provider + optional
    /// attendee count, each " · "-joined. Built as an `AttributedString` (not
    /// `Text` `+` concatenation, deprecated in macOS 26) so the countdown
    /// segment alone can carry a different color/weight.
    private var metaLine: some View {
        let clock = UpNextEvent.clockTime(for: event)
        let relative = UpNextEvent.relativeTime(for: event, now: now)
        let rest = [event.conferenceProvider, UpcomingRowFormatting.attendeeSummary(for: event)]
            .compactMap(\.self)
            .joined(separator: " · ")

        var text = AttributedString("\(clock) · ")
        text.foregroundColor = Tokens.textSecondary

        var countdown = AttributedString(relative)
        countdown.foregroundColor = isImminent ? Tokens.accentBlue : Tokens.textSecondary
        if isImminent { countdown.font = .system(size: 11, weight: .semibold) }
        text += countdown

        if !rest.isEmpty {
            var trailer = AttributedString(" · \(rest)")
            trailer.foregroundColor = Tokens.textSecondary
            text += trailer
        }

        return Text(text).font(.system(size: 11))
    }

    @ViewBuilder
    private var trailing: some View {
        if isImminent {
            Button(action: onRecord) {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 6, height: 6)
                    Text("Record")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                // stays: white dot/text on the red Record pill in both modes
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Tokens.recordRed, in: Capsule())
            }
            .buttonStyle(.plain)
            .axID(.upcomingRecordButton(event.id))
        } else {
            Button(action: onRecord) {
                Text("Record")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(hovering ? .white : Tokens.textSecondary)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background(hovering ? Tokens.recordRed : Color.clear, in: Capsule())
            }
            .buttonStyle(.plain)
            .axID(.upcomingRecordButton(event.id))
        }
    }
}
