import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

/// Fixture-mode `loadNotes`/`loadEnhancedNotes` fallback precedence — mirrors
/// how `fixtureTranscripts` backs `loadTranscript` for records with no
/// `storage`. Exercised directly (not through `LibraryStore.fixture()`) so
/// these don't depend on `FixtureAudio` actually writing a file.
@MainActor
@Suite struct LibraryStoreFixtureNotesTests {
    static func record(_ title: String) -> MeetingRecord {
        MeetingRecord(
            meeting: Meeting(title: title, date: .now, status: .ready),
            folderURL: URL(filePath: "/dev/null")
        )
    }

    @Test func loadNotesReturnsCannedNotesForFixtureRecord() {
        let withNotes = Self.record("Weekly standup")
        let withoutNotes = Self.record("1:1 with Sam")
        let store = LibraryStore(
            fixtures: [withNotes, withoutNotes],
            notes: [withNotes.meeting.id: "- roundtable notes"]
        )
        #expect(store.loadNotes(for: withNotes) == "- roundtable notes")
    }

    @Test func loadNotesReturnsEmptyStringWhenNoFixtureEntry() {
        let record = Self.record("1:1 with Sam")
        let store = LibraryStore(fixtures: [record])
        #expect(store.loadNotes(for: record) == "")
    }

    @Test func loadEnhancedNotesReturnsCannedMarkdownForFixtureRecord() {
        let withEnhanced = Self.record("Weekly standup")
        let withoutEnhanced = Self.record("1:1 with Sam")
        let markdown = "## Updates\n- shipped the draft"
        let store = LibraryStore(
            fixtures: [withEnhanced, withoutEnhanced],
            enhancedNotes: [withEnhanced.meeting.id: markdown]
        )
        #expect(store.loadEnhancedNotes(for: withEnhanced) == markdown)
    }

    @Test func loadEnhancedNotesReturnsNilWhenNoFixtureEntry() {
        let record = Self.record("1:1 with Sam")
        let store = LibraryStore(fixtures: [record])
        #expect(store.loadEnhancedNotes(for: record) == nil)
    }

    /// `notesChanged` must no-op harmlessly for fixture records (no
    /// `autosaver`) — regression guard for the enhance-reveal fixture work:
    /// editing notes in a fixture-mode meeting must never crash or attempt
    /// a disk write.
    @Test func notesChangedNoOpsForFixtureRecord() {
        let record = Self.record("Weekly standup")
        let store = LibraryStore(fixtures: [record], notes: [record.meeting.id: "original"])
        store.notesChanged("edited", in: record)
        // Fixture mode has no autosaver/storage to flush into — the canned
        // value keeps coming back from `loadNotes`, proving nothing crashed
        // and nothing silently mutated fixture state.
        #expect(store.loadNotes(for: record) == "original")
    }
}
