import Foundation
import Observation
import RecapCore

/// One mirror-backup lifecycle event for a single meeting, reported by
/// whatever actually performed the mirror (the processing queue's export
/// step, or this store's own backfill/change-bus re-export).
public enum BackupEvent: Sendable, Equatable {
    case started
    case succeeded
    case failed(MirrorError)
}

/// Per-meeting backup status for the detail toolbar — simpler than the
/// aggregate `BackupState`, derived straight from `Meeting.lastBackupDate`.
public enum MeetingBackupStatus: Equatable, Sendable {
    case backedUp(Date)
    case pending
}

/// Drives the redesigned backup-status surface (Library footer + Settings
/// row): aggregate `BackupState`, figures, retry/backfill actions.
///
/// Owns all folder-mirror-backup orchestration: the bulk backfill that runs
/// when the toggle flips on, and per-meeting mirror events reported by the
/// processing queue (`noteMirrorEvent`) and the change-bus re-export
/// consumer (`mirrorMeeting`). `BackupMirrorCoordinator` and the mirror-only
/// half of `ChangeBusConsumer` were absorbed into this store so there's one
/// place that derives `state`.
@MainActor
@Observable
public final class BackupStatusStore {
    public struct BackupFigures: Equatable, Sendable {
        public var meetingCount: Int
        public var totalBytes: Int64

        public init(meetingCount: Int, totalBytes: Int64) {
            self.meetingCount = meetingCount
            self.totalBytes = totalBytes
        }
    }

    private let settings: SettingsStore
    private let library: LibraryStore
    /// nil in fixture/preview graphs, where nothing touches disk — figures
    /// stay `nil` there.
    private let storage: LibraryStorage?
    private let defaults: UserDefaults
    /// Performs one meeting's mirror. Injectable so tests can fake
    /// success/failure without touching disk; production default builds a
    /// real `FolderMirrorExporter` against the given destination root.
    private let mirrorRecord: @Sendable (MeetingRecord, URL) throws -> Void

    /// Persisted so "stuck since <date>" survives a relaunch.
    private static let stuckReasonKey = "backupStuckReason"
    private static let stuckSinceKey = "backupStuckSince"

    /// Loaded from `defaults` at init so "stuck since <date>" survives a
    /// relaunch; every change goes through `markStuck`/`clearStuck`, which
    /// persist explicitly (property observers on `@Observable` stored
    /// properties are too easy to bypass silently).
    private var stuckReason: BackupStuckReason?
    private var stuckSince: Date?

    /// Meeting IDs whose mirror is currently in flight, from `noteMirrorEvent`
    /// (queue export) or `mirrorMeeting` (change-bus re-export) — renders as
    /// `.working` while non-empty.
    private var inFlightMeetingIDs: Set<UUID> = []
    /// Progress of an active `backfill()` run, if any — takes precedence
    /// over `inFlightMeetingIDs` for the `.working` total shown, since a
    /// backfill already knows its exact total.
    private var backfillProgress: (completed: Int, total: Int)?
    private var backfillTask: Task<Void, Never>?

    /// Fixture/preview override: when set, `state` returns this verbatim
    /// instead of deriving from settings/library. Lets `FixtureScenario`
    /// render "stuck" / "working" footer variants without a real backup
    /// pipeline behind them.
    private var fixtureStateOverride: BackupState?

    public private(set) var figures: BackupFigures?

    public init(
        settings: SettingsStore,
        library: LibraryStore,
        storage: LibraryStorage?,
        defaults: UserDefaults = .standard,
        mirrorRecord: @escaping @Sendable (MeetingRecord, URL) throws -> Void = { record, destinationRoot in
            try FolderMirrorExporter(destinationRootURL: destinationRoot).mirror(record)
        }
    ) {
        self.settings = settings
        self.library = library
        self.storage = storage
        self.defaults = defaults
        self.mirrorRecord = mirrorRecord
        stuckReason = defaults.string(forKey: Self.stuckReasonKey).flatMap(BackupStuckReason.init(rawValue:))
        stuckSince = defaults.object(forKey: Self.stuckSinceKey) as? Date
        recomputeFigures()
    }

    /// Aggregate status shown in the Library footer / Settings row. Derived
    /// live from settings + in-flight/backfill/stuck bookkeeping, so every
    /// mutation above (`noteMirrorEvent`, `backfill`, `retry`) just updates
    /// the underlying bits and this reflects them immediately.
    public var state: BackupState {
        if let fixtureStateOverride { return fixtureStateOverride }
        guard settings.mirrorBackupEnabled else { return .disabled }
        if let stuckReason, let stuckSince { return .stuck(reason: stuckReason, since: stuckSince) }
        if let backfillProgress { return .working(completed: backfillProgress.completed, total: backfillProgress.total) }
        if !inFlightMeetingIDs.isEmpty { return .working(completed: 0, total: inFlightMeetingIDs.count) }
        return .ok(lastBackupAt: latestBackupDate())
    }

    /// Mirrors every ready meeting that still needs a backup (never backed
    /// up, or edited after its last backup) — the toggle-flipped-on
    /// backfill, and also what `retry()` re-runs after a stuck backup.
    /// No-ops (leaves `state` to derive as `.disabled`) when the toggle is
    /// off; also no-ops when no destination folder is configured, matching
    /// the old `BackupMirrorCoordinator.backfill()` contract.
    public func backfill() {
        guard settings.mirrorBackupEnabled else { return }
        let mirrorPath = settings.mirrorFolderPath
        guard !mirrorPath.isEmpty else { return }
        let destinationRoot = URL(fileURLWithPath: mirrorPath)

        let pending = library.meetings.filter { record in
            record.meeting.status == .ready
                && BackupAggregate.isPending(lastBackupDate: record.meeting.lastBackupDate, updatedAt: record.meeting.updatedAt)
        }
        guard !pending.isEmpty else { return }

        backfillTask?.cancel()
        let total = pending.count
        backfillProgress = (completed: 0, total: total)

        let mirrorRecord = mirrorRecord
        backfillTask = Task { [weak self] in
            var lastFailure: MirrorError?
            for record in pending {
                if Task.isCancelled { return }
                let result = await Self.performMirror(record, destinationRoot: destinationRoot, mirrorRecord: mirrorRecord)
                guard let self else { return }
                switch result {
                case .success:
                    self.library.markBackedUp(record.meeting.id)
                    let completed = (self.backfillProgress?.completed ?? 0) + 1
                    self.backfillProgress = (completed: completed, total: total)
                case .failure(let error):
                    lastFailure = error
                }
            }
            guard let self else { return }
            self.backfillProgress = nil
            if let lastFailure {
                self.markStuck(lastFailure)
            } else {
                self.clearStuck()
            }
            self.recomputeFigures()
        }
    }

    /// Re-runs the backfill from a stuck state — same mechanics as
    /// `backfill()`, since a stuck meeting is just one that's still pending.
    public func retry() {
        backfill()
    }

    /// Reports one meeting's mirror lifecycle, from whoever actually
    /// performed the mirror (the processing queue's export step today).
    public func noteMirrorEvent(meetingID: UUID, _ event: BackupEvent) {
        switch event {
        case .started:
            inFlightMeetingIDs.insert(meetingID)
        case .succeeded:
            inFlightMeetingIDs.remove(meetingID)
            clearStuck()
            recomputeFigures()
        case .failed(let error):
            inFlightMeetingIDs.remove(meetingID)
            markStuck(error)
        }
    }

    /// Re-mirrors one meeting off-main, reporting the same events a queue
    /// export would (`noteMirrorEvent`) and persisting a fresh
    /// `lastBackupDate` on success. Used by `ChangeBusConsumer` for the
    /// debounced re-export triggered by notes/edits after the pipeline
    /// already completed. No-ops when the toggle is off or no folder is
    /// configured.
    public func mirrorMeeting(_ record: MeetingRecord) {
        guard settings.mirrorBackupEnabled, !settings.mirrorFolderPath.isEmpty else { return }
        let destinationRoot = URL(fileURLWithPath: settings.mirrorFolderPath)
        let meetingID = record.meeting.id
        noteMirrorEvent(meetingID: meetingID, .started)
        let mirrorRecord = mirrorRecord
        Task { [weak self] in
            let result = await Self.performMirror(record, destinationRoot: destinationRoot, mirrorRecord: mirrorRecord)
            guard let self else { return }
            switch result {
            case .success:
                self.library.markBackedUp(meetingID)
                self.noteMirrorEvent(meetingID: meetingID, .succeeded)
            case .failure(let error):
                self.noteMirrorEvent(meetingID: meetingID, .failed(error))
            }
        }
    }

    /// Per-meeting status for the detail toolbar.
    public func backupStatus(for meetingID: UUID) -> MeetingBackupStatus {
        guard let record = library.record(for: meetingID), let date = record.meeting.lastBackupDate else {
            return .pending
        }
        return .backedUp(date)
    }

    /// Fixture-only: overrides `state` for scenario screenshots (e.g. the
    /// `backupStuck` scenario), bypassing the settings/library derivation
    /// entirely. No production graph calls this.
    public func setStateForFixtures(_ state: BackupState) {
        fixtureStateOverride = state
    }

    // MARK: Private

    private func markStuck(_ error: MirrorError) {
        stuckReason = BackupAggregate.stuckReason(for: error)
        // First failure only: "stuck since Jul 7" must not creep forward
        // with every failed retry.
        if stuckSince == nil {
            stuckSince = .now
        }
        persistStuck()
    }

    private func clearStuck() {
        stuckReason = nil
        stuckSince = nil
        persistStuck()
    }

    private func persistStuck() {
        if let stuckReason {
            defaults.set(stuckReason.rawValue, forKey: Self.stuckReasonKey)
        } else {
            defaults.removeObject(forKey: Self.stuckReasonKey)
        }
        if let stuckSince {
            defaults.set(stuckSince, forKey: Self.stuckSinceKey)
        } else {
            defaults.removeObject(forKey: Self.stuckSinceKey)
        }
    }

    private func latestBackupDate() -> Date? {
        BackupAggregate.latestBackupDate(library.meetings.map(\.meeting.lastBackupDate))
    }

    /// Recomputes `figures` off-main (folder-size walking is blocking disk
    /// I/O) — called on init and after every completed backup.
    private func recomputeFigures() {
        guard let storage else {
            figures = nil
            return
        }
        let backedUp = library.meetings.filter { $0.meeting.lastBackupDate != nil }
        guard !backedUp.isEmpty else {
            figures = BackupFigures(meetingCount: 0, totalBytes: 0)
            return
        }
        Task { [weak self] in
            let summary = await Task.detached(priority: .utility) {
                try? storage.sizeSummary(for: backedUp)
            }.value
            self?.figures = BackupFigures(meetingCount: backedUp.count, totalBytes: summary?.totalBytes ?? 0)
        }
    }

    /// Runs one mirror off-main and classifies the result — shared by
    /// `backfill()` and `mirrorMeeting(_:)`.
    private static func performMirror(
        _ record: MeetingRecord, destinationRoot: URL, mirrorRecord: @escaping @Sendable (MeetingRecord, URL) throws -> Void
    ) async -> Result<Void, MirrorError> {
        await Task.detached(priority: .utility) {
            do {
                try mirrorRecord(record, destinationRoot)
                return .success(())
            } catch {
                return .failure(MirrorError.classify(error))
            }
        }.value
    }
}
