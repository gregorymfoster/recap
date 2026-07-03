import Foundation
import RecapCore

/// Mic capture as `MeetingRecorder` consumes it. `MicSource` is the real
/// implementation; tests inject a fake exposing a canned sample stream.
@MainActor
public protocol MicCapturing: AnyObject {
    /// The device the user picked in Settings, by persistent UID. `nil` means
    /// "system default".
    var preferredInputUID: String? { get set }
    /// Called after the capture graph was rebuilt mid-recording.
    var onRebuild: (@MainActor (String) -> Void)? { get set }
    /// The mic device actually in use, for display.
    var activeDeviceName: String? { get }
    func start() throws -> AsyncStream<[Float]>
    func stop()
}

/// System-audio capture as `MeetingRecorder` consumes it. `SystemAudioTap` is
/// the real implementation; tests inject a fake exposing a canned sample
/// stream.
@MainActor
public protocol SystemAudioCapturing: AnyObject {
    func start() async throws -> AsyncStream<[Float]>
    func stop()
}

extension MicSource: MicCapturing {}
extension SystemAudioTap: SystemAudioCapturing {}
