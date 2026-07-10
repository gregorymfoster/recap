import AVFoundation

/// Seam around the one blocking call `MixerEngine`'s write path makes per
/// block: `AVAudioFile.write(from:)`. On a slow-but-succeeding disk this can
/// stall for a long time without ever throwing — the whole reason the write
/// path lives on its own background task instead of the mixer actor. Tests
/// inject a fake to prove the moved failure-counting still trips
/// `.writeFailed` exactly as before, without needing a real slow disk.
protocol AudioFileWriting: Sendable {
    func write(_ buffer: AVAudioPCMBuffer) throws
}

/// Production adapter: thin wrapper around `AVAudioFile.write(from:)`.
/// `AVAudioFile` is itself `Sendable` (checked against the SDK), so this
/// needs no unsafe opt-out — it only ever holds an immutable reference to it.
final class AVAudioFileWriter: AudioFileWriting {
    private let file: AVAudioFile

    init(file: AVAudioFile) {
        self.file = file
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
    }
}
