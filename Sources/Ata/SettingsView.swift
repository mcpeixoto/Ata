import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel
    @AppStorage(Pref.autoDetect) private var autoDetect = true
    @AppStorage(Pref.autoStart) private var autoStart = false
    @AppStorage(Pref.autoStop) private var autoStop = true
    @AppStorage(Pref.keepAudio) private var keepAudio = false
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.myName) private var myName = "Eu"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppGlyph(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Definições").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Ata 2.0 · tudo corre localmente no teu Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 34)
            .padding(.bottom, 8)

            Form {
                Section("Gravação") {
                    Toggle("Detetar meetings automaticamente", isOn: Binding(
                        get: { autoDetect }, set: { store.setAutoDetect($0); autoDetect = $0 }))
                    Picker("Quando deteto uma meeting", selection: $autoStart) {
                        Text("Perguntar").tag(false)
                        Text("Gravar automaticamente").tag(true)
                    }
                    .disabled(!autoDetect)
                    Toggle("Parar sozinho quando a meeting acaba", isOn: $autoStop)
                        .disabled(!autoDetect)
                }

                Section("Transcrição") {
                    TextField("O teu nome na transcrição", text: $myName)
                    Picker("Idioma", selection: $language) {
                        Text("Automático").tag("auto")
                        Text("Português").tag("pt")
                        Text("English").tag("en")
                        Text("Español").tag("es")
                        Text("Français").tag("fr")
                    }
                    Toggle("Guardar o áudio depois de transcrever", isOn: $keepAudio)
                }

                Section("Sistema") {
                    Toggle("Abrir ao iniciar sessão", isOn: Binding(
                        get: { setup.launchAtLogin }, set: { setup.setLaunchAtLogin($0) }))
                    LabeledContent("Estado") {
                        if setup.ready {
                            Label("Tudo pronto", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Resolver…") { WindowManager.shared.showOnboarding() }
                        }
                    }
                    LabeledContent("Pasta das meetings") {
                        Button("Abrir") { NSWorkspace.shared.open(Paths.meetingsDir) }
                    }
                }

                Section {
                    Text("Avisa sempre os participantes de que estás a gravar. Usa auscultadores para a transcrição separar melhor quem fala.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 600)
        .onAppear { setup.refresh() }
    }
}
