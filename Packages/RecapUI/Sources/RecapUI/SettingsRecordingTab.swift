import CoreAudio
import RecapAudio
import RecapCore
import SwiftUI

/// Recording tab: input device, system audio capture, the global shortcut
/// (informational — the recorder is not rebindable), processing priority
/// (also informational — always low), pause-on-battery, speaker labeling,
/// and transcription language.
struct SettingsRecordingTab: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueStore.self) private var queue: QueueStore?
    @State private var inputDevices: [AudioInputDevice] = AudioInputDevices.inputDevices()
    @State private var deviceListListener: AudioObjectPropertyListenerBlock?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Input device", selection: $settings.preferredInputUID) {
                    Text("System default").tag(String?.none)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .onChange(of: settings.preferredInputUID) {
                    stores?.session.setPreferredInputUID(settings.preferredInputUID)
                }
                Toggle("Capture system audio", isOn: $settings.includeSystemAudio)
                LabeledContent("Start or stop recording anywhere") {
                    Text("⌥⌘R")
                        .font(Tokens.meta.monospacedDigit())
                        .foregroundStyle(Tokens.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusButton))
                }
                SettingsFootnote("Uses macOS's System Audio Recording permission to capture other participants. Switching input devices mid-recording keeps the file writing — expect a brief gap. The shortcut works even when Recap isn't the active app.")
            }
            .onAppear {
                inputDevices = AudioInputDevices.inputDevices()
                deviceListListener = AudioInputDevices.addDeviceListListener(queue: .main) {
                    Task { @MainActor in inputDevices = AudioInputDevices.inputDevices() }
                }
            }
            .onDisappear {
                if let deviceListListener {
                    AudioInputDevices.removeDeviceListListener(deviceListListener)
                }
                deviceListListener = nil
            }

            Section {
                LabeledContent("Processing priority", value: "Low — never interrupts")
                Toggle("Pause processing on battery", isOn: $settings.pausesOnBattery)
                    .onChange(of: settings.pausesOnBattery) {
                        queue?.setPausesOnBattery(settings.pausesOnBattery)
                    }
                SettingsFootnote("Transcription and note enhancement always run at low priority so they never interrupt what you're doing; on battery they wait until you're plugged in.")
            }

            Section {
                Toggle("Label speakers in transcripts", isOn: $settings.labelsSpeakers)
                Picker("Transcription language", selection: $settings.transcriptionLanguage) {
                    Text("Auto-detect").tag(String?.none)
                    ForEach(TranscriptionLanguages.common) { language in
                        Text(language.displayName).tag(String?.some(language.code))
                    }
                }
                SettingsFootnote("Speaker labeling runs on-device and downloads a small model (~50 MB) the first time; if it isn't ready yet, transcripts are simply unlabeled. Auto-detect works well for most meetings — force a language for short or heavily accented recordings.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recording")
    }
}
