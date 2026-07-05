import Foundation
import Testing

@testable import RecapUI

@Suite("SeedLibrary")
struct SeedLibraryTests {
    /// A scratch directory under the system temp dir, cleaned up after each
    /// test — never touches the real `~/Recap*` trees.
    private func withScratchDir(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SeedLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func writeMeetingFolder(named name: String, in root: URL, contents: String = "hello") throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: folder.appendingPathComponent("meeting.json"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.md"))
        return folder
    }

    @Test func copiesSourceIntoUniqueTempDirectory() throws {
        try withScratchDir { scratch in
            let source = scratch.appendingPathComponent("source-library")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            _ = try writeMeetingFolder(named: "2026-01-01 Standup", in: source)

            let tempParent = scratch.appendingPathComponent("temp-root")
            try FileManager.default.createDirectory(at: tempParent, withIntermediateDirectories: true)

            let destination = SeedLibrary.prepare(
                source: source, temporaryDirectory: tempParent, uniqueSuffix: "fixed-suffix"
            )

            let unwrapped = try #require(destination)
            // Compare paths, not URLs — appendingPathComponent(_:) marks the URL
            // as a directory (trailing slash) once the directory exists on disk.
            #expect(unwrapped.path == tempParent.appendingPathComponent("recap-seed-fixed-suffix").path)
            #expect(FileManager.default.fileExists(atPath: unwrapped.appendingPathComponent("2026-01-01 Standup/meeting.json").path))
            #expect(FileManager.default.fileExists(atPath: unwrapped.appendingPathComponent("2026-01-01 Standup/notes.md").path))
        }
    }

    @Test func sourceDirectoryIsNeverWritten() throws {
        try withScratchDir { scratch in
            let source = scratch.appendingPathComponent("source-library")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let meetingFolder = try writeMeetingFolder(named: "2026-01-01 Standup", in: source)
            let metadataURL = meetingFolder.appendingPathComponent("meeting.json")
            let originalContents = try Data(contentsOf: metadataURL)
            let originalModificationDate = try FileManager.default
                .attributesOfItem(atPath: metadataURL.path)[.modificationDate] as? Date

            let tempParent = scratch.appendingPathComponent("temp-root")
            try FileManager.default.createDirectory(at: tempParent, withIntermediateDirectories: true)
            let destination = try #require(SeedLibrary.prepare(source: source, temporaryDirectory: tempParent))

            // Mutate the copy — the source must be completely unaffected.
            try Data("mutated".utf8).write(to: destination.appendingPathComponent("2026-01-01 Standup/meeting.json"))

            let contentsAfter = try Data(contentsOf: metadataURL)
            let modificationDateAfter = try FileManager.default
                .attributesOfItem(atPath: metadataURL.path)[.modificationDate] as? Date
            #expect(contentsAfter == originalContents)
            #expect(modificationDateAfter == originalModificationDate)
        }
    }

    @Test func distinctCallsProduceIsolatedCopies() throws {
        try withScratchDir { scratch in
            let source = scratch.appendingPathComponent("source-library")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            _ = try writeMeetingFolder(named: "2026-01-01 Standup", in: source)

            let tempParent = scratch.appendingPathComponent("temp-root")
            try FileManager.default.createDirectory(at: tempParent, withIntermediateDirectories: true)

            let first = try #require(SeedLibrary.prepare(source: source, temporaryDirectory: tempParent, uniqueSuffix: "one"))
            let second = try #require(SeedLibrary.prepare(source: source, temporaryDirectory: tempParent, uniqueSuffix: "two"))
            #expect(first != second)

            try Data("mutated".utf8).write(to: first.appendingPathComponent("2026-01-01 Standup/meeting.json"))
            let secondContents = try String(
                contentsOf: second.appendingPathComponent("2026-01-01 Standup/meeting.json"), encoding: .utf8
            )
            #expect(secondContents == "hello")
        }
    }

    @Test func missingSourceReturnsNil() throws {
        try withScratchDir { scratch in
            let missing = scratch.appendingPathComponent("does-not-exist")
            let tempParent = scratch.appendingPathComponent("temp-root")
            try FileManager.default.createDirectory(at: tempParent, withIntermediateDirectories: true)
            #expect(SeedLibrary.prepare(source: missing, temporaryDirectory: tempParent) == nil)
        }
    }

    @Test func sourceThatIsAFileNotADirectoryReturnsNil() throws {
        try withScratchDir { scratch in
            let file = scratch.appendingPathComponent("not-a-directory")
            try Data("plain file".utf8).write(to: file)
            let tempParent = scratch.appendingPathComponent("temp-root")
            try FileManager.default.createDirectory(at: tempParent, withIntermediateDirectories: true)
            #expect(SeedLibrary.prepare(source: file, temporaryDirectory: tempParent) == nil)
        }
    }
}
