import Foundation
import Observation

/// Playback state for a saved meeting's audio. One instance lives per open
/// meeting (owned by `MeetingDetailView`, injected into the environment so
/// the transcript pane can follow along and seek).
///
/// This is the pinned API surface — `PlayerBar` and `TranscriptPane` build
/// against it. The engine implementation lives behind `load`/`togglePlayPause`
/// /`seek`/`cycleRate`.
@MainActor
@Observable
public final class PlaybackStore {
    /// Audio currently loaded, or nil when the meeting has no playable audio.
    public private(set) var audioURL: URL?
    public private(set) var isPlaying = false
    /// Current playhead in seconds. Updated while playing; set via `seek`.
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    /// Playback rate; cycles 1 → 1.5 → 2 → 1.
    public private(set) var rate: Double = 1

    public var hasAudio: Bool { audioURL != nil }

    public init() {}

    /// Prepare `url` for playback (no autoplay). Replaces any prior load.
    public func load(url: URL) {
        audioURL = url
        position = 0
    }

    /// Tear down the player (meeting closed / audio missing).
    public func unload() {
        audioURL = nil
        isPlaying = false
        position = 0
        duration = 0
    }

    public func togglePlayPause() {
        guard hasAudio else { return }
        isPlaying.toggle()
    }

    public func seek(to seconds: TimeInterval) {
        guard hasAudio else { return }
        position = max(0, min(seconds, duration))
    }

    public func cycleRate() {
        switch rate {
        case 1: rate = 1.5
        case 1.5: rate = 2
        default: rate = 1
        }
    }
}
