import AVFoundation
import SwiftUI
import UIKit
import UserNotifications

/// The first launch: the microphone, which Ata can't work without, and
/// notifications, which tell you when a transcript is ready.
struct PhoneOnboarding: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var mic = AVAudioApplication.shared.recordPermission
    @State private var notifications = UNAuthorizationStatus.notDetermined

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            AppGlyph(size: 72)
            Text("Welcome to Ata")
                .font(.largeTitle.bold())
            Text("Ata records conversations on this iPhone, even with the screen locked, and turns them into transcripts you can search.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                CheckRow(ok: mic == .granted, title: L("Microphone"),
                         detail: L("To record. Audio stays on this iPhone.")) {
                    Button(mic == .denied ? L("Open Settings") : L("Allow")) { requestMic() }
                        .buttonStyle(.borderedProminent)
                }
                CheckRow(ok: notifications == .authorized || notifications == .provisional,
                         title: L("Notifications"), detail: L("When a transcript is ready."), optional: true) {
                    Button(L("Allow")) { requestNotifications() }
                        .buttonStyle(.bordered)
                        .disabled(notifications == .denied)
                }
            }
            .padding(.horizontal, 4)

            Spacer()

            Button {
                Pref.d.set(true, forKey: Pref.onboarded)
                dismiss()
            } label: {
                Text(mic == .granted ? L("Start using Ata") : L("Not now"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .task { await refresh() }
    }

    private func requestMic() {
        if mic == .denied {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        Task {
            _ = await PhoneRecorder.requestPermission()
            await refresh()
        }
    }

    private func requestNotifications() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refresh()
        }
    }

    private func refresh() async {
        mic = AVAudioApplication.shared.recordPermission
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
