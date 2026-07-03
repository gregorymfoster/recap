import SwiftUI

/// Calendar tab: what Recap does when a calendar meeting starts, plus the
/// calendar-access warning when auto-record needs it but doesn't have it.
struct SettingsCalendarTab: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("When a calendar meeting starts", selection: $settings.calendarAutoRecord) {
                    Text("Do nothing").tag(CalendarAutoRecordMode.off)
                    Text("Ask to record").tag(CalendarAutoRecordMode.prompt)
                    Text("Record automatically").tag(CalendarAutoRecordMode.auto)
                }
                .onChange(of: settings.calendarAutoRecord) {
                    stores?.applyCalendarAutoRecordSetting()
                }
                if stores?.calendarAccessDenied == true {
                    Text("Calendar access is off. Allow it in System Settings → Privacy & Security → Calendars.")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.warningAmberText)
                } else {
                    SettingsFootnote("Detects events with a video-call link or invitees. The recording is titled after the event, with attendees attached.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendar")
    }
}
