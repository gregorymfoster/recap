import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures everything the Mac is playing (except Recap itself) via a Core
/// Audio process tap — the modern system-audio path that needs only the
/// "System Audio Recording Only" permission, not full Screen Recording.
///
/// Pipeline: global `CATapDescription` → `AudioHardwareCreateProcessTap` →
/// private aggregate device wrapping the tap → IOProc delivering buffers,
/// converted to 48 kHz mono Float32 for the mixer.
@MainActor
public final class SystemAudioTap {
    public enum TapError: Error {
        /// Tap creation failed — most commonly the user denied the
        /// System Audio Recording permission.
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioSetupFailed(OSStatus)
        case formatUnsupported
    }


    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<[Float]>.Continuation?

    public init() {}

    /// Result of the nonisolated setup helper: the IDs the `@MainActor` class
    /// needs to hold plus the stream to hand back to the caller. Every field
    /// is a plain value type (`AudioObjectID`/`UInt32`, an `IOProcID`, and an
    /// `AsyncStream`), so this crosses the actor boundary without needing to
    /// be marked unsafe.
    private struct SetupResult: Sendable {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
        let stream: AsyncStream<[Float]>
        let continuation: AsyncStream<[Float]>.Continuation
    }

    /// Starts the tap and returns a stream of 48 kHz mono sample blocks.
    ///
    /// All the blocking Core Audio setup — tap creation (which is what
    /// surfaces the System Audio Recording TCC prompt), aggregate-device
    /// creation, IOProc setup, and `AudioDeviceStart` — runs inside
    /// `performSetup`, a `nonisolated static` helper, so it executes on the
    /// global concurrent executor instead of blocking the main actor while
    /// macOS shows (or waits on) that prompt.
    public func start() async throws -> AsyncStream<[Float]> {
        let result = try await Self.performSetup()
        tapID = result.tapID
        aggregateID = result.aggregateID
        ioProcID = result.ioProcID
        continuation = result.continuation
        return result.stream
    }

    /// Does the actual Core Audio work off the main actor. Every non-Sendable
    /// object it touches (`CATapDescription`, `AVAudioFormat`,
    /// `AVAudioConverter`) is created and consumed entirely inside this
    /// function — only the plain-value IDs and the stream/continuation (both
    /// `Sendable`) cross back out to the caller.
    ///
    /// `@concurrent` rather than plain `nonisolated`: under the
    /// `NonisolatedNonsendingByDefault` upcoming feature a nonisolated async
    /// function runs on the *caller's* actor — the main actor here — which
    /// would silently reintroduce the TCC-prompt UI freeze this exists to fix.
    @concurrent
    private static func performSetup() async throws -> SetupResult {
        // Exclude our own process so playback of past meetings is never re-captured.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(status)
        }

        // The tap's stream format (typically 48 kHz stereo Float32).
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            teardown(tapID: tapID, aggregateID: AudioObjectID(kAudioObjectUnknown), ioProcID: nil)
            throw TapError.formatUnsupported
        }

        // Private aggregate device that exists only to run the tap's IOProc.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Recap System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            teardown(tapID: tapID, aggregateID: AudioObjectID(kAudioObjectUnknown), ioProcID: nil)
            throw TapError.aggregateCreationFailed(status)
        }

        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioPipeline.mixerSampleRate,
                channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: tapFormat, to: monoFormat)
        else {
            teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: nil)
            throw TapError.formatUnsupported
        }

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)

        // The IO block must be @Sendable so it is nonisolated — it runs on the
        // HAL's realtime IO thread, and a MainActor-inherited closure would
        // trap its dispatch assertion. The converter is used only on that one
        // serial IO thread.
        nonisolated(unsafe) let ioConverter = converter
        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            @Sendable _, inInputData, _, _, _ in
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: tapFormat,
                    bufferListNoCopy: inInputData,
                    deallocator: nil
                ),
                buffer.frameLength > 0,
                let samples = BufferConversion.convert(buffer, using: ioConverter, to: monoFormat)
            else { return }
            continuation.yield(samples)
        }
        guard status == noErr, let ioProcID else {
            teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: nil)
            throw TapError.ioSetupFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
            throw TapError.ioSetupFailed(status)
        }

        return SetupResult(
            tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID,
            stream: stream, continuation: continuation
        )
    }

    /// Static teardown used when setup fails partway through, before any
    /// state has been stored on the (possibly not-yet-touched) instance.
    private nonisolated static func teardown(
        tapID: AudioObjectID, aggregateID: AudioObjectID, ioProcID: AudioDeviceIOProcID?
    ) {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    public func stop() {
        teardown()
    }

    private func teardown() {
        Self.teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        continuation?.finish()
        continuation = nil
    }
}
