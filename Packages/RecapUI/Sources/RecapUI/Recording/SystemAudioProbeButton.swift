import RecapAudio
import SwiftUI

/// Shared "Test" flow for the system-audio permission, used by both the
/// Settings Permissions section and Onboarding: a button that runs
/// `MeetingRecorder.probeSystemAudio()`, shows a spinner while it's in
/// flight, and reports the outcome so the caller can update persisted state
/// (`SettingsStore.lastSystemAudioTapFailed`) and refresh its row.
///
/// Pulled out once so the probe-button state machine isn't duplicated
/// between the two call sites — only the surrounding row chrome differs.
struct SystemAudioProbeButton: View {
    enum ProbeState: Equatable {
        case idle
        case checking
    }

    @State private var probeState: ProbeState = .idle
    let label: String
    let onResult: (SystemAudioProbeResult) -> Void

    init(label: String = "Test", onResult: @escaping (SystemAudioProbeResult) -> Void) {
        self.label = label
        self.onResult = onResult
    }

    var body: some View {
        switch probeState {
        case .idle:
            Button(label) {
                probeState = .checking
                Task {
                    let result = await MeetingRecorder.probeSystemAudio()
                    probeState = .idle
                    onResult(result)
                }
            }
            .controlSize(.small)
            .axID(.systemAudioProbeButton)
        case .checking:
            ProgressView()
                .controlSize(.small)
        }
    }
}
