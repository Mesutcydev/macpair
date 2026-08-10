import SwiftUI
import SharedProtocol

private enum VampTerminalPresentation: String, CaseIterable, Identifiable {
    case chat
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Task chat"
        case .terminal: return "Terminal"
        }
    }

    var compactTitle: String {
        switch self {
        case .chat: return "Chat"
        case .terminal: return "Terminal"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "text.bubble"
        case .terminal: return "terminal"
        }
    }
}

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
    @State private var selectedAgentForWorkspace: VampAgentProvider?
    @State private var showingWorkspaces = false
    @State private var showingActivity = false
    @State private var presentation: VampTerminalPresentation = .chat

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            presentationBar

            ZStack {
                VStack(spacing: 0) {
                    // Every tab remains mounted in this one stable ZStack. In
                    // Chat the selected pane is a compact read-only preview;
                    // Terminal expands the same SwiftTerm view in place.
                    ZStack {
                        (workspace.selectedTab?.provider?.terminalBackground ?? Color.black)
                        if workspace.tabs.isEmpty {
                            emptyWorkspaceState
                        }
                        ForEach(workspace.tabs) { tab in
                            VampTerminalPaneView(
                                session: tab.session,
                                isActive: workspace.selectedTabID == tab.id,
                                isPreview: presentation == .chat,
                                provider: tab.provider,
                                onOpenTerminal: { presentation = .terminal },
                                onSendClipboardToHost: { _ = workspace.sendClipboardToHost() },
                                onRequestClipboardFromHost: { _ = workspace.requestClipboardFromHost() },
                                onTerminalClipboard: { text in
                                    _ = workspace.sendClipboardTextToHost(text)
                                },
                                onTerminalInput: { data in
                                    workspace.recordInput(tabID: tab.id, data: data)
                                }
                            )
                            .opacity(workspace.selectedTabID == tab.id ? 1 : 0.001)
                            .id(tab.id)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: presentation == .chat ? 148 : .infinity)
                    .clipped()

                    if presentation == .chat, let tab = workspace.selectedTab {
                        TerminalChatFeedView(
                            chat: tab.chat,
                            session: tab.session,
                            provider: tab.provider,
                            draft: Binding(
                                get: { workspace.tabs.first(where: { $0.id == tab.id })?.draft ?? "" },
                                set: { workspace.updateDraft(tabID: tab.id, value: $0) }
                            ),
                            onSendCommand: { command in
                                workspace.sendCommand(tabID: tab.id, text: command)
                            },
                            onOpenTerminal: { presentation = .terminal },
                            onSendClipboardToHost: { _ = workspace.sendClipboardToHost() },
                            onRequestClipboardFromHost: { _ = workspace.requestClipboardFromHost() }
                        )
                        .id(tab.id)
                    }
                }

                // Diagnostics never participate in the terminal's measured
                // geometry, so errors cannot move the viewport or composer.
                VStack(spacing: VampTerminalDesign.space2) {
                    if let message = workspace.lastTerminalError { terminalErrorBanner(message) }
                    if let message = workspace.clipboardStatusMessage { clipboardToast(message) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, VampTerminalDesign.space3)
                .padding(.top, VampTerminalDesign.space3)
                .allowsHitTesting(false)
                .zIndex(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        // The workspace is intentionally a dark terminal surface even when
        // the home screen follows the system appearance.  Several of the
        // glass tokens use SwiftUI's semantic primary/secondary colors; pin
        // this surface to dark so those tokens remain readable on the black
        // PTY background instead of becoming black text on black.
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let sessionID = coordinator.activeSessionID {
                workspace.activate(sessionID: sessionID)
            }
            // A plain shell is an interactive terminal first. Agent tabs use
            // the semantic Chat projection until the user switches modes.
            if workspace.selectedTab?.provider == nil {
                presentation = .terminal
            }
        }
        .onChange(of: workspace.selectedTabID) { _, _ in
            if workspace.selectedTab?.provider == nil {
                presentation = .terminal
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
        .sheet(item: $selectedAgentForWorkspace) { provider in
            VampWorkspaceChooserView(
                store: workspace.workspaceStore,
                provider: provider,
                hostName: coordinator.connectedHostName ?? "Connected Mac"
            ) { chosenWorkspace, resumeMode, persistenceMode in
                let launch = provider.launchConfiguration(
                    resumeMode: resumeMode,
                    persistenceMode: persistenceMode,
                    workspaceID: chosenWorkspace.id
                )
                _ = workspace.createTab(
                    title: provider.sessionDisplayName,
                    provider: provider,
                    workspace: chosenWorkspace,
                    resumeMode: resumeMode,
                    persistenceMode: persistenceMode,
                    launchExecutable: launch.executable,
                    launchArguments: launch.arguments
                )
                presentation = .chat
                selectedAgentForWorkspace = nil
            }
        }
        .sheet(isPresented: $showingWorkspaces) {
            VampWorkspacesView(
                store: workspace.workspaceStore,
                terminalWorkspace: workspace,
                hostName: coordinator.connectedHostName ?? "Connected Mac",
                connectionLabel: coordinator.connectionMode.label
            )
        }
        .sheet(isPresented: $showingActivity) {
            if let tab = workspace.selectedTab {
                TerminalSessionActivityView(chat: tab.chat, title: tab.title)
            }
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

    private func terminalErrorBanner(_ message: String) -> some View {
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
        .padding(.horizontal, VampTerminalDesign.space3)
        .padding(.vertical, VampTerminalDesign.space2)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: VampGlassPalette.warning.opacity(0.30))
    }

    private func clipboardToast(_ message: String) -> some View {
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
        .padding(.horizontal, VampTerminalDesign.space3)
        .padding(.vertical, VampTerminalDesign.space2)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius)
    }

    private var header: some View {
        HStack(spacing: VampTerminalDesign.space3) {
            Button {
                showingDisconnectConfirmation = true
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
            }
            .buttonStyle(VampGlassPressStyle())
            .accessibilityLabel("Back to hosts")
            .accessibilityHint("Asks for confirmation before disconnecting")

            VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                Text("Task chat")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(VampGlassPalette.good)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text("\(coordinator.connectedHostName ?? "Vamp Terminal") · \(coordinator.connectionMode.label)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: VampTerminalDesign.space2)

            Menu {
                Section("Connected host") {
                    Label(coordinator.connectedHostName ?? "Vamp Terminal", systemImage: "terminal.fill")
                    Label(coordinator.connectionMode.label, systemImage: "circle.fill")
                }
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        presentation = .terminal
                    }
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                Button {
                    showingActivity = true
                } label: {
                    Label("Session Activity", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    showingWorkspaces = true
                } label: {
                    Label("Open workspaces", systemImage: "folder")
                }
                Button(role: .destructive) {
                    showingDisconnectConfirmation = true
                } label: {
                    Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                HStack(spacing: VampTerminalDesign.space2) {
                    Circle()
                        .fill(VampGlassPalette.good)
                        .frame(width: 7, height: 7)
                    Text("Connected")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                }
                .padding(.horizontal, VampTerminalDesign.space3)
                .frame(minHeight: VampTerminalDesign.compactControlHeight)
                .vampGlassSurface(.capsule)
                .vampGlassOutline(cornerRadius: 999, color: VampGlassPalette.ruleStrong)
            }
            .accessibilityLabel("Connection menu")
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

    private var presentationBar: some View {
        HStack(spacing: VampTerminalDesign.space2) {
            Label(
                "Mode",
                systemImage: "rectangle.split.2x1"
            )
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(VampGlassPalette.inkTertiary)
            Spacer(minLength: VampTerminalDesign.space2)

            HStack(spacing: 2) {
                ForEach(VampTerminalPresentation.allCases) { mode in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            presentation = mode
                        }
                    } label: {
                        Label(mode.compactTitle, systemImage: mode.systemImage)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(presentation == mode ? VampGlassPalette.ink : VampGlassPalette.inkSecondary)
                            .padding(.horizontal, VampTerminalDesign.space3)
                            .frame(minHeight: VampTerminalDesign.compactControlHeight)
                            .background(
                                presentation == mode
                                    ? Color.primary.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: VampTerminalDesign.smallRadius, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(presentation == mode ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
            .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
        }
        .padding(.horizontal, VampTerminalDesign.space4)
        .padding(.vertical, VampTerminalDesign.space1)
        .frame(minHeight: 44)
        .vampGlassSurface(.toolbar, cornerRadius: 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(VampGlassPalette.rule)
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
                Section("Project context") {
                    Button {
                        showingWorkspaces = true
                    } label: {
                        Label("Choose workspace", systemImage: "folder.badge.gearshape")
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
            // Agent-first launch resolves through the same workspace chooser as
            // the workspace-first flow. This prevents an agent from silently
            // inheriting an unrelated global cwd.
            selectedAgentForWorkspace = provider
        } label: {
            if let assetName = provider.assetName {
                Label(provider.displayName, image: assetName)
            } else {
                Label(provider.displayName, systemImage: provider.fallbackSystemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(provider.accent)
            }
        }
        .accessibilityLabel(provider.displayName)
    }
}

private struct TerminalChatFeedView: View {
    @ObservedObject var chat: TerminalChatStore
    @ObservedObject var session: ClientTerminalSessionManager
    let provider: VampAgentProvider?
    @Binding var draft: String
    let onSendCommand: (String) -> Void
    let onOpenTerminal: () -> Void
    let onSendClipboardToHost: () -> Void
    let onRequestClipboardFromHost: () -> Void

    @FocusState private var composerFocused: Bool
    @State private var isNearLatest = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: VampTerminalDesign.space4) {
                        ForEach(chat.blocks) { block in
                            TerminalChatBlockView(block: block, provider: provider)
                                .id(block.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom")
                    }
                    .padding(.horizontal, VampTerminalDesign.space4)
                    .padding(.top, VampTerminalDesign.space4)
                    .padding(.bottom, VampTerminalDesign.space5)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .overlay(alignment: .bottomTrailing) {
                    if !isNearLatest {
                        Button {
                            scrollToLatest(proxy, animated: true)
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .padding(.horizontal, VampTerminalDesign.space3)
                                .frame(minHeight: VampTerminalDesign.compactControlHeight)
                                .vampGlassSurface(.capsule)
                                .vampGlassOutline(cornerRadius: 999, color: VampGlassPalette.ruleStrong)
                        }
                        .buttonStyle(VampGlassPressStyle())
                        .padding(.trailing, VampTerminalDesign.space4)
                        .padding(.bottom, VampTerminalDesign.space3)
                    }
                }
                .onAppear {
                    scrollToLatestAfterLayout(proxy, animated: false)
                }
                .onChange(of: chat.blocks) { _, _ in
                    guard isNearLatest else { return }
                    scrollToLatestAfterLayout(proxy, animated: true)
                }
                .onChange(of: composerFocused) { _, focused in
                    guard focused else { return }
                    // The keyboard changes the container height after focus.
                    // Follow once after that layout pass so the composer does
                    // not cover the newest streamed card or expose a stale
                    // "Latest" control on a fresh command.
                    scrollToLatestAfterLayout(proxy, animated: false)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let distanceFromLatest = geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                    return distanceFromLatest <= 56
                } action: { _, nearLatest in
                    isNearLatest = nearLatest
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The conversation owns the scrolling region. Keeping the
            // composer in the safe-area inset prevents the keyboard from
            // changing the feed's measured height and stops the input card
            // from colliding with the latest streamed response.
            .safeAreaInset(edge: .bottom, spacing: 0) {
            TerminalChatComposer(
                draft: $draft,
                composerFocused: $composerFocused,
                provider: provider,
                isEnabled: session.canEditInput,
                canSend: session.canSendInput,
                onSend: sendDraft,
                onOpenTerminal: onOpenTerminal,
                onPaste: pasteFromPhone,
                onSendClipboardToHost: onSendClipboardToHost,
                onRequestClipboardFromHost: onRequestClipboardFromHost
            )
        }
        .background(provider?.terminalBackground ?? Color.black)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        if !animated || reduceMotion {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private func scrollToLatestAfterLayout(_ proxy: ScrollViewProxy, animated: Bool) {
        isNearLatest = true
        DispatchQueue.main.async {
            scrollToLatest(proxy, animated: animated)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                scrollToLatest(proxy, animated: false)
            }
        }
    }

    private func sendDraft() {
        let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, session.canSendInput else { return }
        onSendCommand(command)
        draft = ""
        composerFocused = true
    }

    private func pasteFromPhone() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if draft.isEmpty {
            draft = text
        } else {
            draft += text
        }
        composerFocused = true
    }
}

private struct TerminalSessionActivityView: View {
    @ObservedObject var chat: TerminalChatStore
    let title: String

    var body: some View {
        NavigationStack {
            Group {
                if chat.activityEvents.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "clock")
                } else {
                    List(chat.activityEvents.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.text)
                                .font(.system(.body, design: .rounded))
                            Text(event.date, style: .time)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Activity · \(title)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Workspace / project layer

private struct VampWorkspaceCard: View {
    let workspace: RemoteWorkspace
    let isSelected: Bool
    let activeSessionCount: Int
    let onTap: () -> Void
    let onFavorite: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: VampTerminalDesign.space3) {
            Image(systemName: workspace.kind == .gitRepository ? "shippingbox" : "folder")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .frame(width: 36, height: 36)
                .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)

            VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                HStack(spacing: VampTerminalDesign.space2) {
                    Text(workspace.name)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(VampGlassPalette.ink)
                        .lineLimit(1)
                    if !workspace.isAvailable {
                        Text("UNAVAILABLE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(VampGlassPalette.warning)
                    }
                }
                Text(workspace.path)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: VampTerminalDesign.space2) {
                    if let gitInfo = workspace.gitInfo {
                        Label(gitInfo.branch ?? "Git", systemImage: "arrow.triangle.branch")
                        if gitInfo.isDirty { Text("· changes") }
                        if !gitInfo.projectHints.isEmpty { Text("· " + gitInfo.projectHints.prefix(2).joined(separator: " · ")) }
                    } else {
                        Text(workspace.kind == .home ? "Home folder" : "Folder")
                    }
                    if activeSessionCount > 0 { Text("· \(activeSessionCount) active") }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(VampGlassPalette.inkTertiary)
            }

            Spacer(minLength: 0)
            VStack(spacing: VampTerminalDesign.space2) {
                Button(action: onFavorite) {
                    Image(systemName: workspace.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(workspace.isFavorite ? VampGlassPalette.ink : VampGlassPalette.inkSubtle)
                        .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
                }
                .buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VampGlassPalette.inkSubtle)
            }
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(
            cornerRadius: VampTerminalDesign.largeCardRadius,
            color: isSelected ? VampGlassPalette.ruleStrong : VampGlassPalette.rule
        )
        .contentShape(RoundedRectangle(cornerRadius: VampTerminalDesign.largeCardRadius, style: .continuous))
        .onTapGesture {
            guard workspace.isAvailable else { return }
            onTap()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(workspace.isAvailable ? "Opens this workspace" : "Workspace unavailable")
        .opacity(workspace.isAvailable ? 1 : 0.62)
    }
}

struct VampWorkspaceChooserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: VampWorkspaceStore
    let provider: VampAgentProvider
    let hostName: String
    let onStart: (RemoteWorkspace, ResumeMode, PersistenceMode) -> Void

    @State private var selectedWorkspaceID: UUID?
    @State private var resumeMode: ResumeMode = .new
    @State private var persistenceMode: PersistenceMode = .preserveWithTmux

    private var selectedWorkspace: RemoteWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return store.workspaces.first { $0.id == selectedWorkspaceID && $0.isAvailable }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VampTerminalDesign.space5) {
                    VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                        Text("New \(provider.displayName) session")
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(hostName + " · " + "Choose where this agent should start.")
                            .font(.subheadline)
                            .foregroundStyle(VampGlassPalette.inkSecondary)
                    }

                    sectionLabel("WORKSPACE")
                    if store.isLoading && store.workspaces.isEmpty {
                        ProgressView("Discovering projects on the Mac…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if store.workspaces.isEmpty {
                        emptyWorkspaceMessage
                    } else {
                        ForEach(store.workspaces) { workspace in
                            VampWorkspaceCard(
                                workspace: workspace,
                                isSelected: selectedWorkspaceID == workspace.id,
                                activeSessionCount: 0,
                                onTap: { selectedWorkspaceID = workspace.id },
                                onFavorite: { store.toggleFavorite(workspace.id) }
                            )
                        }
                    }

                    NavigationLink {
                            VampWorkspaceBrowserView(store: store) { workspace in
                            store.adopt(workspace)
                            selectedWorkspaceID = workspace.id
                            onStart(workspace, resumeMode, persistenceMode)
                        }
                    } label: {
                        Label("Browse Mac…", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .foregroundStyle(VampGlassPalette.ink)
                            .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.controlHeight)
                            .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                            .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                    }
                    .buttonStyle(VampGlassPressStyle())

                    if let selectedWorkspace {
                        VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
                            sectionLabel("SESSION")
                            Picker("Session", selection: $resumeMode) {
                                Text("New session").tag(ResumeMode.new)
                                Text("Resume previous").tag(ResumeMode.resumePrevious)
                            }
                            .pickerStyle(.segmented)
                            Toggle("Preserve session after disconnect", isOn: Binding(
                                get: { persistenceMode == .preserveWithTmux },
                                set: { persistenceMode = $0 ? .preserveWithTmux : .sessionOnly }
                            ))
                            .font(.subheadline)
                            Text("Start in: \(selectedWorkspace.path)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(VampGlassPalette.inkSecondary)
                                .lineLimit(2)
                        }
                    }

                    Button {
                        guard let selectedWorkspace else { return }
                        onStart(selectedWorkspace, resumeMode, persistenceMode)
                        dismiss()
                    } label: {
                        Label("Start \(provider.displayName)", systemImage: "arrow.up.right")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.controlHeight)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
                    }
                    .buttonStyle(VampGlassPressStyle())
                    .disabled(selectedWorkspace == nil)
                    .opacity(selectedWorkspace == nil ? 0.45 : 1)
                }
                .padding(.horizontal, VampTerminalDesign.space5)
                .padding(.vertical, VampTerminalDesign.space5)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Choose workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh workspaces")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.activate()
            if selectedWorkspaceID == nil {
                selectedWorkspaceID = store.workspaces.first(where: { $0.isAvailable })?.id
            }
        }
        .onChange(of: store.workspaces) { _, workspaces in
            guard selectedWorkspaceID == nil else { return }
            selectedWorkspaceID = workspaces.first(where: { $0.isAvailable })?.id
        }
    }

    private var emptyWorkspaceMessage: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
            Text("No projects discovered yet")
                .font(.headline)
            Text(store.errorMessage ?? "Browse the Mac to choose a folder. The folder is never deleted when removed from recents.")
                .font(.subheadline)
                .foregroundStyle(VampGlassPalette.inkSecondary)
        }
        .padding(VampTerminalDesign.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vampGlassSurface(.card, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.largeCardRadius)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(VampGlassPalette.inkTertiary)
    }
}

struct VampWorkspacesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: VampWorkspaceStore
    @ObservedObject var terminalWorkspace: TerminalWorkspaceViewModel
    let hostName: String
    let connectionLabel: String
    @State private var selectedWorkspace: RemoteWorkspace?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VampTerminalDesign.space5) {
                    VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                        Text("Workspaces")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        HStack(spacing: VampTerminalDesign.space2) {
                            Circle().fill(VampGlassPalette.good).frame(width: 7, height: 7)
                            Text("\(hostName) · \(connectionLabel)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(VampGlassPalette.inkSecondary)
                        }
                    }

                    Text("RECENT")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(VampGlassPalette.inkTertiary)

                    if store.workspaces.isEmpty && store.isLoading {
                        ProgressView("Discovering projects…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(store.workspaces) { item in
                            VampWorkspaceCard(
                                workspace: item,
                                isSelected: false,
                                activeSessionCount: terminalWorkspace.tabs.filter { $0.workspaceID == item.id }.count,
                                onTap: { selectedWorkspace = item },
                                onFavorite: { store.toggleFavorite(item.id) }
                            )
                        }
                    }

                    Text("OTHER LOCATIONS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                    ForEach(store.roots) { root in
                        NavigationLink {
                            VampWorkspaceBrowserView(store: store, initialPath: root.path) { workspace in
                                store.adopt(workspace)
                                selectedWorkspace = workspace
                            }
                        } label: {
                            HStack {
                                Image(systemName: root.name == "Home" ? "house" : "folder")
                                    .frame(width: 28)
                                Text(root.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(VampGlassPalette.inkSubtle)
                            }
                            .font(.headline)
                            .foregroundStyle(VampGlassPalette.ink)
                            .padding(.horizontal, VampTerminalDesign.space4)
                            .frame(minHeight: VampTerminalDesign.controlHeight)
                            .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                            .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                        }
                        .buttonStyle(VampGlassPressStyle())
                    }
                }
                .padding(.horizontal, VampTerminalDesign.space5)
                .padding(.vertical, VampTerminalDesign.space5)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .sheet(item: $selectedWorkspace) { item in
            VampWorkspaceDetailView(
                workspace: item,
                store: store,
                terminalWorkspace: terminalWorkspace,
                hostName: hostName
            )
        }
        .preferredColorScheme(.dark)
        .onAppear { store.activate() }
    }
}

private struct VampWorkspaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let workspace: RemoteWorkspace
    @ObservedObject var store: VampWorkspaceStore
    @ObservedObject var terminalWorkspace: TerminalWorkspaceViewModel
    let hostName: String
    @State private var selectedAgent: VampAgentProvider?

    private var activeTabs: [TerminalWorkspaceViewModel.Tab] {
        terminalWorkspace.tabs.filter { $0.workspaceID == workspace.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VampTerminalDesign.space5) {
                VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
                    Text(workspace.name)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(workspace.path)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .textSelection(.enabled)
                    if let git = workspace.gitInfo {
                        Label("Git · \(git.branch ?? "branch unknown")\(git.isDirty ? " · changes" : " · clean")", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(VampGlassPalette.inkTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: VampTerminalDesign.space3) {
                    Text("SESSIONS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(VampGlassPalette.inkTertiary)
                    if activeTabs.isEmpty {
                        Text("No active sessions in this workspace.")
                            .font(.subheadline)
                            .foregroundStyle(VampGlassPalette.inkSecondary)
                    } else {
                        ForEach(activeTabs) { tab in
                            HStack(spacing: VampTerminalDesign.space3) {
                                Circle().fill(VampGlassPalette.good).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: VampTerminalDesign.space1) {
                                    Text(tab.title).font(.headline)
                                    Text(tab.stateLabel)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(VampGlassPalette.inkSecondary)
                                }
                                Spacer()
                            }
                            .padding(VampTerminalDesign.space3)
                            .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                            .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                        }
                    }
                }

                Menu {
                    ForEach(VampAgentProvider.allCases) { provider in
                        Button {
                            selectedAgent = provider
                        } label: {
                            Label(provider.displayName, systemImage: provider.fallbackSystemImage)
                        }
                    }
                } label: {
                    Label("New agent session", systemImage: "plus")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.controlHeight)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
                }
                .buttonStyle(VampGlassPressStyle())

                Button {
                    _ = terminalWorkspace.createTab(title: "Shell · \(workspace.name)", workspace: workspace)
                    dismiss()
                } label: {
                    Label("Open shell here", systemImage: "terminal")
                        .font(.headline)
                        .foregroundStyle(VampGlassPalette.ink)
                        .frame(maxWidth: .infinity, minHeight: VampTerminalDesign.controlHeight)
                        .vampGlassSurface(.button, cornerRadius: VampTerminalDesign.controlRadius)
                        .vampGlassOutline(cornerRadius: VampTerminalDesign.controlRadius)
                }
                .buttonStyle(VampGlassPressStyle())
            }
            .padding(.horizontal, VampTerminalDesign.space5)
            .padding(.vertical, VampTerminalDesign.space5)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedAgent) { provider in
            VampWorkspaceChooserView(store: store, provider: provider, hostName: hostName) { chosen, resumeMode, persistenceMode in
                let launch = provider.launchConfiguration(
                    resumeMode: resumeMode,
                    persistenceMode: persistenceMode,
                    workspaceID: chosen.id
                )
                _ = terminalWorkspace.createTab(
                    title: provider.sessionDisplayName,
                    provider: provider,
                    workspace: chosen,
                    resumeMode: resumeMode,
                    persistenceMode: persistenceMode,
                    launchExecutable: launch.executable,
                    launchArguments: launch.arguments
                )
                selectedAgent = nil
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct VampWorkspaceBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: VampWorkspaceStore
    var initialPath: String?
    let onSelect: (RemoteWorkspace) -> Void

    init(
        store: VampWorkspaceStore,
        initialPath: String? = nil,
        onSelect: @escaping (RemoteWorkspace) -> Void
    ) {
        self.store = store
        self.initialPath = initialPath
        self.onSelect = onSelect
    }

    var body: some View {
        List {
            Section {
                if store.isBrowsing {
                    ProgressView("Reading Mac folder…")
                } else if store.directoryEntries.isEmpty {
                    ContentUnavailableView(
                        "No folders here",
                        systemImage: "folder",
                        description: Text("Choose another Mac location or go up one level.")
                    )
                }
                ForEach(store.directoryEntries) { entry in
                    HStack(spacing: VampTerminalDesign.space3) {
                        Button {
                            if let workspace = store.workspace(for: entry) {
                                onSelect(workspace)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: VampTerminalDesign.space3) {
                                Image(systemName: entry.isGitRepository ? "shippingbox" : "folder")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).foregroundStyle(.primary)
                                    Text(entry.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                        Button { store.browse(path: entry.path) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(store.browsePath ?? "Mac folders")
                    .font(.system(size: 11, design: .monospaced))
                    .textCase(nil)
            } footer: {
                Text("Tap a folder to use it as the agent workspace. Use the chevron to browse deeper.")
            }
        }
        .navigationTitle("Browse Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    store.browseParent()
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .disabled(store.browsePath == nil || URL(fileURLWithPath: store.browsePath ?? "").deletingLastPathComponent().path == store.browsePath)
            }
        }
        .onAppear {
            if let initialPath {
                store.browse(path: initialPath)
            } else if let root = store.roots.first(where: { $0.name == "Home" }) ?? store.roots.first {
                store.browse(path: root.path)
            }
        }
    }
}

@MainActor private extension TerminalWorkspaceViewModel.Tab {
    var stateLabel: String {
        switch state {
        case .idle: return "Waiting"
        case .opening: return "Opening"
        case .open: return "Running"
        case .closed: return "Stopped"
        }
    }
}

private struct TerminalChatBlockView: View {
    let block: TerminalChatStore.Block
    let provider: VampAgentProvider?

    var body: some View {
        switch block.role {
        case .system:
            systemBlock
        case .command:
            commandBlock
        case .output, .success, .warning, .error, .progress:
            outputBlock
        }
    }

    private var systemBlock: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
            HStack(spacing: VampTerminalDesign.space2) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(block.title ?? "System")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                if block.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(VampGlassPalette.warning)
                }
            }
            Text(block.text)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(VampGlassPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
            HStack(spacing: VampTerminalDesign.space2) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                Text(block.title ?? "You")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer(minLength: 0)
                Text("command")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkSubtle)
            }
            Text(block.text)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(VampGlassPalette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VampTerminalDesign.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vampGlassSurface(.field, cornerRadius: VampTerminalDesign.cardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: VampGlassPalette.ruleStrong)
        .accessibilityElement(children: .combine)
    }

    private var outputBlock: some View {
        VStack(alignment: .leading, spacing: VampTerminalDesign.space2) {
            HStack(spacing: VampTerminalDesign.space2) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusColor)
                Text(block.title ?? "Terminal output")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                if block.isStreaming {
                    Spacer(minLength: 0)
                    Text("STREAMING")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(statusColor)
                }
            }

            TerminalChatContentView(text: block.text, color: provider?.terminalText ?? VampGlassPalette.ink)
        }
        .padding(VampTerminalDesign.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (provider?.terminalBackground ?? Color.black).opacity(0.72),
            in: RoundedRectangle(cornerRadius: VampTerminalDesign.cardRadius, style: .continuous)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(statusColor)
                .frame(width: 3)
                .padding(.vertical, VampTerminalDesign.space3)
        }
        .vampGlassOutline(cornerRadius: VampTerminalDesign.cardRadius, color: statusColor.opacity(0.25))
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch block.role {
        case .output: return "chevron.right"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .progress: return "arrow.triangle.2.circlepath"
        case .system, .command: return "circle"
        }
    }

    private var statusColor: Color {
        switch block.role {
        case .system: return VampGlassPalette.inkSecondary
        case .command: return provider?.accent ?? VampGlassPalette.ink
        case .output: return provider?.accent ?? VampGlassPalette.inkSecondary
        case .success: return VampGlassPalette.good
        case .warning, .progress: return VampGlassPalette.warning
        case .error: return VampGlassPalette.bad
        }
    }
}

private struct TerminalChatContentView: View {
    let text: String
    let color: Color

    var body: some View {
        if isTable {
            tableContent
        } else {
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(color)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: VampTerminalDesign.chatOutputMaxHeight)
        }
    }

    private var rows: [[String]] {
        text
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "").isEmpty }
            .map { line in
                line.split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }
    }

    private var isTable: Bool {
        let candidates = rows
        guard candidates.count >= 2 else { return false }
        return candidates.allSatisfy { $0.count >= 2 }
            && candidates[1].allSatisfy { $0.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } }
    }

    private var tableContent: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: VampTerminalDesign.space2) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(value.isEmpty ? " " : value)
                                .font(.system(size: 12, weight: index == 0 ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(color.opacity(index == 1 ? 0.7 : 1))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, VampTerminalDesign.space2)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(VampGlassPalette.rule)
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: VampTerminalDesign.chatOutputMaxHeight)
    }
}

private struct TerminalChatComposer: View {
    @Binding var draft: String
    var composerFocused: FocusState<Bool>.Binding
    let provider: VampAgentProvider?
    let isEnabled: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onOpenTerminal: () -> Void
    let onPaste: () -> Void
    let onSendClipboardToHost: () -> Void
    let onRequestClipboardFromHost: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: VampTerminalDesign.space2) {
            Button(action: onOpenTerminal) {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(VampGlassPalette.inkSecondary)
            .accessibilityLabel("Open Terminal")

            TextField(
                provider.map { "Message \($0.sessionDisplayName)…" } ?? "Type a shell command…",
                text: $draft,
                axis: .vertical
            )
                .focused(composerFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .lineLimit(1...4)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(VampGlassPalette.ink)
                .tint(VampGlassPalette.ink)
                .onSubmit(onSend)
                .disabled(!isEnabled)

            Menu {
                Button(action: onPaste) {
                    Label("Paste from iPhone", systemImage: "doc.on.clipboard")
                }
                Button(action: onSendClipboardToHost) {
                    Label("Send iPhone clipboard to Mac", systemImage: "arrow.up.doc")
                }
                Button(action: onRequestClipboardFromHost) {
                    Label("Get Mac clipboard", systemImage: "arrow.down.doc")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(VampGlassPalette.inkSecondary)
            .accessibilityLabel("Command and clipboard actions")

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.black : VampGlassPalette.inkSubtle)
                    .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
                    .background(
                        canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? VampGlassPalette.ink
                            : Color.primary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous)
                    )
            }
            .buttonStyle(VampGlassPressStyle())
            .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send command")
        }
        .padding(.horizontal, VampTerminalDesign.space2)
        .padding(.vertical, VampTerminalDesign.space2)
        .frame(minHeight: 60)
        .vampGlassSurface(.field, cornerRadius: VampTerminalDesign.largeCardRadius)
        .vampGlassOutline(cornerRadius: VampTerminalDesign.largeCardRadius, color: VampGlassPalette.ruleStrong)
        .padding(.horizontal, VampTerminalDesign.space3)
        .padding(.vertical, VampTerminalDesign.space2)
        .background(Color.black.opacity(0.82))
    }
}
