import AVFoundation
import Foundation
import RecapAudio

// Manual verification harness for the capture pipeline (M3/M4).
// Records mic + system audio for N seconds (default 5) to capture-probe.m4a
// in the current directory and prints stream stats. Play some audio while it
// runs to verify the system tap; speak to verify the mic.
//
// Flags:
//   --list-devices        Print input devices (id, name, uid) and exit.
//   --device <uid>         Bind explicitly to this device's persistent UID
//                          (see --list-devices) instead of the system default.
//   --pause-test           Record ~2s → pause ~2s → resume ~2s → stop, then
//                          assert the m4a duration AND stop()'s elapsed are
//                          both ≈4s (±0.5) — proof paused audio isn't written.
//   <seconds>              Positional; how long to record (default 5).

var arguments = Array(CommandLine.arguments.dropFirst())

var pauseTest = false
if let flagIndex = arguments.firstIndex(of: "--pause-test") {
    arguments.remove(at: flagIndex)
    pauseTest = true
}

if let listIndex = arguments.firstIndex(of: "--list-devices") {
    arguments.remove(at: listIndex)
    for device in AudioInputDevices.inputDevices() {
        print("\(device.id)\t\(device.name)\t\(device.uid)")
    }
    exit(0)
}

var deviceUID: String?
if let flagIndex = arguments.firstIndex(of: "--device") {
    let valueIndex = arguments.index(after: flagIndex)
    guard valueIndex < arguments.count else {
        print("FAIL: --device requires a UID (see --list-devices)")
        exit(1)
    }
    deviceUID = arguments[valueIndex]
    arguments.remove(at: valueIndex)
    arguments.remove(at: flagIndex)
}

let seconds = arguments.first.flatMap(Double.init) ?? 5

@MainActor
func run() async {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("capture-probe.m4a")
    try? FileManager.default.removeItem(at: url)

    guard await MeetingRecorder.requestMicPermission() else {
        print("FAIL: microphone permission denied")
        exit(1)
    }

    if let deviceUID {
        guard let device = AudioInputDevices.device(forUID: deviceUID) else {
            print("FAIL: no attached input device with uid \(deviceUID) (see --list-devices)")
            exit(1)
        }
        print("binding explicitly to \(device.name) (\(device.uid))")
    }

    let recorder = MeetingRecorder()
    let output: MeetingRecorder.Output
    do {
        output = try recorder.start(writingTo: url, preferredInputUID: deviceUID)
    } catch {
        print("FAIL: recorder start: \(error)")
        exit(1)
    }
    print("recording \(seconds)s — system audio active: \(recorder.systemAudioActive)")
    print("bound input device: \(recorder.activeInputDeviceName ?? "unknown")")

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

    if pauseTest {
        print("pause test: ~2s record → pause ~2s → resume → ~2s record → stop")
        try? await Task.sleep(for: .seconds(2))
        await recorder.pause()
        print("paused (recorder.isPaused: \(recorder.isPaused))")
        try? await Task.sleep(for: .seconds(2))
        await recorder.resume()
        print("resumed (recorder.isPaused: \(recorder.isPaused))")
        try? await Task.sleep(for: .seconds(2))
    } else {
        try? await Task.sleep(for: .seconds(seconds))
    }
    let duration = await recorder.stop()
    let (chunkCount, sampleCount, peak) = await statsTask.value

    print(String(format: "duration: %.1fs", duration))
    print("16k chunks: \(chunkCount), samples: \(sampleCount) (≈\(sampleCount / 16_000)s)")
    print(String(format: "peak amplitude: %.4f", peak))
    guard let audioFile = try? AVAudioFile(forReading: url) else {
        print("FAIL: output file unreadable")
        exit(1)
    }
    let fileSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
    print(String(format: "file: %@ (%.1fs @ %.0f Hz)", url.lastPathComponent, fileSeconds, audioFile.fileFormat.sampleRate))

    if pauseTest {
        // ~6s of wall time passed but only ~4s were active; both the file on
        // disk and stop()'s returned elapsed must reflect active time only.
        let fileOK = abs(fileSeconds - 4.0) <= 0.5
        let elapsedOK = abs(duration - 4.0) <= 0.5
        print(String(format: "pause test: file %.2fs (want 4±0.5) %@, stop() %.2fs (want 4±0.5) %@",
                     fileSeconds, fileOK ? "OK" : "FAIL",
                     duration, elapsedOK ? "OK" : "FAIL"))
        guard fileOK, elapsedOK else {
            print("FAIL: pause test out of tolerance")
            exit(1)
        }
        print("PASS: paused audio was not written")
    }
    exit(sampleCount > 0 ? 0 : 1)
}

Task { await run() }
RunLoop.main.run()
