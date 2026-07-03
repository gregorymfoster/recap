import Foundation
import Testing
@testable import RecapCore

@Suite struct LibraryChangeBusTests {
    @Test func twoSubscribersBothReceivePostedChange() async {
        let bus = LibraryChangeBus()
        let meetingID = UUID()

        let stream1 = bus.changes()
        let stream2 = bus.changes()

        async let first = stream1.first { _ in true }
        async let second = stream2.first { _ in true }

        // Give both subscribers a moment to register before posting.
        try? await Task.sleep(nanoseconds: 50_000_000)
        bus.post(.meetingChanged(meetingID))

        let result1 = await first
        let result2 = await second

        guard case .meetingChanged(let id1) = result1, case .meetingChanged(let id2) = result2 else {
            Issue.record("Expected both subscribers to receive .meetingChanged")
            return
        }
        #expect(id1 == meetingID)
        #expect(id2 == meetingID)
    }
}
