import Foundation
import Observation
import os
import RecapCore

private let libraryStoreLog = Logger(subsystem: "com.gregfoster.recap", category: "LibraryStore")

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var meetings: [MeetingRecord] = []
    public var selectedMeetingID: UUID?

    let storage: LibraryStorage?
    let index: SearchIndex?
    let autosaver: NotesAutosaver?
    let changeBus: LibraryChangeBus?
    /// Fired with a short, human-readable message whenever a disk write this
    /// store attempts (metadata save, rename, trash, meeting creation, or
    /// `NotesAutosaver` giving up after its retry budget) fails, or when
    /// `reload()` finds meeting folders it couldn't read. `AppStores` routes
    /// this to a toast (mirrors `QueueStore`'s `onError`). `nil` by default —
    /// only ever fires when `storage` is non-nil, since fixture/preview
    /// stores never touch disk.
    public var onSaveError: ((String) -> Void)?
    /// True when the library root folder is missing and that's considered a
    /// genuine error (not just a fresh install that hasn't recorded its first
    /// meeting yet — see `reload()`). Drives the Library's persistent
    /// "can't find your folder" banner.
    public internal(set) var rootUnreachable = false
    /// Set the first time `reload()` observes the root as reachable this
    /// launch — part of `rootUnreachable`'s gating rule (see `reload()`).
    private var rootWasReachableThisLaunch = false
    /// The fingerprint `reload()`/`refreshFromDisk()` last observed —
    /// `refreshFromDisk()`'s short-circuit compares against this so an
    /// unchanged library skips the full folder-list load.
    private var lastFingerprint: LibraryStorage.LibraryFingerprint?
    /// Guards against overlapping `refreshFromDisk()` calls (e.g. two
    /// foreground notifications in quick succession) — not part of the
    /// observable view state, so it's excluded from `@Observable` tracking.
    @ObservationIgnored
    private var refreshInFlight = false
    /// Canned transcripts for fixture records (no disk in fixture mode), so
    /// -fixtures runs and screenshot dumps can show the transcript pane —
    /// avatars, rename affordance. Empty in disk-backed mode.
    var fixtureTranscripts: [UUID: Transcript] = [:]
    /// Canned raw notes for fixture records, mirroring `fixtureTranscripts`.
    /// Empty in disk-backed mode.
    var fixtureNotes: [UUID: String] = [:]
    /// Canned enhanced notes for fixture records, mirroring
    /// `fixtureTranscripts`. Empty in disk-backed mode.
    var fixtureEnhancedNotes: [UUID: String] = [:]
    /// In-memory timed notes for fixture records, mirroring
    /// `fixtureNotes` — `addTimedNote` appends here instead of touching disk.
    /// Empty in disk-backed mode.
    var fixtureTimedNotes: [UUID: [TimedNote]] = [:]
    /// Per-meeting cache of disk-loaded timed notes, so repeat
    /// `timedNotes(for:)` calls don't re-read `notes.json` — populated on
    /// first load, kept in sync by `addTimedNote`. Disk-backed mode only.
    var timedNotesCache: [UUID: [TimedNote]] = [:]

    /// Disk-backed store: loads the library and rebuilds the search index.
    public init(storage: LibraryStorage, index: SearchIndex, changeBus: LibraryChangeBus) {
        self.storage = storage
        self.index = index
        self.autosaver = NotesAutosaver(storage: storage)
        self.changeBus = changeBus
        reload()
        wireAutosaverExhaustion()
    }

    /// Routes `NotesAutosaver`'s "gave up after its retry budget" signal to
    /// the same `onSaveError` toast seam as every other silent-write failure
    /// below. Wired post-init (actor calls are async; `init` isn't) via a
    /// detached task rather than an init parameter — capturing `self` in the
    /// handler would otherwise require `self` before every stored property
    /// is assigned. Harmless if it lands a beat after construction: the
    /// autosaver's own retry backoff (seconds by default) gives this plenty
    /// of time to attach before a real write could ever exhaust it.
    private func wireAutosaverExhaustion() {
        guard let autosaver else { return }
        Task {
            await autosaver.setOnExhausted { [weak self] in
                Task { @MainActor in
                    self?.onSaveError?("Couldn't save your notes — check disk space or folder permissions.")
                }
            }
        }
    }

    /// Fixture store for previews and early UI work.
    public init(
        fixtures: [MeetingRecord],
        transcripts: [UUID: Transcript] = [:],
        notes: [UUID: String] = [:],
        enhancedNotes: [UUID: String] = [:],
        timedNotes: [UUID: [TimedNote]] = [:]
    ) {
        self.storage = nil
        self.index = nil
        self.autosaver = nil
        self.changeBus = nil
        self.meetings = fixtures
        self.fixtureTranscripts = transcripts
        self.fixtureNotes = notes
        self.fixtureEnhancedNotes = enhancedNotes
        self.fixtureTimedNotes = timedNotes
        rebuildDisplayMeetings()
    }

    /// `meetings`, newest-first — the source of truth (`meetings`) never
    /// changes order itself. Cached instead of resorted on every access: the
    /// redesign (design mock 10a/11c) dropped the user-facing sort/filter UI
    /// in favor of a single fixed ordering, but transcription-progress ticks
    /// touch `meetings` far more often than membership or dates change, and
    /// re-sorting + re-grouping the whole library on every tick was showing
    /// up as an O(n log n) hitch while a recording was transcribing. Rebuilt
    /// (`rebuildDisplayMeetings`) only when membership or sort keys (date)
    /// change; status/progress-only updates patch the cached element in
    /// place via `updateDisplayElement`.
    public private(set) var displayMeetings: [MeetingRecord] = []

    /// Section-grouped copy of `displayMeetings` (Today/Yesterday/This
    /// Week/…), cached alongside it for the same reason: `LibraryView`'s body
    /// used to call `MeetingGrouping.sections` directly on every render,
    /// which re-buckets and re-sorts the whole library on every
    /// transcription-progress tick. Rebuilt whenever `displayMeetings` is
    /// rebuilt or a status transition re-sorts a record; `updateDisplayElement`
    /// patches the matching record in place instead of regrouping.
    public private(set) var displaySections: [MeetingGrouping.Section] = []
    /// The calendar day `displaySections` was last built for — lets
    /// `sections(now:calendar:)` detect a stale cache after midnight without
    /// a timer.
    private var sectionsDay: Date?

    private func rebuildDisplayMeetings() {
        displayMeetings = meetings.sorted { $0.meeting.date > $1.meeting.date }
        rebuildSections()
    }

    private func rebuildSections(now: Date = .now, calendar: Calendar = .current) {
        displaySections = MeetingGrouping.sections(displayMeetings, now: now, calendar: calendar)
        sectionsDay = calendar.startOfDay(for: now)
    }

    /// Cached when built for the same calendar day; a post-midnight render
    /// falls back to a fresh (uncached) computation — same cost as today —
    /// until the next mutation re-primes the cache. Never mutates state, so
    /// it's safe to call from a view body.
    public func sections(now: Date = .now, calendar: Calendar = .current) -> [MeetingGrouping.Section] {
        if calendar.startOfDay(for: now) == sectionsDay { return displaySections }
        return MeetingGrouping.sections(displayMeetings, now: now, calendar: calendar)
    }

    /// Patches one element of the cached `displayMeetings` in place, for
    /// mutations that don't change membership or sort order (status,
    /// progress, subtitle, backup timestamp, rename). No-op if the record
    /// isn't present (shouldn't happen, but keeps this defensive). Also
    /// patches `displaySections` in the same spot, so progress ticks don't
    /// need a full regroup.
    private func updateDisplayElement(_ record: MeetingRecord) {
        if let i = displayMeetings.firstIndex(where: { $0.meeting.id == record.meeting.id }) {
            displayMeetings[i] = record
        }
        outer: for si in displaySections.indices {
            for ri in displaySections[si].records.indices where displaySections[si].records[ri].meeting.id == record.meeting.id {
                displaySections[si].records[ri] = record
                break outer
            }
        }
    }

    /// Reloads the library from disk. Also re-checks `rootUnreachable` and
    /// (in the background) repairs the search index if it's drifted from
    /// what's on disk.
    ///
    /// Root-reachability rule: a fresh default install has no `~/Recap`
    /// folder until the first recording creates it (`LibraryStorage.create`),
    /// so a missing root must NOT read as an error there. It's only treated
    /// as a genuine error — surfaced via `rootUnreachable` rather than
    /// silently showing an empty library — when the root is a folder the
    /// user deliberately pointed at (a customized save location in Settings)
    /// or one that was reachable earlier this launch and then vanished
    /// (external drive unmounted, folder deleted/renamed underneath the app).
    public func reload() {
        guard let storage, let index else { return }
        let reachable = storage.rootIsReachable()
        if reachable { rootWasReachableThisLaunch = true }
        let isCustomRoot = storage.rootURL.path != LibraryStorage.defaultRootURL.path
        rootUnreachable = LibraryStorage.rootUnreachableIsError(
            reachable: reachable, isCustomRoot: isCustomRoot, wasReachableEarlierThisLaunch: rootWasReachableThisLaunch
        )

        guard reachable else {
            // Keep the last-known `meetings` in memory rather than wiping the
            // list to empty — losing the root shouldn't look like losing the
            // meetings themselves, and `rootUnreachable` above is what
            // actually drives the Library's banner for the genuine-error case.
            return
        }

        let result = (try? storage.loadAllDetailed()) ?? LibraryStorage.LoadAllResult(records: [], skippedCount: 0)
        meetings = result.records
        rebuildDisplayMeetings()
        if result.skippedCount > 0 {
            let plural = result.skippedCount == 1 ? "" : "s"
            onSaveError?("\(result.skippedCount) meeting\(plural) couldn't be read and \(result.skippedCount == 1 ? "was" : "were") skipped.")
        }
        // Primes the short-circuit `refreshFromDisk()` compares against, so
        // the first foreground refresh after launch can skip a redundant
        // full load if nothing's changed on disk in the meantime.
        lastFingerprint = storage.fingerprint()
        reindexInBackground(records: result.records, storage: storage, index: index)
    }

    /// Merges a freshly loaded disk snapshot with the in-memory `meetings`
    /// array. Disk wins for membership (folders added/removed externally)
    /// and for a record that's strictly newer on disk than in memory;
    /// otherwise the in-memory record is kept, since it's the writer and
    /// transcription-progress ticks live only in memory (no disk write, no
    /// `updatedAt` bump) — a snapshot loaded mid-job must not regress a row
    /// back to its last-saved (pre-progress) state. A record only present in
    /// memory is dropped (it was deleted from disk) UNLESS its status is
    /// `.recording` — insurance against a mid-create race where the folder
    /// hasn't hit disk yet when the fingerprint/load ran.
    static func mergeReloaded(current: [MeetingRecord], loaded: [MeetingRecord]) -> [MeetingRecord] {
        let loadedByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.meeting.id, $0) })
        var handledIDs: Set<UUID> = []
        var result: [MeetingRecord] = []

        for currentRecord in current {
            handledIDs.insert(currentRecord.meeting.id)
            guard let loadedRecord = loadedByID[currentRecord.meeting.id] else {
                if currentRecord.meeting.status == .recording {
                    result.append(currentRecord)
                }
                continue
            }
            if isStrictlyNewer(loadedRecord.meeting.updatedAt, than: currentRecord.meeting.updatedAt) {
                result.append(loadedRecord)
            } else {
                result.append(currentRecord)
            }
        }
        for loadedRecord in loaded where !handledIDs.contains(loadedRecord.meeting.id) {
            result.append(loadedRecord)
        }
        return result
    }

    private static func isStrictlyNewer(_ candidate: Date?, than base: Date?) -> Bool {
        guard let candidate else { return false }
        guard let base else { return true }
        return candidate > base
    }

    /// Outcome of the off-main fingerprint+load step behind
    /// `refreshFromDisk()`.
    private enum RefreshOutcome: Sendable {
        case rootUnreachable
        case unchanged(LibraryStorage.LibraryFingerprint)
        case loaded(LibraryStorage.LoadAllResult, LibraryStorage.LibraryFingerprint)
    }

    /// Runs off the main actor (this is `nonisolated`, so awaiting it from a
    /// `@MainActor` method hops execution to the background before touching
    /// the filesystem): checks reachability, then fingerprints the root and
    /// compares against `lastFingerprint` to decide whether a full
    /// `loadAllDetailed()` is needed at all.
    private nonisolated static func loadIfChanged(
        storage: LibraryStorage, lastFingerprint: LibraryStorage.LibraryFingerprint?
    ) async -> RefreshOutcome {
        guard storage.rootIsReachable() else { return .rootUnreachable }
        let fingerprint = storage.fingerprint()
        if let lastFingerprint, fingerprint == lastFingerprint {
            return .unchanged(fingerprint)
        }
        let result = (try? storage.loadAllDetailed()) ?? LibraryStorage.LoadAllResult(records: [], skippedCount: 0)
        return .loaded(result, fingerprint)
    }

    /// Foreground-refresh path: like `reload()`, but cheap in the common
    /// case where nothing changed on disk while Recap was backgrounded — the
    /// fingerprint check and (when needed) the folder load both run off the
    /// main actor, and a changed result is merged with the in-memory state
    /// rather than replacing it outright (see `mergeReloaded`), so an
    /// in-flight transcription's in-memory progress survives a concurrent
    /// disk snapshot. No-ops (like `reload()`) when there's no real storage,
    /// or while a previous call is still in flight.
    public func refreshFromDisk() {
        guard let storage, let index else { return }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let capturedFingerprint = lastFingerprint
        Task {
            let outcome = await Self.loadIfChanged(storage: storage, lastFingerprint: capturedFingerprint)
            applyRefreshOutcome(outcome, storage: storage, index: index)
            refreshInFlight = false
        }
    }

    /// Applies a `RefreshOutcome` back on the main actor — mirrors
    /// `reload()`'s `rootUnreachable` bookkeeping exactly (same flags, same
    /// gating rule) so the two code paths can't drift apart.
    private func applyRefreshOutcome(_ outcome: RefreshOutcome, storage: LibraryStorage, index: SearchIndex) {
        let reachable: Bool
        switch outcome {
        case .rootUnreachable: reachable = false
        case .unchanged, .loaded: reachable = true
        }
        if reachable { rootWasReachableThisLaunch = true }
        let isCustomRoot = storage.rootURL.path != LibraryStorage.defaultRootURL.path
        rootUnreachable = LibraryStorage.rootUnreachableIsError(
            reachable: reachable, isCustomRoot: isCustomRoot, wasReachableEarlierThisLaunch: rootWasReachableThisLaunch
        )
        guard reachable else {
            // Keep the last-known `meetings` in memory, same as reload()'s
            // unreachable branch.
            return
        }

        switch outcome {
        case .rootUnreachable:
            return
        case .unchanged(let fingerprint):
            lastFingerprint = fingerprint
        case .loaded(let result, let fingerprint):
            meetings = Self.mergeReloaded(current: meetings, loaded: result.records)
            rebuildDisplayMeetings()
            if result.skippedCount > 0 {
                let plural = result.skippedCount == 1 ? "" : "s"
                onSaveError?("\(result.skippedCount) meeting\(plural) couldn't be read and \(result.skippedCount == 1 ? "was" : "were") skipped.")
            }
            reindexInBackground(records: meetings, storage: storage, index: index)
            lastFingerprint = fingerprint
        }
    }

    /// Rebuilds the search index off the main actor. Per-mutation
    /// `index.update` (see `replace`/`insertImported`/etc. below) already
    /// keeps the index in sync for every live edit — this launch-time
    /// rebuild only repairs external drift (files hand-edited or folders
    /// hand-added outside the app, or an index that fell out of sync/was
    /// deleted). Skips the rebuild entirely when the indexed row count
    /// already matches the folder count, since that's the common case at
    /// every ordinary launch. The previous launch's on-disk index keeps
    /// serving search queries the whole time: `reindex(records:storage:)`
    /// does its DELETE + re-insert inside one GRDB write transaction, so
    /// search never sees a half-rebuilt table.
    private func reindexInBackground(records: [MeetingRecord], storage: LibraryStorage, index: SearchIndex) {
        Task.detached(priority: .utility) {
            let indexedCount = (try? index.indexedMeetingCount()) ?? -1
            guard indexedCount != records.count else { return }
            try? index.reindex(records: records, storage: storage)
        }
    }

    /// Routes an otherwise-silent disk-write failure to `onSaveError` with a
    /// short, human message naming the meeting — the shared seam behind
    /// every `try?` write below.
    private func reportSaveFailure(for title: String) {
        onSaveError?("Couldn't save changes to \"\(title)\" — check that your Recap folder is writable.")
    }

    /// Refreshes one meeting's search-index row, logging (not toasting) on
    /// failure. Search staleness isn't worth alarming users over — the
    /// meeting data itself is already safely on disk regardless — and the
    /// next launch's `reindexInBackground` repairs any drift anyway.
    private func indexUpdate(_ record: MeetingRecord, storage: LibraryStorage) {
        guard let index else { return }
        do {
            try index.update(record, from: storage)
        } catch {
            libraryStoreLog.error("index update failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// Creates a new meeting on disk and selects it. Calendar auto-record
    /// seeds the title and attendees from the event.
    @discardableResult
    public func startNewMeeting(title: String = "Untitled meeting", attendees: [String] = []) -> MeetingRecord? {
        let meeting = Meeting(title: title, date: .now, attendees: attendees, status: .recording)
        guard let storage else {
            let record = MeetingRecord(meeting: meeting, folderURL: URL(filePath: "/dev/null"))
            meetings.insert(record, at: 0)
            selectedMeetingID = meeting.id
            rebuildDisplayMeetings()
            return record
        }
        guard let record = try? storage.create(meeting) else {
            reportSaveFailure(for: title)
            return nil
        }
        meetings.insert(record, at: 0)
        selectedMeetingID = meeting.id
        indexUpdate(record, storage: storage)
        rebuildDisplayMeetings()
        return record
    }

    /// Recording stopped: persist the duration and hand the meeting to the
    /// processing queue (M6 — until then it parks as queued).
    public func finishRecording(_ record: MeetingRecord, duration: TimeInterval) {
        var updated = record
        updated.meeting.duration = duration
        updated.meeting.status = .queued
        replace(updated)
    }

    /// Adds an already-materialized imported meeting (folder, audio, and
    /// metadata all on disk — see `AudioImporter`) without a full `reload()`:
    /// sorted insert into the newest-first array, index update, change-bus
    /// post.
    public func insertImported(_ record: MeetingRecord) {
        let i = meetings.firstIndex { $0.meeting.date < record.meeting.date } ?? meetings.endIndex
        meetings.insert(record, at: i)
        if let storage { indexUpdate(record, storage: storage) }
        rebuildDisplayMeetings()
        changeBus?.post(.meetingChanged(record.meeting.id))
    }

    /// Aborts a recording that never captured audio (permission denied, engine failure).
    public func markError(_ record: MeetingRecord, message: String) {
        var updated = record
        updated.meeting.status = .error(message: message)
        replace(updated)
    }

    /// Status transition from the processing pipeline. Transcription progress
    /// ticks update the UI only; transitions between states hit disk.
    public func updateStatus(_ id: UUID, to status: MeetingStatus) {
        guard var record = record(for: id) else { return }
        let previous = record.meeting.status
        guard MeetingStatusTransition.accepts(status, after: previous) else { return }
        record.meeting.status = status
        if case .transcribing = status, case .transcribing = previous {
            // Progress-only tick within the same status: patch both the
            // source array and the cached display order in place. Doesn't
            // touch sort keys, so no rebuild of displayMeetings.
            if let i = meetings.firstIndex(where: { $0.meeting.id == id }) {
                meetings[i] = record
            }
            updateDisplayElement(record)
        } else {
            replace(record)
        }
    }

    /// Persists a recoverable pipeline problem without demoting a meeting that
    /// is otherwise ready (for example, an optional export failure).
    public func addProcessingIssue(_ issue: ProcessingIssue, for id: UUID) {
        guard var record = record(for: id), !record.meeting.processingIssues.contains(issue) else { return }
        record.meeting.processingIssues.append(issue)
        replace(record)
    }

    /// Clears one successfully recovered stage while preserving any unrelated
    /// issues (for example, a repaired backup must not hide a transcription error).
    public func clearProcessingIssue(_ issue: ProcessingIssue, for id: UUID) {
        guard var record = record(for: id), record.meeting.processingIssues.contains(issue) else { return }
        record.meeting.processingIssues.removeAll { $0 == issue }
        replace(record)
    }

    /// Records a successful folder-mirror backup. Deliberately NOT routed
    /// through `replace(_:)`: a backup timestamp isn't a content change, so
    /// it must neither bump `updatedAt` (that would leave the meeting
    /// forever "pending" — `lastBackupDate < updatedAt` — for the next
    /// backfill) nor post `.meetingChanged` (that would re-trigger the very
    /// mirror export that just completed, looping through the change-bus
    /// consumer indefinitely).
    public func markBackedUp(_ id: UUID, at date: Date = .now) {
        guard var record = record(for: id) else { return }
        record.meeting.lastBackupDate = date
        if let i = meetings.firstIndex(where: { $0.meeting.id == id }) {
            meetings[i] = record
        }
        updateDisplayElement(record)
        guard let storage else { return }
        do {
            try storage.saveMetadata(record)
        } catch {
            reportSaveFailure(for: record.meeting.title)
        }
    }

    /// Used by crash salvage: the recovered file is the only duration source.
    public func updateDuration(_ id: UUID, to duration: TimeInterval) {
        guard var record = record(for: id) else { return }
        record.meeting.duration = duration
        replace(record)
    }

    /// Persists the one-line subtitle generated during on-device enhancement,
    /// through the same metadata save path as every other mutation.
    public func updateSubtitle(_ subtitle: String, for id: UUID) {
        guard var record = record(for: id) else { return }
        record.meeting.subtitle = subtitle
        replace(record)
    }

    private func replace(_ record: MeetingRecord) {
        var record = record
        record.meeting.updatedAt = .now
        if let i = meetings.firstIndex(where: { $0.meeting.id == record.meeting.id }) {
            meetings[i] = record
        }
        // None of `replace`'s callers change `meeting.date` (the sort key),
        // so the cached display order stays valid — patch the element
        // in place rather than re-sorting the whole library. Section
        // membership CAN change though (e.g. a `.recovered` transition
        // unpins from the top of Today), so re-bucket after patching.
        updateDisplayElement(record)
        rebuildSections()
        guard let storage else { return }
        do {
            try storage.saveMetadata(record)
        } catch {
            reportSaveFailure(for: record.meeting.title)
        }
        indexUpdate(record, storage: storage)
        changeBus?.post(.meetingChanged(record.meeting.id))
    }

    public func record(for id: UUID) -> MeetingRecord? {
        meetings.first { $0.meeting.id == id }
    }

    /// Renames a meeting's display title. Fixture mode (no `storage`) updates
    /// the in-memory record only, so the context menu still works in previews.
    public func rename(_ record: MeetingRecord, to title: String) {
        guard let storage else {
            var updated = record
            updated.meeting.title = title
            replaceInMemoryOnly(updated)
            return
        }
        guard let renamed = try? storage.rename(record, to: title) else {
            reportSaveFailure(for: record.meeting.title)
            return
        }
        replace(renamed)
    }

    /// Moves a meeting's folder to the Trash (recoverable) and drops it from
    /// the in-memory list + search index. No-ops in fixture mode — there's no
    /// real folder to trash for a `/dev/null` fixture record.
    public func moveToTrash(_ record: MeetingRecord) {
        guard let storage else { return }
        guard (try? storage.trash(record)) != nil else {
            reportSaveFailure(for: record.meeting.title)
            return
        }
        meetings.removeAll { $0.meeting.id == record.meeting.id }
        if selectedMeetingID == record.meeting.id { selectedMeetingID = nil }
        if let index {
            do {
                try index.remove(meetingID: record.meeting.id)
            } catch {
                libraryStoreLog.error("index remove failed: \(String(describing: error), privacy: .private)")
            }
        }
        rebuildDisplayMeetings()
        changeBus?.post(.meetingDeleted(record.meeting.id))
    }

    /// Fixture-only path for `rename` — mirrors `replace` minus disk I/O.
    private func replaceInMemoryOnly(_ record: MeetingRecord) {
        var record = record
        record.meeting.updatedAt = .now
        if let i = meetings.firstIndex(where: { $0.meeting.id == record.meeting.id }) {
            meetings[i] = record
        }
        updateDisplayElement(record)
    }

    /// "~/Recap"-style label for the status bar.
    public var saveLocationLabel: String {
        guard let storage else { return "~/Recap" }
        let path = storage.rootURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    public var readyCount: Int {
        meetings.filter { $0.meeting.status == .ready }.count
    }
}
