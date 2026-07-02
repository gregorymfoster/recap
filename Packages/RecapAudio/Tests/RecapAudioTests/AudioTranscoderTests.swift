import AVFoundation
import Foundation
import Testing
@testable import RecapAudio

@Suite struct AudioTranscoderTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcoder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a 1-second 440 Hz tone as an Int16 LPCM CAF, mirroring the
    /// recorder's spool format.
    private func writeSpool(at url: URL, seconds: Double = 1.0) throws {
        let sampleRate = 48_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sinf(Float(i) * 2 * .pi * 440 / Float(sampleRate)) * 0.5
        }
        try file.write(from: buffer)
    }

    @Test func transcodeProducesReadableAAC() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("audio.caf")
        let m4a = dir.appendingPathComponent("audio.m4a")
        try writeSpool(at: caf)

        try AudioTranscoder.transcodeToAAC(from: caf, to: m4a)

        let duration = try #require(AudioTranscoder.duration(of: m4a))
        #expect(abs(duration - 1.0) < 0.1)
    }

    @Test func salvageBuildsM4AFromOrphanedSpool() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("audio.caf")
        let m4a = dir.appendingPathComponent("audio.m4a")
        try writeSpool(at: caf)

        #expect(AudioTranscoder.salvageSpool(caf: caf, m4a: m4a))
        #expect(FileManager.default.fileExists(atPath: m4a.path))
        // Spool is cleaned up once the m4a is safe.
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        #expect(AudioTranscoder.duration(of: m4a) != nil)
    }

    @Test func salvageReplacesUnreadableM4A() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("audio.caf")
        let m4a = dir.appendingPathComponent("audio.m4a")
        try writeSpool(at: caf)
        // Simulate a crash-abandoned m4a: bytes but no moov atom.
        try Data(repeating: 0xAB, count: 4096).write(to: m4a)

        #expect(AudioTranscoder.salvageSpool(caf: caf, m4a: m4a))
        #expect(AudioTranscoder.duration(of: m4a) != nil)
        #expect(!FileManager.default.fileExists(atPath: caf.path))
    }

    @Test func salvagePrefersHealthyM4A() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("audio.caf")
        let m4a = dir.appendingPathComponent("audio.m4a")
        try writeSpool(at: caf, seconds: 2.0)
        try AudioTranscoder.transcodeToAAC(from: caf, to: m4a)
        let originalDuration = try #require(AudioTranscoder.duration(of: m4a))

        // Spool still present alongside a healthy m4a (crash after the m4a
        // finished): keep the m4a, drop the spool.
        #expect(AudioTranscoder.salvageSpool(caf: caf, m4a: m4a))
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        let duration = try #require(AudioTranscoder.duration(of: m4a))
        #expect(abs(duration - originalDuration) < 0.01)
    }

    @Test func salvageWithNothingToDoReportsMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let caf = dir.appendingPathComponent("audio.caf")
        let m4a = dir.appendingPathComponent("audio.m4a")
        #expect(!AudioTranscoder.salvageSpool(caf: caf, m4a: m4a))
    }
}
