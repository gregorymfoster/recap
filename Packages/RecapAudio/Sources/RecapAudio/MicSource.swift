import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import RecapCore

/// Shared buffer→[Float] conversion used by both capture sources.
/// Runs on capture queues; touches only objects owned by its caller.
enum BufferConversion {
    static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        // The converter's @Sendable input block runs synchronously inside
        // convert(to:) on this thread; the buffer never actually crosses.
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

/// Microphone capture: AVAudioEngine input tap converted to 48 kHz mono
/// Float32 blocks for the mixer.
///
/// The capture graph is rebuilt in place when the default input device
/// changes (AirPods connect/disconnect), when the engine reports a
/// configuration change (device sample-rate switch), or on wake from sleep —
/// the same output stream keeps flowing, at most a short gap. Without this,
/// AVAudioEngine keeps pulling from the device it started with and a
/// disconnect turns the rest of the meeting into silence.
@MainActor
public final class MicSource {
    public enum MicError: Error {
        case permissionDenied
        case formatUnsupported
    }

    private var engine = AVAudioEngine()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var rebuildDebounce: Task<Void, Never>?
    private var notificationTokens: [any NSObjectProtocol] = []
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    /// The device the user picked in Settings, by persistent UID
    /// (`AudioDeviceID`s aren't stable across reboots/replugs). `nil` means
    /// "system default" — today's behavior. Setting this mid-recording
    /// schedules a rebuild that rebinds the engine to the new device.
    public var preferredInputUID: String? {
        didSet {
            guard oldValue != preferredInputUID else { return }
            scheduleRebuild(reason: preferredDeviceRebuildReason())
        }
    }

    /// The device actually bound after the last (re)build — may differ from
    /// `preferredInputUID` if that device wasn't resolvable, in which case
    /// this reports the system-default fallback.
    public private(set) var activeDeviceName: String?

    /// Called after the capture graph was rebuilt mid-recording.
    public var onRebuild: (@MainActor (String) -> Void)?

    public init() {}

    public static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    public func start() throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        try attachTapAndStart()
        observeConfigurationChanges()
        return stream
    }

    public func stop() {
        rebuildDebounce?.cancel()
        rebuildDebounce = nil
        removeObservers()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        activeDeviceName = nil
    }

    // MARK: Capture graph

    private func attachTapAndStart() throws {
        guard let continuation else { return }
        bindPreferredDeviceIfPossible()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard
            format.sampleRate > 0,
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioPipeline.mixerSampleRate,
                channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: format, to: monoFormat)
        else { throw MicError.formatUnsupported }

        // @Sendable keeps the tap block nonisolated — it runs on the engine's
        // capture queue, never the main actor. The converter is used only on
        // that one serial queue.
        let tapConverter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            if let samples = BufferConversion.convert(buffer, using: tapConverter, to: monoFormat) {
                continuation.yield(samples)
            }
        }
        try engine.start()
    }

    /// Binds the engine's AUHAL input unit to `preferredInputUID` when it
    /// resolves to a currently-attached device; otherwise leaves the engine
    /// on the system default (today's behavior). Must run before the input
    /// node's format/tap are touched — changing the AU's device changes its
    /// output format.
    private func bindPreferredDeviceIfPossible() {
        guard let preferredInputUID, let device = AudioInputDevices.device(forUID: preferredInputUID) else {
            activeDeviceName = systemDefaultInputName()
            return
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            activeDeviceName = systemDefaultInputName()
            return
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        activeDeviceName = status == noErr ? device.name : systemDefaultInputName()
    }

    private func systemDefaultInputName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return nil }
        return AudioInputDevices.inputDevices().first { $0.id == deviceID }?.name
    }

    /// Reason string for a preferred-device change, naming the target device
    /// when one is being switched to (surfaced verbatim in the UI).
    private func preferredDeviceRebuildReason() -> String {
        AudioInputDevices.rebuildReason(forPreferredUID: preferredInputUID, in: AudioInputDevices.inputDevices())
    }

    /// Tears down the engine and rebuilds against the current default input.
    /// Debounced: a device switch fires several notifications back to back.
    private func scheduleRebuild(reason: String) {
        guard continuation != nil else { return }
        rebuildDebounce?.cancel()
        rebuildDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.rebuildNow(reason: reason)
        }
    }

    private func rebuildNow(reason: String) {
        guard continuation != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // A fresh engine binds to the new default device and its format.
        engine = AVAudioEngine()
        do {
            try attachTapAndStart()
            onRebuild?(reason)
        } catch {
            // No usable input right now (e.g. device vanished with no
            // fallback). The next device change retries.
        }
    }

    // MARK: Change observation

    private func observeConfigurationChanges() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            // These callbacks are already dispatched on queue .main, so an
            // explicit hop just degrades to a scheduling delay rather than
            // trapping if that dispatch-queue↔MainActor-executor assumption
            // ever breaks — safe here since scheduleRebuild only starts a
            // 400ms-debounced rebuild.
            Task { @MainActor [weak self] in
                self?.scheduleRebuild(reason: "engine configuration changed")
            }
        })
        notificationTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRebuild(reason: "woke from sleep")
            }
        })

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleRebuild(reason: "default input changed")
            }
        }
        defaultInputListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, .main, listener
        )

        // A preferred device that's currently unplugged should bind as soon
        // as it reappears, not just wait for the (unrelated) default-input
        // notification.
        deviceListListener = AudioInputDevices.addDeviceListListener(queue: .main) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.preferredInputUID != nil else { return }
                self.scheduleRebuild(reason: self.preferredDeviceRebuildReason())
            }
        }
    }

    private func removeObservers() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationTokens = []
        if let listener = defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, .main, listener
            )
            defaultInputListener = nil
        }
        if let listener = deviceListListener {
            AudioInputDevices.removeDeviceListListener(listener)
            deviceListListener = nil
        }
    }
}
