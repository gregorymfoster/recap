import Foundation
import RecapAudio

// Manual verification harness for per-process call-audio-activity detection
// (design mock 9b). Runs the REAL ProcessAudioMonitor against CoreAudio
// process-object metadata for N seconds and prints each start/stop event as
// it happens. No mic/system audio capture happens here and no TCC prompt is
// involved — only process-level "is running output/input" flags are read.
//
// Usage:
//   swift run call-audio-probe <seconds> [bundleID ...]
//
// Defaults to watching com.apple.Music, com.spotify.client, us.zoom.xos when
// no bundle ids are given.

let arguments = Array(CommandLine.arguments.dropFirst())

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

    monitor.start(bundleIDs: Set(watchedBundleIDs)) { event in
        switch event {
        case .appStartedAudio(let bundleID):
            print("+ \(bundleID) started audio")
        case .appStoppedAudio(let bundleID):
            print("- \(bundleID) stopped audio")
        }
    }

    try? await Task.sleep(for: .seconds(seconds))

    monitor.stop()
    print("done")
}

await run()
exit(0)
