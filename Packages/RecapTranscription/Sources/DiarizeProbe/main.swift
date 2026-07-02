import Foundation
import RecapTranscription

// Manual-test harness: diarize an audio file and print speaker turns.
// Run: swift run diarize-probe <audio-file>

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: diarize-probe <audio-file>")
    exit(64)
}
let file = URL(fileURLWithPath: arguments[1])
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
} catch {
    print("diarization failed: \(error)")
    exit(1)
}
