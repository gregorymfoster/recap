import RecapCore
import SwiftUI

/// Calendar tab: what Recap does when a meeting is detected — via calendar
/// event or call-app audio activity — plus the calendar-access warning when
/// auto-record needs it but doesn't have it (design mock 9b: "Calendar &
/// Detection").
struct SettingsCalendarTab: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("When a meeting is detected", selection: $settings.calendarAutoRecord) {
                    Text("Do nothing").tag(CalendarAutoRecordMode.off)
                    Text("Ask to record").tag(CalendarAutoRecordMode.prompt)
                    Text("Record automatically").tag(CalendarAutoRecordMode.auto)
                }
                .axID(.settingsCalendarAutoRecordPicker)
                .onChange(of: settings.calendarAutoRecord) {
                    stores?.applyCalendarAutoRecordSetting()
                }
                if stores?.calendarAccessDenied == true {
                    Text("Calendar access is off. Allow it in System Settings → Privacy & Security → Calendars.")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.warningAmberText)
                } else {
                    SettingsFootnote("Detects calendar events with a video-call link or invitees, and calls in progress in the apps below. The recording is titled after the event, with attendees attached.")
                }
            }

            Section("Detect calls from") {
                ForEach(CallAppCatalog.apps) { app in
                    Toggle(
                        app.name,
                        isOn: Binding(
                            get: { !settings.disabledCallAppIDs.contains(app.id) },
                            set: { isOn in
                                if isOn {
                                    settings.disabledCallAppIDs.remove(app.id)
                                } else {
                                    settings.disabledCallAppIDs.insert(app.id)
                                }
                                stores?.applyCalendarAutoRecordSetting()
                            }
                        )
                    )
                    .axID(.settingsCallAppToggle(app.id))
                }
                SettingsFootnote("Detection watches audio activity from call apps only — nothing is captured until you record.")
            }
            .disabled(settings.calendarAutoRecord == .off)
        }
        .formStyle(.grouped)
        .navigationTitle("Calendar")
    }
}
