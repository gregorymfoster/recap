import Testing
@testable import RecapUI

@Suite struct RecoveredRowTitleTests {
    @Test func realTitleIsKept() {
        #expect(RecoveredRowTitle.display(for: "Design crit — mobile") == "Design crit — mobile")
    }

    @Test func emptyTitleFallsBackToRecoveredRecording() {
        #expect(RecoveredRowTitle.display(for: "") == "Recovered recording")
    }

    @Test func whitespaceOnlyTitleFallsBackToRecoveredRecording() {
        #expect(RecoveredRowTitle.display(for: "   ") == "Recovered recording")
    }

    @Test func defaultPlaceholderTitleFallsBackToRecoveredRecording() {
        #expect(RecoveredRowTitle.display(for: "Untitled meeting") == "Recovered recording")
    }
}
