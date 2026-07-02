import Foundation

/// Sums mono sample buffers (mic + system audio) into one stream for
/// transcription. Pure functions — the M4 mixer actor feeds time-aligned
/// buffers through here.
public enum MonoMixer {
    /// Element-wise sum, preserving the longer tail and clamping to [-1, 1].
    public static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let (longer, shorter) = a.count >= b.count ? (a, b) : (b, a)
        var out = longer
        for i in shorter.indices {
            out[i] = max(-1, min(1, out[i] + shorter[i]))
        }
        return out
    }
}
