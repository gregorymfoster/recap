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
//   --json                 In addition to the normal human-readable output,
//                          print exactly one JSON object as the LAST line of
//                          stdout, e.g.:
//                            {"ok":true,"seconds":5,"micFrames":240000,
//                             "systemFrames":240000,"chunks":5,
//                             "peakAmplitude":0.1234,"fileSeconds":5.0,
//                             "systemAudioActive":true,"pauseTest":null}
//                          With --list-devices, prints the device list as a
//                          JSON array instead: [{"id":1,"name":"…","uid":"…"}]
//                          Exit codes are unchanged: 0 success, 1 failure.

/// Last-line machine-readable summary for `--json` (capture-run mode).
/// `micFrames`/`systemFrames` are independent per-source 48 kHz sample
/// totals read from `MeetingRecorder.sampleCounts()` — NOT derived from the
/// mixed 16 kHz chunk stream, so if system audio contributes nothing (tap
/// silently stalled, permission denied) `systemFrames` reads 0 while
/// `micFrames` stays > 0, instead of the two being forced equal. `pauseTest`
/// is the pass/fail of `--pause-test` tolerance checks, or omitted when
/// `--pause-test` was not passed.
struct ProbeResult: Codable {
    var ok: Bool
    var seconds: Double
    var micFrames: Int
    var systemFrames: Int
    var chunks: Int
    var peakAmplitude: Float
    var fileSeconds: Double
    var systemAudioActive: Bool
    var pauseTest: Bool?
}

/// Machine-readable device entry for `--list-devices --json`.
struct DeviceEntry: Codable {
    var id: UInt32
    var name: String
    var uid: String
}

func printJSON(_ value: some Encodable) {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(value), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

var arguments = Array(CommandLine.arguments.dropFirst())

let jsonOutput = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }

var pauseTest = false
if let flagIndex = arguments.firstIndex(of: "--pause-test") {
    arguments.remove(at: flagIndex)
    pauseTest = true
}

if let listIndex = arguments.firstIndex(of: "--list-devices") {
    arguments.remove(at: listIndex)
    let devices = AudioInputDevices.inputDevices()
    if jsonOutput {
        printJSON(devices.map { DeviceEntry(id: $0.id, name: $0.name, uid: $0.uid) })
    } else {
        for device in devices {
            print("\(device.id)\t\(device.name)\t\(device.uid)")
        }
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

    func failEarly(_ message: String) -> Never {
        print(message)
        if jsonOutput {
            printJSON(ProbeResult(
                ok: false, seconds: seconds, micFrames: 0, systemFrames: 0,
                chunks: 0, peakAmplitude: 0, fileSeconds: 0,
                systemAudioActive: false, pauseTest: nil
            ))
        }
        exit(1)
    }

    guard await MeetingRecorder.requestMicPermission() else {
        failEarly("FAIL: microphone permission denied")
    }

    if let deviceUID {
        guard let device = AudioInputDevices.device(forUID: deviceUID) else {
            failEarly("FAIL: no attached input device with uid \(deviceUID) (see --list-devices)")
        }
        print("binding explicitly to \(device.name) (\(device.uid))")
    }

    let recorder = MeetingRecorder()
    let output: MeetingRecorder.Output
    do {
        output = try await recorder.start(writingTo: url, preferredInputUID: deviceUID)
    } catch {
        failEarly("FAIL: recorder start: \(error)")
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
    let sourceCounts = await recorder.sampleCounts()

    print(String(format: "duration: %.1fs", duration))
    print("16k chunks: \(chunkCount), samples: \(sampleCount) (≈\(sampleCount / 16_000)s)")
    print("mic samples: \(sourceCounts.mic) (48kHz), system samples: \(sourceCounts.system) (48kHz)")
    print(String(format: "peak amplitude: %.4f", peak))
    guard let audioFile = try? AVAudioFile(forReading: url) else {
        failEarly("FAIL: output file unreadable")
    }
    let fileSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
    print(String(format: "file: %@ (%.1fs @ %.0f Hz)", url.lastPathComponent, fileSeconds, audioFile.fileFormat.sampleRate))

    var pauseTestPassed: Bool?
    if pauseTest {
        // ~6s of wall time passed but only ~4s were active; both the file on
        // disk and stop()'s returned elapsed must reflect active time only.
        let fileOK = abs(fileSeconds - 4.0) <= 0.5
        let elapsedOK = abs(duration - 4.0) <= 0.5
        print(String(format: "pause test: file %.2fs (want 4±0.5) %@, stop() %.2fs (want 4±0.5) %@",
                     fileSeconds, fileOK ? "OK" : "FAIL",
                     duration, elapsedOK ? "OK" : "FAIL"))
        pauseTestPassed = fileOK && elapsedOK
        if pauseTestPassed == true {
            print("PASS: paused audio was not written")
        } else {
            print("FAIL: pause test out of tolerance")
        }
    }

    let ok = sampleCount > 0 && (pauseTestPassed ?? true)
    if jsonOutput {
        printJSON(ProbeResult(
            ok: ok, seconds: seconds, micFrames: sourceCounts.mic, systemFrames: sourceCounts.system,
            chunks: chunkCount, peakAmplitude: peak, fileSeconds: fileSeconds,
            systemAudioActive: recorder.systemAudioActive, pauseTest: pauseTestPassed
        ))
    }
    exit(ok ? 0 : 1)
}

Task { await run() }
RunLoop.main.run()
