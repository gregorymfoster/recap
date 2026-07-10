import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import os

private let tapLog = Logger(subsystem: "com.gregfoster.recap", category: "SystemAudioTap")

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
    /// Bumped by every `stop()`. `rebuild()` snapshots it before suspending
    /// into setup and re-checks it afterward — if a `stop()` ran while setup
    /// was in flight, stop wins: the freshly-built Core Audio objects are
    /// destroyed immediately instead of being adopted.
    private var stopGeneration = 0
    /// Guards against overlapping `rebuild()` calls (e.g. a wake notification
    /// firing while a watchdog-driven rebuild is still suspended in setup) —
    /// the second call is simply dropped, the in-flight one finishes the job.
    private var isRebuilding = false
    private var wakeObserver: (any NSObjectProtocol)?

    public init() {}

    /// The Core Audio object IDs the nonisolated setup helper hands back for
    /// the `@MainActor` class to hold. Every field is a plain value type
    /// (`AudioObjectID`/`UInt32` and an `IOProcID`), so this crosses the
    /// actor boundary without needing to be marked unsafe.
    private struct Hardware: Sendable {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
    }

    /// Starts the tap and returns a stream of 48 kHz mono sample blocks.
    ///
    /// The stream (and its continuation) is created exactly ONCE, here — not
    /// inside setup. Setup only binds the IOProc to the continuation it's
    /// given, so `rebuild()` can tear the whole Core Audio graph down and
    /// build a fresh one feeding the *same* stream: the caller's pump task
    /// never sees a stream swap across sleep/wake or death recovery.
    ///
    /// All the blocking Core Audio setup — tap creation (which is what
    /// surfaces the System Audio Recording TCC prompt), aggregate-device
    /// creation, IOProc setup, and `AudioDeviceStart` — runs inside
    /// `performSetup`, a `@concurrent static` helper, so it executes on the
    /// global concurrent executor instead of blocking the main actor while
    /// macOS shows (or waits on) that prompt.
    public func start() async throws -> AsyncStream<[Float]> {
        // Bounded: see `AudioPipeline.capturedStreamBufferedBlocks` — if the
        // mixer actor stalls (slow disk), this stream must not grow without
        // limit while the realtime IOProc callback keeps yielding into it.
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self,
            bufferingPolicy: .bufferingNewest(AudioPipeline.capturedStreamBufferedBlocks)
        )
        let hardware = try await Self.performSetup(feeding: continuation)
        tapID = hardware.tapID
        aggregateID = hardware.aggregateID
        ioProcID = hardware.ioProcID
        self.continuation = continuation
        installWakeObserver()
        return stream
    }

    /// Full teardown-and-re-setup of the Core Audio graph, feeding the same
    /// stream `start()` returned. Called on wake from sleep (the aggregate
    /// device's tap link doesn't survive a sleep cycle) and by the liveness
    /// watchdog's bounded recovery when system samples stop arriving.
    ///
    /// Safe against the lifecycle races around it:
    /// - **Already stopped** (or never started): `continuation` is nil — no-op.
    /// - **Double invocation**: `isRebuilding` drops the overlapping call.
    /// - **Concurrent `stop()`**: stop wins. `stop()` is synchronous on the
    ///   main actor, so it can only interleave while this method is suspended
    ///   in `performSetup`; it bumps `stopGeneration`, tears down whatever
    ///   hardware exists (none — we already tore it down), and finishes the
    ///   stream. When setup resumes, the generation mismatch tells us to
    ///   destroy the freshly-built objects instead of adopting them.
    ///
    /// A failed setup (e.g. permission revoked mid-recording) leaves the tap
    /// torn down but the stream alive; the watchdog's remaining bounded
    /// attempts may try again, and `stop()` still cleans up normally.
    public func rebuild() async {
        guard let continuation, !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        let generation = stopGeneration
        teardownHardware()
        tapLog.info("rebuilding system-audio tap")
        do {
            let hardware = try await Self.performSetup(feeding: continuation)
            guard stopGeneration == generation else {
                // stop() ran while setup was suspended — stop wins.
                Self.teardown(
                    tapID: hardware.tapID, aggregateID: hardware.aggregateID,
                    ioProcID: hardware.ioProcID
                )
                tapLog.info("rebuild abandoned: stop() arrived during setup")
                return
            }
            tapID = hardware.tapID
            aggregateID = hardware.aggregateID
            ioProcID = hardware.ioProcID
            tapLog.info("system-audio tap rebuilt")
        } catch {
            tapLog.error("system-audio tap rebuild failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Does the actual Core Audio work off the main actor, binding the IOProc
    /// to the continuation it's handed (it never creates a stream itself —
    /// see `start()`). Every non-Sendable object it touches
    /// (`CATapDescription`, `AVAudioFormat`, `AVAudioConverter`) is created
    /// and consumed entirely inside this function — only the plain-value IDs
    /// cross back out to the caller (the continuation is `Sendable`).
    ///
    /// `@concurrent` rather than plain `nonisolated`: under the
    /// `NonisolatedNonsendingByDefault` upcoming feature a nonisolated async
    /// function runs on the *caller's* actor — the main actor here — which
    /// would silently reintroduce the TCC-prompt UI freeze this exists to fix.
    @concurrent
    private static func performSetup(
        feeding continuation: AsyncStream<[Float]>.Continuation
    ) async throws -> Hardware {
        // Exclude our own process so playback of past meetings (PlaybackStore's
        // AVAudioPlayer, in the main window) is never re-captured into a new
        // recording running at the same time.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObjectIDs())
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

        return Hardware(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
    }

    /// Resolves this process's own Core Audio "Process object" id via
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`, so the global tap
    /// can exclude it (`CATapDescription`'s exclude list wants Process object
    /// ids, not raw PIDs). Returns an empty array — same as excluding
    /// nothing — if the translation fails; that's not expected in practice
    /// (every running process with any Core Audio client gets a Process
    /// object) but failing open here just means Recap's own audio isn't
    /// excluded, not a crash.
    private nonisolated static func ownProcessObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &processID
            )
        }
        guard status == noErr, processID != kAudioObjectUnknown else { return [] }
        return [processID]
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
        // Signals any rebuild() suspended in setup that stop won the race —
        // it must destroy what it built rather than resurrect the capture.
        stopGeneration &+= 1
        removeWakeObserver()
        teardownHardware()
        continuation?.finish()
        continuation = nil
    }

    /// Destroys the Core Audio graph (IOProc → aggregate device → process
    /// tap, in that order) but leaves the output stream alive — `rebuild()`
    /// uses this to swap graphs under a stable stream; `stop()` follows it
    /// by finishing the continuation.
    private func teardownHardware() {
        Self.teardown(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Sleep/wake

    /// Installed on successful `start()`, removed at `stop()` — mirrors
    /// `MicSource`'s convention. Sleep kills the aggregate device's tap
    /// link, so on wake the whole graph is rebuilt against the same stream.
    private func installWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Explicit hop, not MainActor.assumeIsolated: the block is
            // already dispatched on queue .main, so the Task hop degrades to
            // a scheduling delay rather than trapping if that dispatch-queue
            // ↔ MainActor-executor assumption ever breaks.
            Task { @MainActor [weak self] in
                await self?.rebuild()
            }
        }
    }

    private func removeWakeObserver() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }
}
