import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel
    @AppStorage(Pref.autoDetect) private var autoDetect = true
    @AppStorage(Pref.autoStart) private var autoStart = false
    @AppStorage(Pref.onboarded) private var onboarded = false

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Permissões") {
                        CheckRow(ok: setup.mic, title: "Microfone",
                                 detail: "Para gravar a tua voz.") {
                            Button("Permitir") { setup.requestMic() }
                        }
                        Divider()
                        CheckRow(ok: setup.screen, title: "Áudio do sistema",
                                 detail: setup.screenNeedsRelaunch
                                    ? "Ativa a Ata na lista e depois reabre a app."
                                    : "Para gravar os outros participantes. O macOS chama-lhe \"Gravação de ecrã e áudio do sistema\"; só usamos o som.") {
                            HStack {
                                if setup.screenNeedsRelaunch {
                                    Button("Reabrir") { setup.relaunch() }
                                }
                                Button("Permitir") { setup.requestScreen() }
                            }
                        }
                        Divider()
                        CheckRow(ok: setup.notifications, title: "Notificações", detail: "Avisa quando deteta uma meeting e quando a transcrição fica pronta.",
                                 optional: true) {
                            Button("Permitir") { setup.requestNotifications() }
                        }
                    }

                    section("Transcrição local") {
                        CheckRow(ok: setup.whisper, title: "Motor whisper.cpp",
                                 detail: setup.whisperStatus ?? (setup.hasBrew
                                    ? "Instalado via Homebrew. Usa a GPU do teu Mac."
                                    : "Precisa do Homebrew (brew.sh).")) {
                            if setup.installingWhisper {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(setup.hasBrew ? "Instalar" : "Abrir brew.sh") { setup.installWhisper() }
                            }
                        }
                        Divider()
                        CheckRow(ok: setup.model, title: "Modelo Whisper large-v3-turbo",
                                 detail: setup.downloadError ?? "1.6 GB, descarregado uma vez. Português e inglês com ótima qualidade.") {
                            if let p = setup.downloadProgress {
                                VStack(alignment: .trailing, spacing: 2) {
                                    ProgressView(value: p).frame(width: 110)
                                    Text("\(Int(p * 100))%").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            } else {
                                Button(setup.downloadError == nil ? "Descarregar" : "Tentar de novo") { setup.downloadModels() }
                            }
                        }
                    }

                    section("Comportamento") {
                        Toggle(isOn: Binding(get: { autoDetect }, set: { store.setAutoDetect($0); autoDetect = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Detetar meetings automaticamente").font(.system(size: 13, weight: .semibold))
                                Text("Quando o Slack, Zoom, Meet, Teams… começam a usar o micro.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        if autoDetect {
                            Picker("Quando deteto uma meeting", selection: $autoStart) {
                                Text("Perguntar com notificação").tag(false)
                                Text("Gravar automaticamente").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            .font(.system(size: 12))
                        }
                        Divider()
                        Toggle(isOn: Binding(get: { setup.launchAtLogin }, set: { setup.setLaunchAtLogin($0) })) {
                            Text("Abrir a Ata ao iniciar sessão").font(.system(size: 13, weight: .semibold))
                        }
                        .toggleStyle(.switch)
                    }
                }
                .padding(24)
            }
            footer
        }
        .frame(width: 520, height: 640)
        .onAppear { setup.refresh() }
        .onReceive(poll) { _ in setup.refresh() }
        .onChange(of: setup.ready) { _, ready in if ready { store.setupChanged() } }
    }

    private var hero: some View {
        ZStack {
            Theme.brand.opacity(0.9)
            VStack(spacing: 10) {
                AppGlyph(size: 64)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.35)))
                Text("Bem-vindo à Ata").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Grava e transcreve qualquer meeting, 100% no teu Mac.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 18)
        }
        .frame(height: 190)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    private var footer: some View {
        HStack {
            if setup.ready {
                Label("Tudo pronto", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Text(setup.missingSummary ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(setup.ready ? "Começar" : "Fechar") {
                onboarded = true
                store.setupChanged()
                WindowManager.shared.closeOnboarding()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }
}
