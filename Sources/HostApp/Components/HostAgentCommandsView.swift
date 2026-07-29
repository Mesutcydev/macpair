import SwiftUI

/// Quick-reference terminal commands for AI agents and automation scripts.
struct HostAgentCommandsView: View {
    enum Style {
        case settings
        case onboarding
    }

    var style: Style = .settings
    @State private var copiedCommand: String?

    private struct AgentCommand: Identifiable {
        let id: String
        let command: String
        let hint: String
    }

    private let commands: [AgentCommand] = [
        .init(id: "ensure", command: "screenharbor ensure", hint: "Start if needed; exit 0 when ready"),
        .init(id: "status", command: "screenharbor status --json", hint: "Machine-readable status"),
        .init(id: "version", command: "screenharbor version", hint: "Installed app version and build"),
        .init(id: "pending", command: "screenharbor pending", hint: "Inspect pending trust request before approving"),
        .init(id: "approve-pairing", command: "screenharbor approve-pairing --fingerprint <hex>", hint: "Approve only when fingerprint matches"),
        .init(id: "approve-connection", command: "screenharbor approve-connection", hint: "Approve a pending client connection request"),
        .init(id: "open", command: "open -b uk.mesut.screenharbor.host", hint: "Launch the app"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: style == .onboarding ? 12 : 8) {
            if style == .onboarding {
                Text("Cursor, Claude Code, and other agents can start and check this host from Terminal. The website DMG includes an optional CLI installer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Use the `screenharbor` CLI from Terminal to start or verify this host. Install its optional `/usr/local/bin/screenharbor` symlink from the website DMG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(commands) { entry in
                commandRow(entry)
            }

            Link(destination: HostAppLinks.websiteURL) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Full agent docs")
                            .font(style == .onboarding ? .callout : .caption.weight(.medium))
                        Text(HostAppLinks.websiteDisplayPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private func commandRow(_ entry: AgentCommand) -> some View {
        let isCopied = copiedCommand == entry.command
        Button {
            copyCommand(entry.command)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.command)
                        .font(.system(style == .onboarding ? .callout : .caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(entry.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
            }
            .padding(style == .onboarding ? 10 : 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy command")
    }

    private func copyCommand(_ command: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        #endif
        copiedCommand = command
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedCommand == command { copiedCommand = nil }
        }
    }
}
