import Foundation
import Testing
@testable import RecapCore

@Suite struct FolderMirrorExporterTests {
    private func meeting() -> Meeting {
        Meeting(
            title: "Roadmap sync",
            date: Date(timeIntervalSince1970: 1_780_000_000),
            duration: 1860,
            attendees: ["Maya", "Daniel"],
            status: .ready
        )
    }

    /// A source meeting folder with all five known files present.
    private func makeSourceRecord(fileNames: [String]? = nil) throws -> MeetingRecord {
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let record = MeetingRecord(meeting: meeting(), folderURL: sourceDir)

        let allFiles: [(String, String)] = [
            ("meeting.json", "{}"),
            ("notes.md", "raw notes"),
            ("enhanced.md", "enhanced notes"),
            ("transcript.json", "{\"utterances\":[]}"),
            ("audio.m4a", "fake audio bytes"),
        ]
        let names = fileNames ?? allFiles.map(\.0)
        for (name, content) in allFiles where names.contains(name) {
            try Data(content.utf8).write(to: sourceDir.appendingPathComponent(name))
        }
        return record
    }

    @Test func freshMirrorCopiesAllPresentFiles() throws {
        let record = try makeSourceRecord()
        defer { try? FileManager.default.removeItem(at: record.folderURL) }
        let destRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-dest-\(UUID().uuidString)")
        // The exporter refuses to invent a missing destination root (that's
        // the `destinationUnreachable` signal), so create it like a user
        // picking an existing folder would.
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destRoot) }

        let exporter = FolderMirrorExporter(destinationRootURL: destRoot)
        try exporter.mirror(record)

        let destFolder = destRoot.appendingPathComponent(record.folderURL.lastPathComponent)
        for name in ["meeting.json", "notes.md", "enhanced.md", "transcript.json", "audio.m4a"] {
            #expect(FileManager.default.fileExists(atPath: destFolder.appendingPathComponent(name).path))
        }
    }

    @Test func reMirrorAfterTouchingOneFileOnlyRecopiesThatFile() throws {
        let record = try makeSourceRecord()
        defer { try? FileManager.default.removeItem(at: record.folderURL) }
        let destRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-dest-\(UUID().uuidString)")
        // The exporter refuses to invent a missing destination root (that's
        // the `destinationUnreachable` signal), so create it like a user
        // picking an existing folder would.
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destRoot) }

        let exporter = FolderMirrorExporter(destinationRootURL: destRoot)
        try exporter.mirror(record)

        let destFolder = destRoot.appendingPathComponent(record.folderURL.lastPathComponent)
        let fm = FileManager.default

        func modificationDate(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }

        let otherFiles = ["meeting.json", "enhanced.md", "transcript.json", "audio.m4a"]
        let mtimesBefore = Dictionary(uniqueKeysWithValues: otherFiles.map { ($0, modificationDate(destFolder.appendingPathComponent($0))) })

        // Wait a beat so the new mtime is unambiguously later, then touch
        // only notes.md with new content.
        try? await_(seconds: 1.1)
        try Data("updated notes".utf8).write(to: record.folderURL.appendingPathComponent("notes.md"))

        try exporter.mirror(record)

        let updatedNotes = try String(contentsOf: destFolder.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(updatedNotes == "updated notes")

        for name in otherFiles {
            #expect(modificationDate(destFolder.appendingPathComponent(name)) == mtimesBefore[name] ?? nil)
        }
    }

    @Test func missingAudioDoesNotThrowAndStillMirrorsTheRest() throws {
        let record = try makeSourceRecord(fileNames: ["meeting.json", "notes.md", "enhanced.md", "transcript.json"])
        defer { try? FileManager.default.removeItem(at: record.folderURL) }
        let destRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-dest-\(UUID().uuidString)")
        // The exporter refuses to invent a missing destination root (that's
        // the `destinationUnreachable` signal), so create it like a user
        // picking an existing folder would.
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destRoot) }

        let exporter = FolderMirrorExporter(destinationRootURL: destRoot)
        try exporter.mirror(record)

        let destFolder = destRoot.appendingPathComponent(record.folderURL.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: destFolder.appendingPathComponent("audio.m4a").path))
        for name in ["meeting.json", "notes.md", "enhanced.md", "transcript.json"] {
            #expect(FileManager.default.fileExists(atPath: destFolder.appendingPathComponent(name).path))
        }
    }

    // MARK: Error surfacing

    @Test func missingDestinationRootThrowsDestinationUnreachable() throws {
        let record = try makeSourceRecord()
        defer { try? FileManager.default.removeItem(at: record.folderURL) }
        let destRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-dest-\(UUID().uuidString)")
        // Deliberately never created.

        let exporter = FolderMirrorExporter(destinationRootURL: destRoot)
        #expect(throws: MirrorError.destinationUnreachable) {
            try exporter.mirror(record)
        }
        // And it must not have invented the root as a side effect.
        #expect(!FileManager.default.fileExists(atPath: destRoot.path))
    }

    @Test func unwritableDestinationFolderSurfacesCopyFailure() throws {
        let record = try makeSourceRecord()
        defer { try? FileManager.default.removeItem(at: record.folderURL) }
        let destRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-dest-\(UUID().uuidString)")
        let destFolder = destRoot.appendingPathComponent(record.folderURL.lastPathComponent)
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        // Read+execute only: createDirectory(withIntermediateDirectories:)
        // still succeeds on the existing folder, but every file copy into it
        // fails with a permission error.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destFolder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destFolder.path)
            try? FileManager.default.removeItem(at: destRoot)
        }

        let exporter = FolderMirrorExporter(destinationRootURL: destRoot)
        #expect(throws: MirrorError.copyFailed) {
            try exporter.mirror(record)
        }
    }

    /// Simple blocking sleep helper so tests stay synchronous like the rest
    /// of the suite (mtime-diffing tests need real wall-clock separation).
    private func await_(seconds: Double) throws {
        Thread.sleep(forTimeInterval: seconds)
    }
}
