#if os(macOS)
import SwiftUI

/// Auto-detect, the shortcut, calendar and work/personal.
struct SettingsRecordingPane: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var setup: SetupModel

    @AppStorage(Pref.autoDetect) private var autoDetect = true
    @AppStorage(Pref.autoStart) private var autoStart = false
    @AppStorage(Pref.autoStop) private var autoStop = true
    @AppStorage(Pref.calendarPrompt) private var calendarPrompt = false
    @AppStorage(Pref.calendarLeadMinutes) private var calendarLeadMinutes = 1
    @AppStorage(Pref.calendarPeopleOnly) private var calendarPeopleOnly = true
    @AppStorage(Pref.defaultCategory) private var defaultCategory = ""
    @State private var recordShortcut: Shortcut? = Hotkey.current
    @State private var calendarCategories = MeetingCategory.calendarMap

    var body: some View {
        Form {
            recordingSection
            calendarSection
            categorySection
        }
        .settingsForm()
    }

    private var recordingSection: some View {
        Section("Recording") {
            if FreeQuota.appliesOnMac {
                LabeledContent("Free minutes", value: L("%d of %d free minutes left this month",
                                                         FreeQuota.remaining(used: store.freeUsed),
                                                         FreeQuota.limitMinutes))
            }
            Toggle("Detect meetings automatically", isOn: Binding(
                get: { autoDetect }, set: { store.setAutoDetect($0); autoDetect = $0 }))
            Picker("When a meeting is detected", selection: $autoStart) {
                Text("Ask me").tag(false)
                Text("Start recording").tag(true)
            }
            .disabled(!autoDetect)
            Toggle("Stop on its own when the meeting ends", isOn: $autoStop)
                .disabled(!autoDetect)
            if autoDetect, !autoStart, !setup.notifications {
                LabeledContent {
                    Button("Allow") { setup.requestNotifications() }
                } label: {
                    SettingsNote(L("Without notifications, Ata can't ask you when it notices a meeting."), tone: .warning)
                }
            }
            LabeledContent("Record from anywhere") {
                ShortcutField(shortcut: $recordShortcut) { new in
                    Hotkey.set(new) { AppStore.shared.toggleRecording() }
                }
                .frame(width: 140, height: 22)
                // An NSView has no text baseline, so LabeledContent lined the
                // field's bottom edge up with the label's baseline and the field
                // sat below it. Give it one, a little under its middle, where its
                // own 11–12 pt text sits.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            if recordShortcut != nil, !Hotkey.isRegistered, !Snapshots.rendering {
                SettingsNote(L("Another app already uses that combination. Try a different one."), tone: .warning)
            } else {
                SettingsNote(L("Starts or stops recording without going near the icon, from whatever app you are in."))
            }
        }
    }

    private var calendarSection: some View {
        Section("Calendar") {
            Toggle("Offer to record meetings on my calendar", isOn: Binding(
                get: { calendarPrompt },
                set: { on in
                    calendarPrompt = on
                    if on, !setup.calendar { setup.requestCalendar() } else { store.calendarChanged() }
                }))
            if calendarPrompt {
                Picker("How long before", selection: $calendarLeadMinutes) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in
                        Text(minutes == 1 ? L("A minute") : L("%d minutes", minutes)).tag(minutes)
                    }
                }
                .onChange(of: calendarLeadMinutes) { _, _ in store.calendarChanged() }
                Toggle("Only events with other people invited", isOn: $calendarPeopleOnly)
                    .onChange(of: calendarPeopleOnly) { _, _ in store.calendarChanged() }
                if !setup.calendar {
                    LabeledContent(L("Access")) {
                        Button(L("Allow")) { setup.requestCalendar() }
                    }
                }
            }
            SettingsNote(calendarFootnote,
                         tone: calendarPrompt && !setup.calendar ? .warning : .secondary)
        }
    }

    private var categorySection: some View {
        Section("Work and personal") {
            Picker("New meetings", selection: $defaultCategory) {
                Text("No category").tag("")
                ForEach(MeetingCategory.allCases) { c in Text(c.name).tag(c.rawValue) }
            }
            if setup.calendar {
                ForEach(CalendarStore.shared.calendars(), id: \.id) { calendar in
                    Picker(calendar.title, selection: Binding(
                        get: { calendarCategories[calendar.id] ?? "" },
                        set: { value in
                            calendarCategories[calendar.id] = value.isEmpty ? nil : value
                            MeetingCategory.calendarMap = calendarCategories
                        })) {
                        Text("No category").tag("")
                        ForEach(MeetingCategory.allCases) { c in Text(c.name).tag(c.rawValue) }
                    }
                }
            }
            SettingsNote(setup.calendar
                 ? L("A meeting from one of these calendars gets its category. Otherwise Ata goes by the app: Zoom, Teams or Slack is work, FaceTime or WhatsApp is personal. You can change it in the meeting.")
                 : L("Ata goes by the app: Zoom, Teams or Slack is work, FaceTime or WhatsApp is personal. Allow the calendar above to choose per calendar. You can change it in the meeting."))
        }
    }

    /// What this will actually do, given everything else that is switched on. A
    /// setting that quietly does nothing is worse than one that says why.
    private var calendarFootnote: String {
        if calendarPrompt, !setup.calendar, setup.calendarAskWasSilent {
            return L("macOS did not ask. Turn Ata on under Calendars in System Settings → Privacy & Security.")
        }
        if calendarPrompt, !setup.calendar {
            return setup.calendarDenied
                ? L("Ata cannot read your calendar. Turn it on under Calendars in System Settings → Privacy & Security.")
                : L("Ata needs permission to read your calendar.")
        }
        if calendarPrompt, !setup.notifications {
            return L("Turn on notifications for Ata and the prompt arrives there. Until then the next meeting shows in Ata's window.")
        }
        if calendarPrompt, autoStart {
            return L("Recording starts on its own when the meeting does, because \"When a meeting is detected\" is set to start recording.")
        }
        if calendarPrompt {
            return L("A notification before the meeting, with a Record button. The recording is filed under the event's title, and the people invited are what Ata offers when it asks whose voice it heard.")
        }
        return L("Ata reads the calendars already in Calendar.app, your Google account included. Nothing leaves your Mac, and Ata never writes to a calendar.")
    }
}
#endif
