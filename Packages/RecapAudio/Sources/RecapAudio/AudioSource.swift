import Foundation
import RecapCore

/// A producer of raw audio buffers. Implementations: microphone (AVAudioEngine),
/// system audio (Core Audio process tap, SCStream fallback).
public protocol AudioSource: Sendable {
    var name: String { get }
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}
