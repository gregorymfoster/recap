import AVFoundation
import Foundation
import os

private let fixtureAudioLog = Logger(subsystem: "com.gregfoster.recap", category: "FixtureAudio")

/// Generates a short silent `.m4a` for `-fixtures` mode so the player bar
/// (design handoff v2 §8d) has something real to dock and scrub, instead of
/// the `/dev/null` every other fixture record points at.
///
/// Fixture mode is disk-light by contract (no writes to the user's real
/// library), so this writes into a throwaway temp folder rather than
/// `~/Recap` — same spirit as the `-soak` graph's temp root in
/// `AppStores.init`.
enum FixtureAudio {
    /// Writes a `duration`-second silent mono `.m4a` into a fresh temp
    /// folder and returns that folder's URL (the file itself is named
    /// `audio.m4a`, matching `MeetingRecord.audioURL`'s expected layout).
    /// Fast (<200ms) — a few hundred KB of AAC-encoded silence, encoded
    /// synchronously via `AVAudioFile` rather than any real-time engine.
    /// Returns nil (leaving the fixture meeting's `/dev/null` folder as-is)
    /// if anything goes wrong — a missing player bar in a screenshot is far
    /// better than a fixture launch that throws or hangs.
    static func makeSilentMeetingFolder(duration: TimeInterval = 40) -> URL? {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapFixtureAudio-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let fileURL = folderURL.appendingPathComponent("audio.m4a")

            let sampleRate: Double = 44_100
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                return nil
            }
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            let file = try AVAudioFile(forWriting: fileURL, settings: outputSettings, commonFormat: .pcmFormatFloat32, interleaved: false)

            let frameCount = AVAudioFrameCount(sampleRate * duration)
            // Write in ~1s chunks rather than one giant buffer — keeps peak
            // memory low and stays well under the 200ms budget either way.
            let chunkFrames = AVAudioFrameCount(sampleRate)
            var framesRemaining = frameCount
            while framesRemaining > 0 {
                let thisChunk = min(chunkFrames, framesRemaining)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: thisChunk) else { break }
                buffer.frameLength = thisChunk
                // Buffer is zero-initialized by AVAudioPCMBuffer — silence,
                // no need to touch the channel data explicitly.
                try file.write(from: buffer)
                framesRemaining -= thisChunk
            }
            return folderURL
        } catch {
            fixtureAudioLog.error("Failed to generate fixture audio: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: folderURL)
            return nil
        }
    }
}
