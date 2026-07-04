import Foundation

/// Pure message-formatting for the mic-loss toast (design mock 6c): fired
/// when the recorder rebuilds its input mid-recording, most commonly because
/// the active mic was unplugged and macOS fell back to another device.
/// Extracted from `AppStores`' `MeetingSessionStore.onInputRebuilt` wiring so
/// the copy is testable without constructing the whole store graph.
enum MicLossToast {
    /// - Parameters:
    ///   - reason: The raw `RecorderEvent.inputRebuilt` reason string (e.g.
    ///     "input device disconnected"). Only used when no device name
    ///     could be resolved, so the toast still says *something* useful.
    ///   - deviceName: The mic now in use, when known — preferred over
    ///     `reason` since it matches the design copy exactly ("switched to
    ///     <device>").
    static func message(reason: String, deviceName: String?) -> String {
        if let deviceName, !deviceName.isEmpty {
            return "Mic disconnected — switched to \(deviceName)"
        }
        let trimmed = reason.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Mic disconnected — switched input device" }
        return "Mic disconnected — \(trimmed)"
    }
}
