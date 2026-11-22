import SwiftUI

/// The first tab. Idle is the home: a greeting, the record button, what is
/// being transcribed, recent meetings and the free minutes. While recording,
/// and while the file is saved, the timer leads and the same button stops it.
/// What shows when is decided in `RecordHomeModel`.
struct RecordView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var savedToast = false
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                switch RecordHomeModel.layout(isRecording: store.isRecording, isStopping: store.phase == .stopping) {
                case .idle: RecordHomeIdle()
                case .recording: RecordHomeRecording()
                }
            }
            .navigationTitle("Ata")
            // The greeting is the title on the home; a bar above it would say "Ata" twice.
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) {
                if savedToast { toast }
            }
            .onAppear { store.clearMicrophoneDenialIfGranted() }
            .onChange(of: store.phase) { old, new in
                guard RecordHomeModel.showsSavedToast(wasStopping: old == .stopping, isIdle: new == .idle,
                                                      failed: store.lastError != nil) else { return }
                showToast()
            }
        }
    }

    private var toast: some View {
        Text("Saved. Transcribing now.")
            .ataHeadline()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, Theme.Space.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func showToast() {
        toastTask?.cancel()
        withAnimation { savedToast = true }
        UIAccessibility.post(notification: .announcement, argument: L("Saved. Transcribing now."))
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { savedToast = false }
        }
    }
}
