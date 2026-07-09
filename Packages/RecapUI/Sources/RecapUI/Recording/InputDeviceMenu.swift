import RecapAudio
import SwiftUI

/// Reusable input-device picker: lists every `AudioInputDevice` plus "System
/// default", shows the current device's name with a chevron affordance, and
/// calls `onSelect` with the chosen device's `uid` (`nil` for system
/// default). Extracted from `MeetingDetailView.liveInputRow` so the capsule
/// and Settings can share one implementation.
struct InputDeviceMenu: View {
    var devices: [AudioInputDevice]
    /// The persisted preferred device uid; `nil` means "system default".
    var selectedUID: String?
    var onSelect: (String?) -> Void
    /// Callers pick the AXID appropriate to where this menu is mounted
    /// (e.g. `.capsuleDeviceMenu`, `.menuBarDeviceMenu`) since the same
    /// component is reused in several surfaces.
    var axID: AXID

    private var currentName: String {
        guard let selectedUID, let device = devices.first(where: { $0.uid == selectedUID }) else {
            return "System default"
        }
        return device.name
    }

    var body: some View {
        Menu {
            Button("System default") { onSelect(nil) }
            if !devices.isEmpty {
                Divider()
                ForEach(devices) { device in
                    Button(device.name) { onSelect(device.uid) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textTertiary)
                Text(currentName)
                    .font(Tokens.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Tokens.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .axID(axID)
    }
}
