import Foundation
import RecapCore
import RecapEnhancement

// Manual verification harness for note enhancement (M8).
// Usage: enhance-probe <transcript.json> [notes.md] [--json]
// Requires Apple Intelligence to be enabled on this Mac.
//
// --json: in addition to the normal human-readable output, prints exactly one
// JSON object as the LAST line of stdout, e.g.:
//   {"ok":true,"outputChars":842,"hasSubtitle":true,"seconds":4.2}
// Exit codes are unchanged: 0 success, 1 failure, 64 usage error, 2 Apple
// Intelligence unavailable (JSON emits {"ok":false,"error":"apple-intelligence-unavailable"}).

/// Last-line machine-readable summary for `--json`.
struct ProbeResult: Codable {
    var ok: Bool
    var outputChars: Int?
    var hasSubtitle: Bool?
    var seconds: Double?
    var error: String?
}

func printJSON(_ result: ProbeResult) {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(result), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let jsonOutput = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }
guard let transcriptPath = arguments.first else {
    print("usage: enhance-probe <transcript.json> [notes.md] [--json]")
    exit(64)
}
let notesPath = arguments.dropFirst().first

@MainActor
func run() async {
    let enhancer = FoundationModelEnhancer()
    guard enhancer.isAvailable else {
        print("UNAVAILABLE: Apple Intelligence is off or unsupported on this Mac")
        if jsonOutput {
            printJSON(ProbeResult(ok: false, outputChars: nil, hasSubtitle: nil, seconds: nil, error: "apple-intelligence-unavailable"))
        }
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
        let result = try await enhancer.enhance(rawNotes: notes, transcript: transcript)
        let elapsed = Date.now.timeIntervalSince(started)
        print(String(format: "done in %.1fs\n", elapsed))
        if let subtitle = result.subtitle {
            print("subtitle: \(subtitle)\n")
        }
        print(result.notes)
        if jsonOutput {
            printJSON(ProbeResult(
                ok: true, outputChars: result.notes.count,
                hasSubtitle: result.subtitle != nil, seconds: elapsed, error: nil
            ))
        }
        exit(0)
    } catch {
        print("FAIL: \(error)")
        if jsonOutput {
            printJSON(ProbeResult(ok: false, outputChars: nil, hasSubtitle: nil, seconds: nil, error: nil))
        }
        exit(1)
    }
}

Task { await run() }
RunLoop.main.run()
