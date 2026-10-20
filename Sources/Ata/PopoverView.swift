import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        switch store.phase {
        case .recording, .stopping:
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                Text(store.elapsedText).monospacedDigit()
            }
        case .starting:
            Image(systemName: "record.circle")
        case .idle:
            if store.transcribingID != nil {
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                    Text("\(Int(store.transcribeProgress * 100))%").monospacedDigit()
                }
            } else if store.detectedApp != nil {
                Image(systemName: "waveform.circle.fill")
            } else {
                Image(systemName: "waveform")
            }
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let missing = setup.missingSummary { setupBanner(missing) }
            if let err = store.lastError { errorBanner(err) }
            recordCard
            if !store.meetings.isEmpty { recent }
            Divider().opacity(0.5)
            footer
        }
        .padding(14)
        .frame(width: 350)
        .onAppear { setup.refresh(); store.reload() }
    }

    // MARK: Cabeçalho

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ata").font(.system(size: 15, weight: .bold, design: .rounded))
                Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { WindowManager.shared.showSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Definições")
        }
    }

    private var statusLine: String {
        switch store.phase {
        case .starting: return "A preparar…"
        case .recording: return "A gravar" + (store.currentApp.map { " · \($0)" } ?? "")
        case .stopping: return "A terminar…"
        case .idle:
            if store.transcribingID != nil { return "A transcrever localmente…" }
            if let app = store.detectedApp { return "Meeting detetada no \(app)" }
            return "Pronta para gravar"
        }
    }

    private func setupBanner(_ text: String) -> some View {
        Button { WindowManager.shared.showOnboarding() } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Termina a configuração").font(.system(size: 12, weight: .semibold))
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.lastError = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.10)))
    }

    // MARK: Gravação

    @ViewBuilder
    private var recordCard: some View {
        Card {
            switch store.phase {
            case .idle, .starting:
                idleContent
            case .recording, .stopping:
                RecordingContent()
            }
        }
    }

    private var idleContent: some View {
        HStack(spacing: 14) {
            RecordButton { store.toggleRecording() }
                .disabled(store.phase == .starting)
                .opacity(store.phase == .starting ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 4) {
                if let app = store.detectedApp {
                    HStack(spacing: 6) {
                        PulsingDot(color: .green)
                        Text("Meeting no \(app)").font(.system(size: 13, weight: .semibold))
                    }
                    Text("Carrega para gravar e transcrever.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(store.phase == .starting ? "A preparar…" : "Gravar meeting")
                        .font(.system(size: 14, weight: .semibold))
                    Text("O teu micro e o som do Mac. Funciona com qualquer app.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .background(
            Button("") { store.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0)
        )
    }

    // MARK: Recentes

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENTES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 2) {
                ForEach(store.meetings.prefix(6)) { m in
                    MeetingRow(meeting: m)
                }
            }
        }
    }

    // MARK: Rodapé

    private var footer: some View {
        HStack(spacing: 2) {
            GhostButton(title: "Pasta", systemImage: "folder") {
                NSWorkspace.shared.open(Paths.meetingsDir)
            }
            Spacer()
            GhostButton(title: "Sair", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }
}

/// Conteúdo do cartão durante a gravação.
private struct RecordingContent: View {
    @EnvironmentObject var store: AppStore
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    PulsingDot()
                    Text(store.phase == .stopping ? "A TERMINAR" : "A GRAVAR")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(store.elapsedText)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            VStack(spacing: 8) {
                meter(Pref.d.string(forKey: Pref.myName) ?? "Eu", icon: "mic.fill",
                      level: store.micLevel, tint: Theme.meTint)
                meter("Outros", icon: "speaker.wave.2.fill", level: store.systemLevel, tint: Theme.othersTint)
            }

            if let w = store.warning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(w).font(.system(size: 11)).foregroundStyle(.orange)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.stopRecording()
                } label: {
                    Label("Parar e transcrever", systemImage: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.record))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store.phase == .stopping)

                Button {
                    if confirmDiscard {
                        store.discardRecording()
                    } else {
                        confirmDiscard = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDiscard = false }
                    }
                } label: {
                    Text(confirmDiscard ? "Apagar?" : "Descartar")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(confirmDiscard ? Color.red.opacity(0.15) : Color.primary.opacity(0.06)))
                        .foregroundStyle(confirmDiscard ? Color.red : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.phase == .stopping)
            }
        }
    }

    private func meter(_ label: String, icon: String, level: Float, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint).frame(width: 14)
            Text(label).font(.system(size: 11, weight: .medium)).frame(width: 56, alignment: .leading)
                .lineLimit(1)
            LevelMeter(level: level, tint: tint)
        }
    }
}

/// Uma meeting na lista de recentes.
struct MeetingRow: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(detailColor).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open() }
        .contextMenu { menu }
    }

    private var isTranscribing: Bool { store.transcribingID == meeting.id }

    private var detail: String {
        switch meeting.status {
        case .failed: return meeting.error ?? "Falhou"
        case .pending: return "Na fila · \(meeting.subtitle)"
        case .recording: return "A gravar…"
        default: return meeting.subtitle
        }
    }

    private var detailColor: Color { meeting.status == .failed ? .red : .secondary }

    private var icon: some View {
        let (symbol, color): (String, Color) = {
            switch meeting.status {
            case .done: return ("doc.text.fill", .accentColor)
            case .failed: return ("exclamationmark.triangle.fill", .red)
            case .recording: return ("record.circle.fill", .red)
            case .pending, .transcribing: return ("hourglass", .orange)
            }
        }()
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.opacity(0.14))
            .frame(width: 28, height: 28)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color))
    }

    @ViewBuilder
    private var trailing: some View {
        if isTranscribing {
            HStack(spacing: 6) {
                ProgressView(value: store.transcribeProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Text("\(Int(store.transcribeProgress * 100))%")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        } else if meeting.status == .failed && meeting.hasAudio {
            Button("Tentar de novo") { store.retry(meeting) }
                .controlSize(.small)
        } else if meeting.status == .done && hover {
            Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if meeting.status == .done {
            Button("Abrir transcrição") { open() }
            Button("Copiar texto") { copy() }
        }
        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.dir]) }
        if meeting.hasAudio && meeting.status != .transcribing && meeting.status != .recording {
            Button("Transcrever de novo") { store.retry(meeting) }
        }
        Divider()
        Button("Apagar", role: .destructive) { store.delete(meeting) }
            .disabled(meeting.status == .recording || isTranscribing)
    }

    private func open() {
        if meeting.status == .done, FileManager.default.fileExists(atPath: meeting.transcriptURL.path) {
            NSWorkspace.shared.open(meeting.transcriptURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([meeting.dir])
        }
    }

    private func copy() {
        guard let text = try? String(contentsOf: meeting.transcriptURL, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
