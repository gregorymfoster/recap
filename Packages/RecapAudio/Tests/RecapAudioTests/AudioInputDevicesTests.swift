import Testing
@testable import RecapAudio

@Suite struct AudioInputDevicesTests {
    private let mic = AudioInputDevice(id: 1, name: "MacBook Pro Microphone", uid: "builtin-mic")
    private let airpods = AudioInputDevice(id: 2, name: "Greg's AirPods Pro", uid: "airpods-uid")

    @Test func resolveFindsDeviceByUID() {
        let devices = [mic, airpods]
        #expect(AudioInputDevices.resolve(uid: "airpods-uid", in: devices) == airpods)
    }

    @Test func resolveNilUIDMeansSystemDefault() {
        let devices = [mic, airpods]
        #expect(AudioInputDevices.resolve(uid: nil, in: devices) == nil)
    }

    @Test func resolveFallsBackWhenPreferredDeviceVanished() {
        // The AirPods were preferred but are no longer attached.
        let devices = [mic]
        #expect(AudioInputDevices.resolve(uid: "airpods-uid", in: devices) == nil)
    }

    @Test func rebuildReasonNamesTheResolvedDevice() {
        let devices = [mic, airpods]
        #expect(AudioInputDevices.rebuildReason(forPreferredUID: "airpods-uid", in: devices)
            == "input switched to Greg's AirPods Pro")
    }

    @Test func rebuildReasonFallsBackToSystemDefaultWhenUnresolvable() {
        let devices = [mic]
        #expect(AudioInputDevices.rebuildReason(forPreferredUID: "airpods-uid", in: devices)
            == "input switched to system default")
    }

    @Test func rebuildReasonForNilUIDIsSystemDefault() {
        let devices = [mic, airpods]
        #expect(AudioInputDevices.rebuildReason(forPreferredUID: nil, in: devices)
            == "input switched to system default")
    }
}
