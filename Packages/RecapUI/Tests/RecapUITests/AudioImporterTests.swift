import AVFoundation
import Foundation
import RecapAudio
import RecapCore
import Testing
@testable import RecapUI

@Suite struct AudioImporterTests {
    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImporterTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    /// A 1-second 440 Hz sine WAV, like a file dragged in from Finder.
    private func writeWAV(at url: URL, seconds: Double = 1.0) throws {
        let sampleRate = 44_100.0
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

    @Test func importsWAVAsQueuedMeetingWithMaterializedM4A() throws {
        let storage = makeStorage()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("Client interview \(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: source) }
        try writeWAV(at: source)

        let record = try AudioImporter(storage: storage).importFile(at: source)

        #expect(record.meeting.status == .queued)
        #expect(record.meeting.title == source.deletingPathExtension().lastPathComponent)
        // Audio is fully materialized as audio.m4a before the record returns.
        #expect(FileManager.default.fileExists(atPath: record.audioURL.path))
        #expect((try? AVAudioFile(forReading: record.audioURL)) != nil)
        // Duration probed from the materialized file and persisted.
        #expect(abs(record.meeting.duration - 1.0) < 0.05)
        let reloaded = try storage.loadAll()
        #expect(reloaded.first?.meeting.duration == record.meeting.duration)
    }

    @Test func m4aSourceIsCopiedVerbatim() throws {
        let storage = makeStorage()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImporterM4A-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("tone.wav")
        try writeWAV(at: wav)
        let m4a = dir.appendingPathComponent("voice memo.m4a")
        try AudioTranscoder.transcodeToAAC(from: wav, to: m4a)
        let sourceBytes = try Data(contentsOf: m4a)

        let record = try AudioImporter(storage: storage).importFile(at: m4a)

        #expect(try Data(contentsOf: record.audioURL) == sourceBytes)
        #expect(abs(record.meeting.duration - 1.0) < 0.1)
    }

    @Test func unreadableSourceThrowsWithoutCreatingAFolder() throws {
        let storage = makeStorage()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(repeating: 0x42, count: 2048).write(to: source)

        #expect(throws: AudioImporter.ImportError.self) {
            try AudioImporter(storage: storage).importFile(at: source)
        }
        #expect((try? storage.loadAll()) ?? [] == [])
    }
}
