#if os(macOS)
import SwiftUI

/// MCP: agents on this Mac can read meetings.
struct SettingsAgentPane: View {
    @AppStorage(Pref.agentAccess) private var agentAccess = false
    @State private var agentCopied = false

    private var agentExecutable: String {
        Bundle.main.executablePath ?? "Ata"
    }

    var body: some View {
        Form {
            Section("Connect your agent") {
                Toggle("Let AI agents on this Mac read your meetings", isOn: $agentAccess)
                SettingsNote(L("Claude, Cursor and other agents that speak MCP can list, search and read your meetings. Ata itself sends nothing. What an agent reads, it may send to its own AI provider. Agents cannot change or delete anything."))
                if agentAccess {
                    Text(verbatim: AgentConfiguration.json(executable: agentExecutable))
                        .ataFont(11, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Theme.Space.s)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(Color.primary.opacity(0.05)))
                    if !InstallLocation.isSettled(Bundle.main.bundlePath, home: NSHomeDirectory()) {
                        SettingsNote(L("Move Ata to the Applications folder first. This path stops working if the app moves."))
                    }
                    Button("Copy configuration") {
                        Platform.actions.copy(AgentConfiguration.json(executable: agentExecutable))
                        agentCopied = true
                    }
                    if agentCopied {
                        Label("Copied.", systemImage: "checkmark.circle.fill")
                            .ataCaption()
                            .foregroundStyle(.green)
                            .task {
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                agentCopied = false
                            }
                    }
                    SettingsNote(L("Paste it into your agent's MCP settings. For Claude Code: %@",
                                   AgentConfiguration.claudeCode(executable: agentExecutable)))
                }
            }
        }
        .settingsForm()
    }
}
#endif
