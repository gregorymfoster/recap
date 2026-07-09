import Foundation
import Testing
@testable import RecapCore

@Suite struct NotesRenderingTests {
    @Test func bothEmptyProducesEmptyString() {
        #expect(NotesRendering.rawNotes(timed: [], freeform: "") == "")
    }

    @Test func onlyFreeformReturnsItTrimmed() {
        let result = NotesRendering.rawNotes(timed: [], freeform: "  - ship it  \n")
        #expect(result == "- ship it")
    }

    @Test func onlyTimedNotesReturnsJustTheLines() {
        let timed = [TimedNote(offset: 65, text: "Follow up with Sam")]
        let result = NotesRendering.rawNotes(timed: timed, freeform: "")
        #expect(result == "[1:05] Follow up with Sam")
    }

    @Test func timedThenBlankLineThenFreeform() {
        let timed = [TimedNote(offset: 5, text: "Kickoff")]
        let result = NotesRendering.rawNotes(timed: timed, freeform: "- action item")
        #expect(result == "[0:05] Kickoff\n\n- action item")
    }

    @Test func timedNotesAreSortedByOffsetRegardlessOfInputOrder() {
        let timed = [
            TimedNote(offset: 120, text: "Second"),
            TimedNote(offset: 5, text: "First"),
        ]
        let result = NotesRendering.rawNotes(timed: timed, freeform: "")
        #expect(result == "[0:05] First\n[2:00] Second")
    }

    @Test func offsetPastAnHourUsesHMMSSFormat() {
        let timed = [TimedNote(offset: 3_725, text: "Past the hour mark")]
        let result = NotesRendering.rawNotes(timed: timed, freeform: "")
        #expect(result == "[1:02:05] Past the hour mark")
    }

    @Test func negativeOffsetClampsToZero() {
        let timed = [TimedNote(offset: -3, text: "Clock skew guard")]
        let result = NotesRendering.rawNotes(timed: timed, freeform: "")
        #expect(result == "[0:00] Clock skew guard")
    }
}
