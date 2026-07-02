import AVFoundation
import Foundation
import RecapAudio

// Manual verification harness for the capture pipeline (M3/M4).
// Records mic + system audio for N seconds (default 5) to capture-probe.m4a
// in the current directory and prints stream stats. Play some audio while it
// runs to verify the system tap; speak to verify the mic.

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 5

@MainActor
func run() async {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("capture-probe.m4a")
    try? FileManager.default.removeItem(at: url)

    guard await MeetingRecorder.requestMicPermission() else {
        print("FAIL: microphone permission denied")
        exit(1)
    }

    let recorder = MeetingRecorder()
    let output: MeetingRecorder.Output
    do {
        output = try recorder.start(writingTo: url)
    } catch {
        print("FAIL: recorder start: \(error)")
        exit(1)
    }
    print("recording \(seconds)s — system audio active: \(recorder.systemAudioActive)")

    let statsTask = Task {
        var chunkCount = 0
        var sampleCount = 0
        var peakLevel: Float = 0
        for await chunk in output.chunks {
            chunkCount += 1
            sampleCount += chunk.samples.count
            peakLevel = max(peakLevel, chunk.samples.map(abs).max() ?? 0)
        }
        return (chunkCount, sampleCount, peakLevel)
    }

    try? await Task.sleep(for: .seconds(seconds))
    let duration = await recorder.stop()
    let (chunkCount, sampleCount, peak) = await statsTask.value

    print(String(format: "duration: %.1fs", duration))
    print("16k chunks: \(chunkCount), samples: \(sampleCount) (≈\(sampleCount / 16_000)s)")
    print(String(format: "peak amplitude: %.4f", peak))
    if let audioFile = try? AVAudioFile(forReading: url) {
        let fileSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        print(String(format: "file: %@ (%.1fs @ %.0f Hz)", url.lastPathComponent, fileSeconds, audioFile.fileFormat.sampleRate))
    } else {
        print("FAIL: output file unreadable")
        exit(1)
    }
    exit(sampleCount > 0 ? 0 : 1)
}

Task { await run() }
RunLoop.main.run()
