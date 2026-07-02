import CoreAudio

/// One input-capable Core Audio device, as shown in the picker.
///
/// `AudioDeviceID` isn't stable across reboots or replugs — only `uid` is
/// worth persisting (in `SettingsStore.preferredInputUID`). Resolve the UID
/// back to a live `AudioDeviceID` at the point of use.
public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String

    public init(id: AudioDeviceID, name: String, uid: String) {
        self.id = id
        self.name = name
        self.uid = uid
    }
}

/// Enumerates Core Audio input devices and reports when the device list
/// changes (plug/unplug), so pickers can stay live.
///
/// A plain enum namespace, not a class: enumeration is a handful of
/// synchronous `AudioObjectGetPropertyData` calls, cheap enough to re-run
/// on demand rather than cache. Sendable-correct — the change-notification
/// block is `@Sendable` and only ever calls back through a `@Sendable`
/// closure, never captures actor state.
public enum AudioInputDevices {
    /// A fresh property-address value per call (it's just a description
    /// struct, not shared state) — keeps this enum free of mutable statics,
    /// which Swift 6 strict concurrency would otherwise flag.
    private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// All devices exposing at least one input channel, sorted by name.
    public static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap(inputDevice(for:)).sorted { $0.name < $1.name }
    }

    /// Resolves a persisted UID to a currently-attached device, if any.
    public static func device(forUID uid: String) -> AudioInputDevice? {
        resolve(uid: uid, in: inputDevices())
    }

    /// Pure lookup, factored out of `device(forUID:)` so the "preferred
    /// device present vs. vanished → fall back" decision is testable without
    /// touching Core Audio.
    public static func resolve(uid: String?, in devices: [AudioInputDevice]) -> AudioInputDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// The reason string surfaced when the preferred device changes: names
    /// the target device when it resolves, otherwise falls back to "system
    /// default". Pure — takes the device list as input so it's testable
    /// without touching Core Audio.
    public static func rebuildReason(forPreferredUID uid: String?, in devices: [AudioInputDevice]) -> String {
        guard let device = resolve(uid: uid, in: devices) else {
            return "input switched to system default"
        }
        return "input switched to \(device.name)"
    }

    /// Registers a listener for device plug/unplug. Returns a token to pass
    /// to `removeListener`. The block hops to the given queue (`.main` is
    /// typical) before calling `onChange`, mirroring `MicSource`'s pattern
    /// for the default-input listener.
    @discardableResult
    public static func addDeviceListListener(
        queue: DispatchQueue, onChange: @escaping @Sendable () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        var address = deviceListAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        )
        return listener
    }

    public static func removeDeviceListListener(_ listener: @escaping AudioObjectPropertyListenerBlock) {
        var address = deviceListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
        )
    }

    // MARK: Enumeration internals

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    /// Builds an `AudioInputDevice` for `id` if it has at least one input
    /// channel; returns nil for output-only devices.
    private static func inputDevice(for id: AudioDeviceID) -> AudioInputDevice? {
        guard inputChannelCount(for: id) > 0 else { return nil }
        guard let name = deviceName(for: id), let uid = deviceUID(for: id) else { return nil }
        return AudioInputDevice(id: id, name: name, uid: uid)
    }

    private static func inputChannelCount(for id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }
        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }
        status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferListPointer)
        guard status == noErr else { return 0 }
        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    private static func deviceUID(for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String
    }
}
