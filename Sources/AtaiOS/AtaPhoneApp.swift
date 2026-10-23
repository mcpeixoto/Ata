import SwiftUI

@main
struct AtaPhoneApp: App {
    @StateObject private var store = PhoneStore.shared
    @StateObject private var navigation = PhoneNavigation.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Notifier.shared.setUp()
        PhoneStore.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(navigation)
                .tint(Theme.meTint)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.becameActive() }
                }
        }
    }
}

/// Five tabs: record, the meetings, the people Ata knows, insights, settings.
struct RootView: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var navigation: PhoneNavigation

    var body: some View {
        TabView(selection: $navigation.tab) {
            RecordView()
                .tabItem { Label("Record", systemImage: "mic.circle.fill") }
                .tag(PhoneNavigation.Tab.record)
            MeetingsList()
                .tabItem { Label("Meetings", systemImage: "list.bullet.rectangle") }
                .tag(PhoneNavigation.Tab.meetings)
            NavigationStack {
                ScrollView { PeopleView().padding() }
                    .navigationTitle("People")
            }
            .tabItem { Label("People", systemImage: "person.2.fill") }
            .tag(PhoneNavigation.Tab.people)
            NavigationStack {
                ScrollView { InsightsView().padding() }
                    .navigationTitle("Insights")
            }
            .tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }
            .tag(PhoneNavigation.Tab.insights)
            PhoneSettings()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(PhoneNavigation.Tab.settings)
        }
        .sheet(isPresented: $navigation.showingOnboarding) {
            PhoneOnboarding()
                .interactiveDismissDisabled()
        }
    }
}
