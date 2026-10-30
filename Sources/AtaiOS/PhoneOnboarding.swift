import AVFoundation
import SwiftUI
import UIKit
import UserNotifications

/// The first launch: the microphone, which Ata can't work without, your name,
/// which an iPhone app can't read for itself, and notifications, which tell you
/// when a transcript is ready.
struct PhoneOnboarding: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(Pref.myName) private var myName = ""
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
            Text("Ask the people you record first. In many places it is the law.")
                .font(.footnote)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Your name")
                    .font(.subheadline.weight(.semibold))
                TextField("Your name in the transcript", text: $myName, prompt: Text("Me"))
                    .textContentType(.givenName)
                    .textFieldStyle(.roundedBorder)
                Text("Your lines are marked with this name. Ata also tells the other people in the room apart, and you name each voice once in People.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Pref.d.set(true, forKey: Pref.onboarded)
                dismiss()
            } label: {
                Text(mic == .granted ? L("Start using Ata") : L("Not now"))
                    .frame(maxWidth: .infinity)
            }
            // Without the microphone, Allow is the one thing to press; a second
            // filled button saying "Not now" would compete with it.
            .modifier(FinishStyle(primary: mic == .granted))
            .controlSize(.large)
        }
        .padding(24)
        .task { await refresh() }
    }

    private struct FinishStyle: ViewModifier {
        let primary: Bool

        func body(content: Content) -> some View {
            if primary {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
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
