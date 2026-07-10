import Foundation
import Testing
@testable import RecapCore

@Suite struct BackupAggregateTests {
    // MARK: MirrorError.classify

    @Test func classifyPassesThroughExistingMirrorErrors() {
        #expect(MirrorError.classify(MirrorError.diskFull) == .diskFull)
        #expect(MirrorError.classify(MirrorError.destinationUnreachable) == .destinationUnreachable)
        #expect(MirrorError.classify(MirrorError.copyFailed) == .copyFailed)
    }

    @Test func classifyCocoaOutOfSpaceIsDiskFull() {
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)
        #expect(MirrorError.classify(error) == .diskFull)
    }

    @Test func classifyPOSIXENOSPCIsDiskFull() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(MirrorError.classify(error) == .diskFull)
    }

    @Test func classifyUnderlyingENOSPCIsDiskFull() {
        // FileManager typically wraps the POSIX failure in a Cocoa error —
        // the underlying error still means the disk is full.
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let error = NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        #expect(MirrorError.classify(error) == .diskFull)
    }

    @Test func classifyNoSuchFileIsDestinationUnreachable() {
        let noSuchFile = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue)
        #expect(MirrorError.classify(noSuchFile) == .destinationUnreachable)
        let readNoSuchFile = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue)
        #expect(MirrorError.classify(readNoSuchFile) == .destinationUnreachable)
    }

    @Test func classifyAnythingElseIsCopyFailed() {
        let permission = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
        #expect(MirrorError.classify(permission) == .copyFailed)
        struct Opaque: Error {}
        #expect(MirrorError.classify(Opaque()) == .copyFailed)
    }

    // MARK: Stuck reason mapping

    @Test func stuckReasonMapsEveryMirrorError() {
        #expect(BackupAggregate.stuckReason(for: .destinationUnreachable) == .folderUnreachable)
        #expect(BackupAggregate.stuckReason(for: .diskFull) == .diskFull)
        #expect(BackupAggregate.stuckReason(for: .copyFailed) == .copyFailed)
    }

    // MARK: Pending

    @Test func neverBackedUpIsPending() {
        #expect(BackupAggregate.isPending(lastBackupDate: nil, updatedAt: nil))
        #expect(BackupAggregate.isPending(lastBackupDate: nil, updatedAt: .now))
    }

    @Test func backedUpAfterLastEditIsNotPending() {
        let edited = Date(timeIntervalSince1970: 1_000)
        let backedUp = Date(timeIntervalSince1970: 2_000)
        #expect(!BackupAggregate.isPending(lastBackupDate: backedUp, updatedAt: edited))
        // No recorded edit at all: the backup stands.
        #expect(!BackupAggregate.isPending(lastBackupDate: backedUp, updatedAt: nil))
    }

    @Test func editedAfterLastBackupIsPending() {
        let backedUp = Date(timeIntervalSince1970: 1_000)
        let edited = Date(timeIntervalSince1970: 2_000)
        #expect(BackupAggregate.isPending(lastBackupDate: backedUp, updatedAt: edited))
    }

    // MARK: Latest backup date

    @Test func latestBackupDateIsNilWhenNothingEverBackedUp() {
        #expect(BackupAggregate.latestBackupDate([]) == nil)
        #expect(BackupAggregate.latestBackupDate([nil, nil]) == nil)
    }

    @Test func latestBackupDatePicksTheMaxIgnoringNils() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        #expect(BackupAggregate.latestBackupDate([early, nil, late]) == late)
    }
}
