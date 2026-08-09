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
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar

            ZStack {
                Color.black
                if workspace.tabs.isEmpty {
                    emptyWorkspaceState
                }
                ForEach(workspace.tabs) { tab in
                    VampTerminalPaneView(
                        session: tab.session,
                        isActive: workspace.selectedTabID == tab.id,
                        provider: tab.provider,
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
                HStack(spacing: VampTerminalDesign.space2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(VampGlassPalette.warning)
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .lineLimit(3)
                    if workspace.hasStalledTab {
                        Spacer(minLength: 6)
                        Button("Retry") {
                            workspace.retryStalledTabs()
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(VampGlassPalette.ink)
                        .padding(.horizontal, VampTerminalDesign.space3)
                        .frame(minHeight: VampTerminalDesign.minTapTarget)
                        .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                        .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                        .buttonStyle(VampGlassPressStyle())
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, VampTerminalDesign.space4)
                    .padding(.vertical, VampTerminalDesign.space3)
                    .vampGlassSurface(.card, cornerRadius: 0)
                    .vampGlassOutline(cornerRadius: 0, color: VampGlassPalette.warning.opacity(0.30))
            }
            if let message = workspace.clipboardStatusMessage {
                HStack(spacing: VampTerminalDesign.space2) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                    Text(message)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VampTerminalDesign.space4)
                .padding(.vertical, VampTerminalDesign.space2)
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
        .alert("Disconnect from Mac?", isPresented: $showingDisconnectConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                Task { await coordinator.endSession() }
            }
        } message: {
            Text("All active terminal tabs on this connection will close. Use tmux or screen if you need to reconnect later.")
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
        HStack(spacing: VampTerminalDesign.space3) {
            VampGlassIconTile(systemImage: "terminal.fill", size: 38)

            VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
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

            Spacer(minLength: VampTerminalDesign.space2)

            Button {
                showingDisconnectConfirmation = true
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VampGlassPalette.ink)
                    .frame(minWidth: VampTerminalDesign.minTapTarget, minHeight: VampTerminalDesign.minTapTarget)
                    .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                    .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius, color: VampGlassPalette.ruleStrong)
            }
            .buttonStyle(VampGlassPressStyle())
            .accessibilityLabel("Disconnect from Mac")
            .accessibilityHint("Asks for confirmation before ending every terminal")
        }
        .padding(.horizontal, VampTerminalDesign.space4)
        .padding(.vertical, VampTerminalDesign.space2)
        .vampGlassSurface(.toolbar, cornerRadius: 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VampGlassPalette.ruleStrong)
                .frame(height: 0.5)
        }
    }

    private var emptyWorkspaceState: some View {
        VStack(spacing: VampTerminalDesign.space3) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(VampGlassPalette.inkSecondary)
            Text("No terminal tabs")
                .font(.headline)
                .foregroundStyle(VampGlassPalette.ink)
            Text("Open a new shell to continue. Existing tabs stay alive when you switch between them.")
                .font(.footnote)
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                _ = workspace.createTab()
            } label: {
                Label("New terminal", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VampGlassPalette.ink)
                    .padding(.horizontal, VampTerminalDesign.space4)
                    .frame(minHeight: VampTerminalDesign.minTapTarget)
                    .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                    .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius, color: VampGlassPalette.ruleStrong)
            }
            .buttonStyle(VampGlassPressStyle())
            .disabled(!workspace.canCreateTab)
        }
        .padding(VampTerminalDesign.space6)
        .frame(maxWidth: 360)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.largeCardRadius, color: VampGlassPalette.ruleStrong)
        .accessibilityElement(children: .contain)
    }

    private var tabBar: some View {
        HStack(spacing: VampTerminalDesign.space2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VampTerminalDesign.space2) {
                    ForEach(workspace.tabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, VampTerminalDesign.space3)
                .padding(.vertical, VampTerminalDesign.space2)
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
                    ForEach(VampAgentProvider.allCases) { provider in
                        agentCommandButton(provider)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(workspace.canCreateTab ? VampGlassPalette.ink : VampGlassPalette.inkSubtle)
                    .frame(minWidth: VampTerminalDesign.minTapTarget, minHeight: VampTerminalDesign.minTapTarget)
                    .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                    .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius, color: VampGlassPalette.ruleStrong)
            }
            .buttonStyle(VampGlassPressStyle())
            .disabled(!workspace.canCreateTab)
            .accessibilityLabel("New terminal tab")
            .accessibilityValue(workspace.tabCountLabel)
            .accessibilityHint(workspace.canCreateTab ? "Opens another independent shell" : "Terminal capacity reached")
            .padding(.trailing, VampTerminalDesign.space3)
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
                HStack(spacing: VampTerminalDesign.space2) {
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
                .padding(.leading, VampTerminalDesign.space3)
                .padding(.trailing, workspace.tabs.count > 1 ? VampTerminalDesign.space2 : VampTerminalDesign.space3)
                .frame(minHeight: VampTerminalDesign.controlHeight)
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
                        .frame(minWidth: VampTerminalDesign.minTapTarget, minHeight: VampTerminalDesign.controlHeight)
                }
                .buttonStyle(VampGlassPressStyle())
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .vampGlassSurface(.tab, cornerRadius: VampTerminalDesign.tabRadius)
        .background {
            RoundedRectangle(cornerRadius: VampTerminalDesign.tabRadius, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.035))
        }
        .vampGlassOutline(
            cornerRadius: VampTerminalDesign.tabRadius,
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

    private func agentCommandButton(_ provider: VampAgentProvider) -> some View {
        Button {
            _ = workspace.createTab(
                startupCommand: provider.startupCommand,
                title: provider.displayName,
                provider: provider
            )
        } label: {
            HStack(spacing: VampTerminalDesign.space2) {
                VampProviderMark(provider: provider, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                    Text(provider.executable)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
