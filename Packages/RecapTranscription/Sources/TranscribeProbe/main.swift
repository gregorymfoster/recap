import Foundation
import RecapTranscription

// Manual verification harness for model download + file transcription (M5).
// Usage: swift run transcribe-probe <audio-file> [variant]
// Downloads the variant (default: tiny) into the standard models root if
// needed, transcribes the file, and prints the transcript with timings.

let arguments = CommandLine.arguments.dropFirst()
guard let audioPath = arguments.first else {
    print("usage: transcribe-probe <audio-file> [variant]")
    exit(64)
}
let variant = arguments.dropFirst().first ?? "tiny"

@MainActor
func run() async {
    guard let model = ModelCatalog.info(for: variant) else {
        print("FAIL: unknown variant \(variant); known: \(ModelCatalog.all.map(\.id).joined(separator: ", "))")
        exit(1)
    }
    let manager = WhisperModelManager()

    if manager.installedFolder(for: model) == nil {
        print("downloading \(model.displayName)…")
        manager.download(model)
        while case .downloading(let fraction) = manager.states[model.id] ?? .available {
            print(String(format: "  %3.0f%%", fraction * 100))
            try? await Task.sleep(for: .seconds(2))
        }
        guard manager.states[model.id] == .installed else {
            print("FAIL: download did not complete")
            exit(1)
        }
    }
    manager.setActive(model.id)

    guard let engine = manager.activeEngine() else {
        print("FAIL: no engine for installed model")
        exit(1)
    }

    print("transcribing \(audioPath) with \(model.displayName)…")
    let started = Date.now
    do {
        let transcript = try await engine.transcribe(file: URL(fileURLWithPath: audioPath)) { fraction in
            print(String(format: "  progress %3.0f%%", fraction * 100))
        }
        let elapsed = Date.now.timeIntervalSince(started)
        print(String(format: "done in %.1fs — %d utterances (%@)", elapsed, transcript.utterances.count, transcript.language))
        for utterance in transcript.utterances {
            print(String(format: "[%6.1f – %6.1f] %@", utterance.start, utterance.end, utterance.text))
        }
        exit(0)
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
}

Task { await run() }
RunLoop.main.run()
