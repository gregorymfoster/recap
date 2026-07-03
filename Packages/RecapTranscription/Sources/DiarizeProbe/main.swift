import Foundation
import RecapTranscription

// Manual-test harness: diarize an audio file and print speaker turns.
// Run: swift run diarize-probe <audio-file> [--json]
//
// --json: in addition to the normal human-readable output, prints exactly one
// JSON object as the LAST line of stdout, e.g.: {"ok":true,"speakers":2,"turns":9}
// Exit codes are unchanged: 0 success, 1 failure, 64 usage error, 66 file not found.

/// Last-line machine-readable summary for `--json`.
struct ProbeResult: Codable {
    var ok: Bool
    var speakers: Int
    var turns: Int
}

func printJSON(_ result: ProbeResult) {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(result), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let jsonOutput = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }

guard let path = arguments.first else {
    print("usage: diarize-probe <audio-file> [--json]")
    exit(64)
}
let file = URL(fileURLWithPath: path)
guard FileManager.default.fileExists(atPath: file.path) else {
    print("no such file: \(file.path)")
    exit(66)
}

let diarizer = SpeakerDiarizer()
let started = Date()
do {
    let turns = try await diarizer.speakerTurns(in: file) { fraction in
        print(String(format: "  … %3.0f%%", fraction * 100))
    }
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "\n%d turns in %.1fs:", turns.count, elapsed))
    for turn in turns {
        print(String(format: "  %7.2f – %7.2f  %@", turn.start, turn.end, turn.speakerID))
    }
    let speakers = Set(turns.map(\.speakerID)).sorted()
    print("\nspeakers: \(speakers.joined(separator: ", "))")
    if jsonOutput {
        printJSON(ProbeResult(ok: true, speakers: speakers.count, turns: turns.count))
    }
} catch {
    print("diarization failed: \(error)")
    if jsonOutput {
        printJSON(ProbeResult(ok: false, speakers: 0, turns: 0))
    }
    exit(1)
}
