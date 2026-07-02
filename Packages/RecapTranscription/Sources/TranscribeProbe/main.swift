import AVFoundation
import Foundation
import RecapCore
import RecapTranscription

// Manual verification harness for model download + transcription (M5/M7).
// Usage: transcribe-probe <audio-file> [variant] [--stream]
// Downloads the variant (default: tiny) if needed, then transcribes the file —
// in one shot, or with --stream by replaying it through the live streaming
// path in 1-second chunks.

var argumentList = Array(CommandLine.arguments.dropFirst())
let streaming = argumentList.contains("--stream")
argumentList.removeAll { $0 == "--stream" }
guard let audioPath = argumentList.first else {
    print("usage: transcribe-probe <audio-file> [variant] [--stream]")
    exit(64)
}
let variant = argumentList.dropFirst().first ?? "tiny"

/// Replays an audio file through the streaming API as 1s 16 kHz mono chunks.
@MainActor
func runStreamProbe(engine: WhisperKitEngine, url: URL) async {
    guard
        let file = try? AVAudioFile(forReading: url),
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ),
        let converter = AVAudioConverter(from: file.processingFormat, to: monoFormat)
    else {
        print("FAIL: cannot read \(url.path)")
        exit(1)
    }
    var samples: [Float] = []
    let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
    while let _ = try? file.read(into: readBuffer), readBuffer.frameLength > 0 {
        let capacity = AVAudioFrameCount(Double(readBuffer.frameLength) * 16_000 / file.processingFormat.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { break }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input: AVAudioPCMBuffer = readBuffer
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let data = out.floatChannelData, out.frameLength > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        }
        readBuffer.frameLength = 0
    }
    print("streaming \(samples.count / 16_000)s of audio in 1s chunks…")

    let (chunks, continuation) = AsyncStream.makeStream(of: RecapCore.AudioChunk.self)
    let updates = engine.transcribe(stream: chunks)
    let feed = Task {
        var position: TimeInterval = 0
        for start in stride(from: 0, to: samples.count, by: 16_000) {
            let end = min(start + 16_000, samples.count)
            continuation.yield(RecapCore.AudioChunk(
                samples: Array(samples[start..<end]), sampleRate: 16_000, start: position
            ))
            position += Double(end - start) / 16_000
        }
        continuation.finish()
    }
    var confirmed = 0
    var sawLive = false
    var sawFailure = false
    for await update in updates {
        switch update {
        case .confirmed(let utterance):
            confirmed += 1
            print(String(format: "CONFIRMED [%5.1f – %5.1f] %@", utterance.start, utterance.end, utterance.text))
        case .partial(let utterance):
            print(String(format: "partial   [%5.1f – %5.1f] %@", utterance.start, utterance.end, utterance.text))
        case .progress:
            break
        case .status(let state):
            print("STATUS    \(state)")
            switch state {
            case .live: sawLive = true
            case .failed: sawFailure = true
            default: break
            }
        }
    }
    _ = await feed.value
    print("done — \(confirmed) confirmed utterances, live=\(sawLive), failed=\(sawFailure)")
    exit(confirmed > 0 && sawLive && !sawFailure ? 0 : 1)
}

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

    if streaming {
        await runStreamProbe(engine: engine, url: URL(fileURLWithPath: audioPath))
        return
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
