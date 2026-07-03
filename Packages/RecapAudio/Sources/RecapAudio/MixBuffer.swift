import Foundation

/// Shared constants for the capture → mix → transcribe pipeline.
public enum AudioPipeline {
    /// Common rate both sources are converted to before mixing. Must stay an
    /// integer multiple of 16 kHz for `Downsampler3x`.
    public static let mixerSampleRate: Double = 48_000
}

/// Alignment buffer for the two capture streams (mic + system audio).
///
/// Both sources deliver 48 kHz mono continuously, so pairwise draining keeps
/// them aligned. If one side stalls (tap permission denied, device vanished),
/// the other must not back up forever: past `starvationThreshold` samples the
/// stalled side is padded with silence so recording keeps flowing.
struct MixBuffer {
    /// ~2 s at 48 kHz before declaring the quiet side stalled.
    var starvationThreshold = 96_000
    /// When false (mic-only recording), mic samples pass straight through
    /// instead of waiting for a system-audio counterpart.
    var systemActive = true
    /// When false (system-audio-only recording, e.g. mic access denied),
    /// system samples pass straight through instead of waiting for a mic
    /// counterpart — mirror image of `systemActive`.
    var micActive = true

    private(set) var mic: [Float] = []
    private(set) var system: [Float] = []

    mutating func pushMic(_ samples: [Float]) -> [Float] {
        guard systemActive else { return samples }
        mic.append(contentsOf: samples)
        return drain()
    }

    mutating func pushSystem(_ samples: [Float]) -> [Float] {
        guard micActive else { return samples }
        system.append(contentsOf: samples)
        return drain()
    }

    private mutating func drain() -> [Float] {
        let n = min(mic.count, system.count)
        if n > 0 {
            let out = MonoMixer.mix(Array(mic[..<n]), Array(system[..<n]))
            mic.removeFirst(n)
            system.removeFirst(n)
            return out
        }
        // One side is empty. Flush the other if it has backed up past the threshold.
        if mic.count > starvationThreshold {
            let out = mic
            mic = []
            return out
        }
        if system.count > starvationThreshold {
            let out = system
            system = []
            return out
        }
        return []
    }

    /// Mixes whatever is left, zero-padding the shorter side. Call at stop.
    mutating func flushRemainder() -> [Float] {
        let out = MonoMixer.mix(mic, system)
        mic = []
        system = []
        return out
    }
}

/// 48 kHz → 16 kHz mono by averaging each group of three samples.
/// Box-filter decimation is adequate anti-aliasing for speech-to-text input.
enum Downsampler3x {
    static func downsample(_ samples: [Float]) -> [Float] {
        let outCount = samples.count / 3
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let base = i * 3
            out[i] = (samples[base] + samples[base + 1] + samples[base + 2]) / 3
        }
        return out
    }
}
