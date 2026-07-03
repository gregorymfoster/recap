import Foundation
import RecapCore

/// Buckets meetings into date-based sections for the Library list (Today,
/// Yesterday, This Week, This Month, then a "MMMM yyyy" section per older
/// month). Pure and calendar-injected so it's fully testable — no `Date.now`,
/// no `Calendar.current` inside.
public enum MeetingGrouping {
    public struct Section: Equatable, Sendable {
        public var id: String
        public var title: String
        public var records: [MeetingRecord]

        public init(id: String, title: String, records: [MeetingRecord]) {
            self.id = id
            self.title = title
            self.records = records
        }
    }

    /// Groups `records` (assumed already sorted the way the caller wants
    /// within-section order to read) into sections, preserving input order
    /// within each bucket.
    public static func sections(_ records: [MeetingRecord], now: Date, calendar: Calendar) -> [Section] {
        guard !records.isEmpty else { return [] }

        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let monthStart = calendar.dateInterval(of: .month, for: now)?.start
        else {
            // Calendar math failing is not something a real Gregorian/etc.
            // calendar does; fall back to a single bucket rather than crash.
            return [Section(id: "all", title: "All meetings", records: records)]
        }

        var order: [String] = []
        var buckets: [String: (title: String, records: [MeetingRecord])] = [:]
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"
        monthFormatter.calendar = calendar

        func append(_ record: MeetingRecord, id: String, title: String) {
            if buckets[id] == nil {
                order.append(id)
                buckets[id] = (title, [])
            }
            buckets[id]!.records.append(record)
        }

        for record in records {
            let date = record.meeting.date
            let day = calendar.startOfDay(for: date)
            if day == today {
                append(record, id: "today", title: "Today")
            } else if day == yesterday {
                append(record, id: "yesterday", title: "Yesterday")
            } else if date >= weekStart {
                append(record, id: "this-week", title: "This Week")
            } else if date >= monthStart {
                append(record, id: "this-month", title: "This Month")
            } else {
                let monthAnchor = calendar.dateInterval(of: .month, for: date)?.start ?? date
                let id = "month-\(monthAnchor.timeIntervalSinceReferenceDate)"
                append(record, id: id, title: monthFormatter.string(from: date))
            }
        }

        return order.map { id in
            let bucket = buckets[id]!
            return Section(id: id, title: bucket.title, records: bucket.records)
        }
    }
}
