import SwiftUI

struct VampTerminalWorkspaceView: View {
    @ObservedObject var workspace: TerminalWorkspaceViewModel
    @ObservedObject var coordinator: ClientSessionCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var showingStartupCommand = false
    @State private var startupCommandPrefix = ""
    @State private var startupCommandInput = ""
    @State private var startupCommandTitle = "Attach terminal session"

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar

            ZStack {
                Color.black
                ForEach(workspace.tabs) { tab in
                    VampTerminalPaneView(
                        session: tab.session,
                        isActive: workspace.selectedTabID == tab.id,
                        onSendClipboardToHost: { _ = workspace.sendClipboardToHost() },
                        onRequestClipboardFromHost: { _ = workspace.requestClipboardFromHost() },
                        onTerminalClipboard: { text in
                            _ = workspace.sendClipboardTextToHost(text)
                        }
                    )
                    .id(tab.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = workspace.lastTerminalError {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(VampGlassPalette.warning)
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .lineLimit(2)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .vampGlassSurface(.card, cornerRadius: 0)
                    .vampGlassOutline(cornerRadius: 0, color: VampGlassPalette.warning.opacity(0.30))
            }
            if let message = workspace.clipboardStatusMessage {
                HStack(spacing: 9) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .vampGlassSurface(.card, cornerRadius: 0)
                .vampGlassOutline(cornerRadius: 0)
            }
        }
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let sessionID = coordinator.activeSessionID {
                workspace.activate(sessionID: sessionID)
            }
        }
        .onChange(of: coordinator.activeSessionID) { _, sessionID in
            if let sessionID {
                workspace.activate(sessionID: sessionID)
            } else {
                workspace.stop()
            }
        }
        .onDisappear {
            workspace.stop()
        }
        .alert("Rename terminal", isPresented: $showingRename) {
            TextField("Terminal name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let renameTargetID {
                    workspace.rename(tabID: renameTargetID, title: renameText)
                }
            }
        } message: {
            Text("Choose a short name for this shell tab.")
        }
        .alert(startupCommandTitle, isPresented: $showingStartupCommand) {
            TextField("session-name", text: $startupCommandInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Open") {
                let argument = startupCommandInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !argument.isEmpty else { return }
                _ = workspace.createTab(startupCommand: startupCommandPrefix + shellQuote(argument))
                startupCommandInput = ""
            }
        } message: {
            Text("Vamp Terminal opens a fresh PTY, then runs the command. Use tmux or screen to resume a shell or agent that is already running on the Mac.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VampGlassIconTile(systemImage: "terminal.fill", size: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(coordinator.connectedHostName ?? "Vamp Terminal")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(VampGlassPalette.good)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(coordinator.connectionMode.label)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await coordinator.endSession() }
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VampGlassPalette.ink)
                    .frame(minWidth: 44, minHeight: 44)
                    .vampGlassSurface(.button, cornerRadius: 11)
                    .vampGlassOutline(cornerRadius: 11, color: VampGlassPalette.ruleStrong)
            }
            .buttonStyle(VampGlassPressStyle())
            .accessibilityLabel("Disconnect from Mac")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .vampGlassSurface(.toolbar, cornerRadius: 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VampGlassPalette.ruleStrong)
                .frame(height: 0.5)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(workspace.tabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            Menu {
                Button {
                    _ = workspace.createTab()
                } label: {
                    Label("New shell", systemImage: "terminal")
                }

                Section("Resume a session") {
                    Button {
                        presentStartupCommand(
                            title: "Attach tmux session",
                            prefix: "tmux new-session -A -s "
                        )
                    } label: {
                        Label("Attach / create tmux", systemImage: "rectangle.split.2x1")
                    }
                    Button {
                        presentStartupCommand(
                            title: "Attach GNU screen",
                            prefix: "screen -r "
                        )
                    } label: {
                        Label("Attach screen", systemImage: "rectangle.on.rectangle")
                    }
                }

                Section("Agent launchers") {
                    agentCommandButton("Claude Code", command: "claude", session: "claude")
                    agentCommandButton("Codex CLI", command: "codex", session: "codex")
                    agentCommandButton("Aider", command: "aider", session: "aider")
                    agentCommandButton("OpenCode", command: "opencode", session: "opencode")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(workspace.canCreateTab ? VampGlassPalette.ink : VampGlassPalette.inkSubtle)
                    .frame(minWidth: 44, minHeight: 44)
                    .vampGlassSurface(.button, cornerRadius: 11)
                    .vampGlassOutline(cornerRadius: 11, color: VampGlassPalette.ruleStrong)
            }
            .buttonStyle(VampGlassPressStyle())
            .disabled(!workspace.canCreateTab)
            .accessibilityLabel("New terminal tab")
            .accessibilityValue(workspace.tabCountLabel)
            .accessibilityHint(workspace.canCreateTab ? "Opens another independent shell" : "Terminal capacity reached")
            .padding(.trailing, 10)
        }
        .vampGlassSurface(.toolbar, cornerRadius: 0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VampGlassPalette.ruleStrong).frame(height: 0.5)
        }
    }

    private func tabChip(_ tab: TerminalWorkspaceViewModel.Tab) -> some View {
        let selected = workspace.selectedTabID == tab.id
        return HStack(spacing: 0) {
            Button {
                workspace.select(tabID: tab.id)
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(dotColor(for: tab.state))
                        .frame(width: 7, height: 7)
                    Text(tab.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(selected ? VampGlassPalette.ink : VampGlassPalette.inkSecondary)
                        .lineLimit(1)
                    if tab.hasUnreadOutput {
                        Circle()
                            .fill(VampGlassPalette.ink)
                            .frame(width: 5, height: 5)
                            .accessibilityLabel("Unread output")
                    }
                }
                .padding(.leading, 11)
                .padding(.trailing, workspace.tabs.count > 1 ? 6 : 11)
                .frame(minHeight: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityValue(accessibilityValue(for: tab, selected: selected))
            .accessibilityHint("Select this terminal")

            if workspace.tabs.count > 1 {
                Button {
                    workspace.close(tabID: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                        .frame(width: 32, height: 34)
                }
                .buttonStyle(VampGlassPressStyle())
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .vampGlassSurface(.tab, cornerRadius: 9)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.035))
        }
        .vampGlassOutline(
            cornerRadius: 9,
            color: selected ? VampGlassPalette.ruleStrong : VampGlassPalette.rule
        )
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(selected ? VampGlassPalette.ink : .clear)
                .frame(width: 24, height: 2)
                .offset(y: 1)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.92),
                    value: selected
                )
        }
        .contextMenu {
            Button {
                renameTargetID = tab.id
                renameText = tab.title
                showingRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                workspace.close(tabID: tab.id)
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
    }

    private func dotColor(for state: ClientTerminalSessionManager.State) -> Color {
        switch state {
        case .open: return VampGlassPalette.good
        case .opening: return VampGlassPalette.warning
        case .idle: return VampGlassPalette.inkSubtle
        case .closed: return VampGlassPalette.bad
        }
    }

    private func accessibilityValue(
        for tab: TerminalWorkspaceViewModel.Tab,
        selected: Bool
    ) -> String {
        let state: String
        switch tab.state {
        case .idle: state = "waiting"
        case .opening: state = "opening"
        case .open: state = "connected"
        case .closed: state = "closed"
        }
        let unread = tab.hasUnreadOutput ? ", unread output" : ""
        return "\(selected ? "selected, " : "")\(state)\(unread)"
    }

    private func presentStartupCommand(title: String, prefix: String) {
        startupCommandTitle = title
        startupCommandPrefix = prefix
        startupCommandInput = ""
        showingStartupCommand = true
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func agentCommandButton(_ title: String, command: String, session: String) -> some View {
        Button {
            _ = workspace.createTab(startupCommand: "tmux new-session -A -s \(session) -- \(command)")
        } label: {
            Label(title, systemImage: "sparkles")
        }
    }
}
