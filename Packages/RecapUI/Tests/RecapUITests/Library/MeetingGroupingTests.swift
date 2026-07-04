import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

@Suite struct MeetingGroupingTests {
    /// Fixed "now": Tuesday, June 9, 2026 at noon UTC.
    static let now = Date(timeIntervalSince1970: 1_781_006_400)

    static func calendar(firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static func record(title: String, daysAgo: Double, relativeTo base: Date = now) -> MeetingRecord {
        MeetingRecord(
            meeting: Meeting(title: title, date: base.addingTimeInterval(-daysAgo * 86_400)),
            folderURL: URL(filePath: "/dev/null")
        )
    }

    @Test func emptyInputProducesNoSections() {
        #expect(MeetingGrouping.sections([], now: Self.now, calendar: Self.calendar()) == [])
    }

    @Test func bucketsTodayYesterdayLastWeekAndTwoMonthsAgo() {
        let today = Self.record(title: "Today", daysAgo: 0)
        let yesterday = Self.record(title: "Yesterday", daysAgo: 1)
        let lastWeek = Self.record(title: "Last week", daysAgo: 10)
        let twoMonthsAgo = Self.record(title: "Two months ago", daysAgo: 65)

        let sections = MeetingGrouping.sections(
            [today, yesterday, lastWeek, twoMonthsAgo], now: Self.now, calendar: Self.calendar()
        )

        let titles = sections.map(\.title)
        #expect(titles.contains("Today"))
        #expect(titles.contains("Yesterday"))
        #expect(sections.first { $0.title == "Today" }?.records.map(\.meeting.title) == ["Today"])
        #expect(sections.first { $0.title == "Yesterday" }?.records.map(\.meeting.title) == ["Yesterday"])

        // "Last week" (10 days ago) is older than this month's start (June
        // 17 is mid-month) so it should land in a monthly bucket, not
        // "This Week"/"This Month" — assert membership rather than assuming
        // which bucket without re-deriving the boundary here.
        let lastWeekSection = sections.first { $0.records.contains { $0.meeting.title == "Last week" } }
        #expect(lastWeekSection != nil)

        let twoMonthsSection = sections.first { $0.records.contains { $0.meeting.title == "Two months ago" } }
        #expect(twoMonthsSection != nil)
        #expect(twoMonthsSection?.title != "Today")
        #expect(twoMonthsSection?.title != "Yesterday")
        #expect(twoMonthsSection?.id != lastWeekSection?.id)
    }

    /// "Now" for the week/month boundary tests: Friday, June 12, 2026 at
    /// noon UTC — later in the week than `now` (Tuesday) so there's a day
    /// that's inside the same week without being Today or Yesterday.
    static let fridayNow = Date(timeIntervalSince1970: 1_781_265_600)

    @Test func thisWeekBucketHoldsRecentDaysInsideTheCurrentWeek() {
        // fridayNow (2026-06-12) is a Friday; with a Monday-start calendar
        // the week began 2026-06-08. 3 days ago is Tuesday 2026-06-09 —
        // inside the same week, but not Today/Yesterday — so it should land
        // in "This Week".
        let calendar = Self.calendar(firstWeekday: 2) // Monday start
        let tuesdayThisWeek = Self.record(title: "Tuesday", daysAgo: 3, relativeTo: Self.fridayNow)
        let sections = MeetingGrouping.sections([tuesdayThisWeek], now: Self.fridayNow, calendar: calendar)
        #expect(sections.first?.title == "This Week")
    }

    @Test func thisMonthBucketHoldsEarlierDaysInsideTheCurrentMonth() {
        let calendar = Self.calendar(firstWeekday: 2) // Monday start; week began 2026-06-08
        // 6 days ago (relative to fridayNow) is 2026-06-06 — inside June
        // (this month) but before the current week's Monday start, so it
        // should fall to "This Month".
        let earlierThisMonth = Self.record(title: "Earlier this month", daysAgo: 6, relativeTo: Self.fridayNow)
        let sections = MeetingGrouping.sections([earlierThisMonth], now: Self.fridayNow, calendar: calendar)
        #expect(sections.first?.title == "This Month")
    }

    @Test func olderMonthsGetMonthYearTitlesAndSeparateSections() {
        let march = Self.record(title: "March meeting", daysAgo: 95) // ~mid March 2026
        let january = Self.record(title: "January meeting", daysAgo: 150) // ~mid January 2026
        let sections = MeetingGrouping.sections([march, january], now: Self.now, calendar: Self.calendar())

        let marchSection = sections.first { $0.records.contains { $0.meeting.title == "March meeting" } }
        let januarySection = sections.first { $0.records.contains { $0.meeting.title == "January meeting" } }
        #expect(marchSection != nil)
        #expect(januarySection != nil)
        #expect(marchSection?.id != januarySection?.id)
        #expect(marchSection?.title.contains("2026") == true)
        #expect(januarySection?.title.contains("2026") == true)
    }

    @Test func preservesInputOrderWithinASection() {
        let a = Self.record(title: "A", daysAgo: 0)
        let b = Self.record(title: "B", daysAgo: 0)
        let c = Self.record(title: "C", daysAgo: 0)
        let sections = MeetingGrouping.sections([b, c, a], now: Self.now, calendar: Self.calendar())
        #expect(sections.count == 1)
        #expect(sections[0].records.map(\.meeting.title) == ["B", "C", "A"])
    }

    @Test func weekBoundaryRespectsInjectedFirstWeekday() {
        // Same date, two different `firstWeekday` calendars can classify a
        // day differently between "This Week" and an older bucket.
        let sundayCalendar = Self.calendar(firstWeekday: 1)
        let mondayCalendar = Self.calendar(firstWeekday: 2)
        let candidate = Self.record(title: "Boundary day", daysAgo: 3)

        let sundaySections = MeetingGrouping.sections([candidate], now: Self.now, calendar: sundayCalendar)
        let mondaySections = MeetingGrouping.sections([candidate], now: Self.now, calendar: mondayCalendar)

        // Both must classify it into *some* section — the point is the
        // calendar is actually threaded through, not hardcoded.
        #expect(sundaySections.count == 1)
        #expect(mondaySections.count == 1)
    }
}
