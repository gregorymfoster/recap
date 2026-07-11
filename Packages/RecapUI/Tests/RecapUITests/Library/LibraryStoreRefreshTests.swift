import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

/// Covers the foreground-refresh short-circuit added alongside `reload()`:
/// `LibraryStore.mergeReloaded` (pure merge table tests) and
/// `refreshFromDisk()` (fingerprint short-circuit, membership pickup, root
/// unreachable handling).
@MainActor
@Suite(.serialized) struct LibraryStoreRefreshTests {
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreRefreshTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    private static func record(
        _ title: String, status: MeetingStatus = .ready, updatedAt: Date? = nil
    ) -> MeetingRecord {
        MeetingRecord(
            meeting: Meeting(title: title, date: .now, status: status, updatedAt: updatedAt),
            folderURL: URL(filePath: "/dev/null")
        )
    }

    // MARK: mergeReloaded

    @Test func mergeReloadedKeepsCurrentWhenLoadedIsNotStrictlyNewer() {
        let base = Date(timeIntervalSince1970: 1_000)
        let current = Self.record("Same time", updatedAt: base)
        var loaded = current
        loaded.meeting.title = "Disk copy" // same updatedAt, different content — current should win
        loaded.meeting.updatedAt = base

        let merged = LibraryStore.mergeReloaded(current: [current], loaded: [loaded])

        #expect(merged.map(\.meeting.title) == ["Same time"])
    }

    @Test func mergeReloadedPrefersLoadedWhenStrictlyNewer() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let current = Self.record("In memory", updatedAt: older)
        var loaded = current
        loaded.meeting.title = "From disk"
        loaded.meeting.updatedAt = newer

        let merged = LibraryStore.mergeReloaded(current: [current], loaded: [loaded])

        #expect(merged.map(\.meeting.title) == ["From disk"])
    }

    @Test func mergeReloadedAddsMembersOnlyOnDisk() {
        let onDiskOnly = Self.record("New from disk")

        let merged = LibraryStore.mergeReloaded(current: [], loaded: [onDiskOnly])

        #expect(merged.map(\.meeting.id) == [onDiskOnly.meeting.id])
    }

    @Test func mergeReloadedDropsMembersOnlyInMemory() {
        let deletedExternally = Self.record("Gone from disk", status: .ready)

        let merged = LibraryStore.mergeReloaded(current: [deletedExternally], loaded: [])

        #expect(merged.isEmpty)
    }

    @Test func mergeReloadedNeverDropsARecordingMeeting() {
        // Insurance against a mid-create race: the folder hasn't hit disk
        // yet when the snapshot was taken, so the disk load simply doesn't
        // see it — that must not make an active recording vanish.
        let recording = Self.record("Still recording", status: .recording)

        let merged = LibraryStore.mergeReloaded(current: [recording], loaded: [])

        #expect(merged.map(\.meeting.id) == [recording.meeting.id])
    }

    @Test func mergeReloadedKeepsInMemoryTranscribingProgressOnEqualUpdatedAt() {
        // Transcription-progress ticks live only in memory (no disk write,
        // no `updatedAt` bump) — a same-`updatedAt` disk snapshot loaded
        // mid-job must not regress the in-memory progress.
        let savedAt = Date(timeIntervalSince1970: 1_000)
        let current = Self.record("Transcribing", status: .transcribing(progress: 0.75), updatedAt: savedAt)
        var loaded = current
        loaded.meeting.status = .transcribing(progress: 0.1)
        loaded.meeting.updatedAt = savedAt

        let merged = LibraryStore.mergeReloaded(current: [current], loaded: [loaded])

        #expect(merged.first?.meeting.status == .transcribing(progress: 0.75))
    }

    // MARK: refreshFromDisk

    @Test func refreshFromDiskPicksUpAnExternallyCreatedFolder() async throws {
        let storage = makeStorage()
        let existing = try storage.create(Meeting(title: "Existing", date: .now))
        let index = try SearchIndex()
        let store = LibraryStore(storage: storage, index: index, changeBus: LibraryChangeBus())
        #expect(store.meetings.map(\.meeting.id) == [existing.meeting.id])

        let added = try storage.create(Meeting(title: "Added externally", date: .now))
        store.refreshFromDisk()

        await waitUntil { Set(store.meetings.map(\.meeting.id)) == Set([existing.meeting.id, added.meeting.id]) }
        #expect(Set(store.meetings.map(\.meeting.id)) == Set([existing.meeting.id, added.meeting.id]))
    }

    /// After `reload()` primes `lastFingerprint`, an unchanged
    /// `refreshFromDisk()` must skip the full folder load entirely — proven
    /// by seeding a corrupt folder whose "1 meeting couldn't be read" toast
    /// only fires once (at construction), never again on the no-op refresh.
    @Test func refreshFromDiskShortCircuitsWhenNothingChanged() async throws {
        let storage = makeStorage()
        _ = try storage.create(Meeting(title: "Valid", date: .now))
        let corrupt = storage.rootURL.appendingPathComponent("corrupt folder")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("meeting.json"))

        var reportedMessages: [String] = []
        let store = LibraryStore(storage: storage, index: try SearchIndex(), changeBus: LibraryChangeBus())
        store.onSaveError = { reportedMessages.append($0) }
        // Baseline full load (with the handler now wired up) primes
        // `lastFingerprint` against the corrupt folder's current state and
        // fires the toast once.
        store.reload()
        #expect(reportedMessages.count == 1)

        store.refreshFromDisk()
        // Give the (short-circuited) background task a moment to run.
        try await Task.sleep(for: .milliseconds(200))

        #expect(reportedMessages.count == 1)
    }

    @Test func refreshFromDiskSetsRootUnreachableWhenRootVanishesAndKeepsMeetings() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Before the folder vanished", date: .now))
        let store = LibraryStore(storage: storage, index: try SearchIndex(), changeBus: LibraryChangeBus())
        #expect(!store.rootUnreachable)

        try FileManager.default.removeItem(at: storage.rootURL)
        store.refreshFromDisk()

        await waitUntil { store.rootUnreachable }
        #expect(store.rootUnreachable)
        #expect(store.meetings.map(\.meeting.id) == [record.meeting.id])
    }
}
