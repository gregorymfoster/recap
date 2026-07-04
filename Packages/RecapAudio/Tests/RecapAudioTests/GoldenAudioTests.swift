import AVFoundation
import Accelerate
import Foundation
import Testing
@testable import RecapAudio

/// Runs the real `Fixtures/meeting-fixture.m4a` through the same
/// convert-to-48kHz-mono → `MonoMixer` → `Downsampler3x` path
/// `MeetingRecorder`'s mixer actor uses, and checks the output against
/// constants measured once from an actual run (not guessed) — a coarse
/// end-to-end smoke test that the pipeline doesn't silently mangle audio
/// (wrong sample count, degenerate/near-zero signal, etc.).
@Suite struct GoldenAudioTests {
    /// Measured once by decoding the fixture and running it through
    /// `MonoMixer.mix`/`Downsampler3x.downsample` (see git history of this
    /// file for the one-off probe used to compute these). The fixture is
    /// stable checked-in audio, so these shouldn't drift; a real pipeline
    /// regression (wrong resample ratio, mixer dropping/duplicating samples,
    /// silence where there should be signal) would move them well outside
    /// the tolerances below.
    private enum Golden {
        /// 48kHz mono sample count after decoding + converting the fixture.
        static let mixedSampleCount = 1_492_188
        static let mixedRMS: Float = 0.10461155
        /// After 3:1 downsampling to 16kHz.
        static let downsampledSampleCount = 497_396
        static let downsampledRMS: Float = 0.10354426
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RecapAudioTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // RecapAudio/
            .deletingLastPathComponent() // Packages/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Fixtures/meeting-fixture.m4a")
    }

    /// Decodes the fixture and converts to 48 kHz mono Float32 — the format
    /// every capture source is normalized to before mixing.
    private func decodeTo48kHzMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioPipeline.mixerSampleRate,
                channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: monoFormat)
        else {
            Issue.record("could not build converter")
            return []
        }

        let totalFrames = AVAudioFrameCount(file.length)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: totalFrames) else {
            Issue.record("could not allocate read buffer")
            return []
        }
        try file.read(into: readBuffer)

        let outCapacity = AVAudioFrameCount(
            Double(readBuffer.frameLength) * AudioPipeline.mixerSampleRate / inputFormat.sampleRate
        ) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: outCapacity) else {
            Issue.record("could not allocate output buffer")
            return []
        }
        // The converter's @Sendable input block runs synchronously inside
        // convert(to:) on this thread; the buffer never actually crosses.
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = readBuffer
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }

        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }

    private func rms(_ samples: [Float]) -> Float {
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }

    @Test func mixerAndDownsamplerProduceGoldenLengthAndRMS() throws {
        let url = fixtureURL()
        #expect(FileManager.default.fileExists(atPath: url.path), "fixture missing at \(url.path)")

        let samples = try decodeTo48kHzMono(url)
        #expect(
            abs(samples.count - Golden.mixedSampleCount) <= Golden.mixedSampleCount / 100,
            "decoded 48kHz sample count \(samples.count) drifted >1% from golden \(Golden.mixedSampleCount)"
        )

        // MonoMixer: a single (mic-only) source mixed against silence should
        // pass through unchanged — mirrors mic-only recording.
        let mixed = MonoMixer.mix(samples, [])
        #expect(mixed.count == samples.count)
        let mixedRMS = rms(mixed)
        #expect(
            abs(mixedRMS - Golden.mixedRMS) < 0.01,
            "mixed RMS \(mixedRMS) drifted from golden \(Golden.mixedRMS)"
        )

        // Downsampler3x: 48kHz -> 16kHz, exactly 1/3 the length (minus the
        // <3-sample remainder the mixer actor carries between blocks).
        let usable = mixed.count - mixed.count % 3
        let downsampled = Downsampler3x.downsample(Array(mixed[..<usable]))
        let ratio = Double(downsampled.count) / Double(mixed.count)
        #expect(abs(ratio - 1.0 / 3.0) < 0.001, "downsample ratio \(ratio) should be ~1/3")
        #expect(
            abs(downsampled.count - Golden.downsampledSampleCount) <= Golden.downsampledSampleCount / 100,
            "downsampled count \(downsampled.count) drifted >1% from golden \(Golden.downsampledSampleCount)"
        )

        let downsampledRMS = rms(downsampled)
        #expect(
            abs(downsampledRMS - Golden.downsampledRMS) < 0.01,
            "downsampled RMS \(downsampledRMS) drifted from golden \(Golden.downsampledRMS)"
        )
        // Downsampling (box-filter averaging) is mild lossy compression —
        // RMS should stay close to the pre-downsample signal, not collapse.
        #expect(abs(downsampledRMS - mixedRMS) < 0.02)
    }
}
