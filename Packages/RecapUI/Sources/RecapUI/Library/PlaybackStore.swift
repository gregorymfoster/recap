import AVFoundation
import Foundation
import Observation
import os

/// Playback state for a saved meeting's audio. One instance lives per open
/// meeting (owned by `MeetingDetailView`, injected into the environment so
/// the transcript pane can follow along and seek).
///
/// This is the pinned API surface — `PlayerBar` and `TranscriptPane` build
/// against it. The engine implementation lives behind `load`/`togglePlayPause`
/// /`seek`/`cycleRate`.
///
/// Position updates use a coarse ~4 Hz repeating `Timer`, armed only while
/// `isPlaying` and invalidated on pause/stop/unload — never a per-frame or
/// zero-delay loop (see `Scripts/soak-test.sh` and the project's history of
/// main-thread runaway loops from careless timers).
@MainActor
@Observable
public final class PlaybackStore {
    private static let logger = Logger(subsystem: "com.gregfoster.recap", category: "Playback")

    /// Audio currently loaded, or nil when the meeting has no playable audio.
    public private(set) var audioURL: URL?
    public private(set) var isPlaying = false
    /// Current playhead in seconds. Updated while playing; set via `seek`.
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    /// Playback rate; cycles 1 → 1.5 → 2 → 1.
    public private(set) var rate: Double = 1

    public var hasAudio: Bool { audioURL != nil }

    private var player: AVAudioPlayer?
    private var positionTimer: Timer?
    /// Poll interval for the position timer — coarse on purpose (~4 Hz), well
    /// clear of a per-frame loop.
    private static let positionPollInterval: TimeInterval = 0.25

    public init() {}

    /// Prepare `url` for playback (no autoplay). Replaces any prior load.
    /// A missing or corrupt file leaves the store in the unloaded state
    /// rather than crashing or throwing to the caller.
    public func load(url: URL) {
        stopTimer()
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        duration = 0
        audioURL = nil

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = Float(rate)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            audioURL = url
        } catch {
            Self.logger.error("Failed to load audio for playback: \(error.localizedDescription, privacy: .public)")
            // Stay unloaded — hasAudio is false, PlayerBar/TranscriptPane
            // simply don't show playback UI.
        }
    }

    /// Tear down the player (meeting closed / audio missing).
    public func unload() {
        stopTimer()
        player?.stop()
        player = nil
        audioURL = nil
        isPlaying = false
        position = 0
        duration = 0
        rate = 1
    }

    public func togglePlayPause() {
        guard let player, hasAudio else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            // Playback previously ran to the end — restart from the top.
            if position >= duration, duration > 0 {
                player.currentTime = 0
                position = 0
            }
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    public func seek(to seconds: TimeInterval) {
        guard let player, hasAudio else { return }
        let clamped = max(0, min(seconds, duration))
        player.currentTime = clamped
        position = clamped
    }

    public func cycleRate() {
        switch rate {
        case 1: rate = 1.5
        case 1.5: rate = 2
        default: rate = 1
        }
        player?.rate = Float(rate)
    }

    // MARK: - Position timer

    private func startTimer() {
        stopTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.positionPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func stopTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func tick() {
        guard let player else { return }
        if player.isPlaying {
            position = player.currentTime
        } else {
            // Playback ended naturally (AVAudioPlayer stops itself at the end).
            isPlaying = false
            position = duration
            stopTimer()
        }
    }
}
