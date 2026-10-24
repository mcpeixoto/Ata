import SwiftUI

@main
struct AtaWatchApp: App {
    @StateObject private var model = WatchModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchModel.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRecordView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.becameActive() }
                }
        }
    }
}
