import SwiftUI

@main
struct AtaPhoneApp: App {
    @StateObject private var store = PhoneStore.shared
    @StateObject private var navigation = PhoneNavigation.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The screenshot run starts from fixtures instead; see PhoneSnapshots.swift.
        if Snapshots.rendering {
            Snapshots.setUp()
            return
        }
        Notifier.shared.setUp()
        // Before anything can record: a purchase made while Ata was closed, or a renewal.
        ProStore.shared.start()
        PhoneStore.shared.bootstrap()
        WatchLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(navigation)
                .tint(Theme.meTint)
                .preferredColorScheme(Snapshots.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, !Snapshots.rendering { store.becameActive() }
                }
                // "Open in Ata" from Files or another app: audio becomes a meeting.
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    navigation.tab = .meetings
                    store.importAudio([url])
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
        .sheet(isPresented: $navigation.showingPaywall) {
            Paywall()
        }
    }
}
