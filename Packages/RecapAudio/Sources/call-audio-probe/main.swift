import Foundation
import RecapAudio

// Manual verification harness for per-process call-audio-activity detection
// (design mock 9b). Runs the REAL ProcessAudioMonitor against CoreAudio
// process-object metadata for N seconds and prints each start/stop event as
// it happens. No mic/system audio capture happens here and no TCC prompt is
// involved — only process-level "is running output/input" flags are read.
//
// Usage:
//   swift run call-audio-probe <seconds> [bundleID ...] [--json]
//
// Defaults to watching com.apple.Music, com.spotify.client, us.zoom.xos when
// no bundle ids are given.
//
// --json: in addition to the normal human-readable output, prints exactly one
// JSON object as the LAST line of stdout, e.g.:
//   {"ok":true,"events":3,"started":2,"stopped":1,"watched":["com.apple.Music"]}
// The probe already runs for a bounded `seconds` and exits on its own, so
// --json needs no extra bounding — it just summarizes what was observed
// during that fixed window. Exit codes are unchanged: 0 success (always,
// since zero events is a valid outcome — there is no failure mode here
// beyond a usage error).

/// Last-line machine-readable summary for `--json`.
struct ProbeResult: Codable {
    var ok: Bool
    var events: Int
    var started: Int
    var stopped: Int
    var watched: [String]
}

func printJSON(_ result: ProbeResult) {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(result), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let jsonOutput = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }

let seconds = arguments.first.flatMap(Double.init) ?? 5
let bundleIDArguments = arguments.count > 1 ? Array(arguments.dropFirst()) : []
let watchedBundleIDs = bundleIDArguments.isEmpty
    ? ["com.apple.Music", "com.spotify.client", "us.zoom.xos"]
    : bundleIDArguments

print("watching \(watchedBundleIDs.count) app(s) for \(seconds)s: \(watchedBundleIDs.joined(separator: ", "))")
print("play/pause Music.app (or start/stop the other watched apps) to see events; zero events is fine if nothing played.")

@MainActor
func run() async {
    // Short poll interval for a snappy manual-test loop; startAfterPolls/
    // stopAfterPolls keep their production defaults (2 / 40) unless the
    // probe's short runtime warrants faster feedback, which it doesn't need
    // to prove wiring is correct.
    let monitor = ProcessAudioMonitor(pollInterval: .seconds(1))

    var startedCount = 0
    var stoppedCount = 0
    monitor.start(bundleIDs: Set(watchedBundleIDs)) { event in
        switch event {
        case .appStartedAudio(let bundleID):
            startedCount += 1
            print("+ \(bundleID) started audio")
        case .appStoppedAudio(let bundleID):
            stoppedCount += 1
            print("- \(bundleID) stopped audio")
        }
    }

    try? await Task.sleep(for: .seconds(seconds))

    monitor.stop()
    print("done")

    if jsonOutput {
        printJSON(ProbeResult(
            ok: true, events: startedCount + stoppedCount, started: startedCount,
            stopped: stoppedCount, watched: watchedBundleIDs
        ))
    }
}

await run()
exit(0)
