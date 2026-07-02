import AVFoundation

/// Converts the crash-safe CAF spool into the canonical AAC m4a, and
/// salvages recordings that died mid-write (crash, power loss, disk full).
public enum AudioTranscoder {
    public enum TranscodeError: Error {
        case unreadableSource
        case cannotCreateDestination
    }

    /// Re-encodes an audio file to 48 kHz mono AAC at `destination`.
    /// Blocking; call off the main actor for long files.
    public static func transcodeToAAC(from source: URL, to destination: URL) throws {
        let reader = try AVAudioFile(forReading: source)
        let format = reader.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAudioFile(
            forWriting: destination, settings: settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else {
            throw TranscodeError.unreadableSource
        }
        // read(into:) throws at EOF rather than returning an empty buffer,
        // so bound the loop on the frame position.
        while reader.framePosition < reader.length {
            try reader.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try writer.write(from: buffer)
        }
    }

    /// If a meeting folder holds a CAF spool without a playable m4a (the app
    /// died mid-recording, or the m4a writer failed), produce the m4a from
    /// the spool. Returns true when a playable m4a exists afterwards.
    /// The spool is only deleted after a successful transcode.
    @discardableResult
    public static func salvageSpool(caf: URL, m4a: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: caf.path) else {
            return fm.fileExists(atPath: m4a.path)
        }
        // An m4a abandoned mid-write has no moov atom and won't open; a
        // readable one wins over the spool.
        if fm.fileExists(atPath: m4a.path), (try? AVAudioFile(forReading: m4a)) != nil {
            try? fm.removeItem(at: caf)
            return true
        }
        do {
            try transcodeToAAC(from: caf, to: m4a)
            try? fm.removeItem(at: caf)
            return true
        } catch {
            // Keep the spool — it's the only copy of the audio.
            try? fm.removeItem(at: m4a)
            return false
        }
    }

    /// Duration of an audio file in seconds, or nil if unreadable.
    public static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0
        else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
