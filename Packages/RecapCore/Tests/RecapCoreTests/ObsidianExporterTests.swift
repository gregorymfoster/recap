import Foundation
import Testing
@testable import RecapCore

@Suite struct ObsidianExporterTests {
    private func meeting(title: String = "Roadmap sync") -> Meeting {
        Meeting(
            title: title,
            date: Date(timeIntervalSince1970: 1_780_000_000),  // 2026-06-02 UTC
            duration: 1860,
            attendees: ["Maya", "Daniel"],
            status: .ready
        )
    }

    @Test func fileNameIsDatePlusSanitizedTitle() {
        let exporter = ObsidianExporter(vaultFolderURL: URL(fileURLWithPath: "/tmp"))
        let name = exporter.fileName(for: meeting(title: "Q3: budget / launch?"))
        #expect(name.hasSuffix(".md"))
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("?"))
        #expect(name.contains("Q3 budget launch"))
    }

    @Test func rendersFrontmatterNotesAndSpeakerTranscript() {
        let exporter = ObsidianExporter(vaultFolderURL: URL(fileURLWithPath: "/tmp"))
        let transcript = Transcript(
            utterances: [
                Utterance(speakerID: "S1", start: 0, end: 4, text: "Hello there."),
                Utterance(speakerID: "S1", start: 4, end: 8, text: "Let's begin."),
                Utterance(speakerID: "S2", start: 8, end: 12, text: "Ready when you are."),
            ],
            engine: "whisperkit", model: "m", language: "en"
        )
        let output = exporter.render(
            meeting(), notes: "raw", enhanced: "- Budget approved at 40k.", transcript: transcript
        )
        #expect(output.hasPrefix("---\n"))
        #expect(output.contains("duration: 31m"))
        #expect(output.contains("  - \"Maya\""))
        #expect(output.contains("- Budget approved at 40k."))
        #expect(!output.contains("raw"))  // enhanced wins over raw notes
        #expect(output.contains("## Transcript"))
        #expect(output.contains("**Speaker 1**\nHello there.\nLet's begin."))
        #expect(output.contains("**Speaker 2**\nReady when you are."))
    }

    @Test func fallsBackToRawNotesWithoutEnhancement() {
        let exporter = ObsidianExporter(vaultFolderURL: URL(fileURLWithPath: "/tmp"))
        let output = exporter.render(meeting(), notes: "- my rough note", enhanced: nil, transcript: nil)
        #expect(output.contains("- my rough note"))
        #expect(!output.contains("## Transcript"))
    }

    @Test func exportWritesAndOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsidian-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let exporter = ObsidianExporter(vaultFolderURL: dir)
        let record = MeetingRecord(meeting: meeting(), folderURL: dir)

        let first = try exporter.export(record, notes: "v1", enhanced: nil, transcript: nil)
        let second = try exporter.export(record, notes: "v2", enhanced: nil, transcript: nil)
        #expect(first == second)
        let content = try String(contentsOf: second, encoding: .utf8)
        #expect(content.contains("v2") && !content.contains("v1"))
    }
}
