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

    /// Starts the tap and returns a stream of 48 kHz mono sample blocks.
    public func start() throws -> AsyncStream<[Float]> {
        // Exclude our own process so playback of past meetings is never re-captured.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(status)
        }
        self.tapID = tapID

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
            teardown()
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
            teardown()
            throw TapError.aggregateCreationFailed(status)
        }
        self.aggregateID = aggregateID

        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioPipeline.mixerSampleRate,
                channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: tapFormat, to: monoFormat)
        else {
            teardown()
            throw TapError.formatUnsupported
        }

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation

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
            teardown()
            throw TapError.ioSetupFailed(status)
        }
        self.ioProcID = ioProcID

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw TapError.ioSetupFailed(status)
        }
        return stream
    }

    public func stop() {
        teardown()
    }

    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        continuation?.finish()
        continuation = nil
    }
}
