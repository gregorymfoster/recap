import Foundation
import RecapCore
import RecapEnhancement

// Manual verification harness for note enhancement (M8).
// Usage: enhance-probe <transcript.json> [notes.md]
// Requires Apple Intelligence to be enabled on this Mac.

let arguments = CommandLine.arguments.dropFirst()
guard let transcriptPath = arguments.first else {
    print("usage: enhance-probe <transcript.json> [notes.md]")
    exit(64)
}
let notesPath = arguments.dropFirst().first

@MainActor
func run() async {
    let enhancer = FoundationModelEnhancer()
    guard enhancer.isAvailable else {
        print("UNAVAILABLE: Apple Intelligence is off or unsupported on this Mac")
        exit(2)
    }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transcript = try decoder.decode(Transcript.self, from: data)
        let notes = notesPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""

        print("enhancing (\(transcript.utterances.count) utterances, notes: \(notes.isEmpty ? "empty" : "\(notes.count) chars"))…")
        let started = Date.now
        let enhanced = try await enhancer.enhance(rawNotes: notes, transcript: transcript)
        print(String(format: "done in %.1fs\n", Date.now.timeIntervalSince(started)))
        print(enhanced)
        exit(0)
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
}

Task { await run() }
RunLoop.main.run()
