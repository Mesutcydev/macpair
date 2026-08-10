import SwiftUI

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
        case .terminal: return "Raw"
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
    @State private var presentation: VampTerminalPresentation = .chat

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            presentationBar

            ZStack {
                (workspace.selectedTab?.provider?.terminalBackground ?? Color.black)
                if workspace.tabs.isEmpty {
                    emptyWorkspaceState
                }
                ForEach(workspace.tabs) { tab in
                    VampTerminalPaneView(
                        session: tab.session,
                        isActive: presentation == .terminal && workspace.selectedTabID == tab.id,
                        provider: tab.provider,
                        onSendClipboardToHost: { _ = workspace.sendClipboardToHost() },
                        onRequestClipboardFromHost: { _ = workspace.requestClipboardFromHost() },
                        onTerminalClipboard: { text in
                            _ = workspace.sendClipboardTextToHost(text)
                        },
                        onTerminalInput: { data in
                            workspace.recordInput(tabID: tab.id, data: data)
                        }
                    )
                    .id(tab.id)
                }

                if presentation == .chat, let tab = workspace.selectedTab {
                    TerminalChatFeedView(
                        chat: tab.chat,
                        session: tab.session,
                        provider: tab.provider,
                        onSendCommand: { command in
                            workspace.sendCommand(tabID: tab.id, text: command)
                        },
                        onOpenTerminal: {
                            presentation = .terminal
                        },
                        onSendClipboardToHost: { _ = workspace.sendClipboardToHost() },
                        onRequestClipboardFromHost: { _ = workspace.requestClipboardFromHost() }
                    )
                    // The chat surface is disposable presentation state. The
                    // terminal panes above remain mounted by their stable tab
                    // IDs, so changing this identity never restarts a PTY.
                    .id(tab.id)
                    .transition(.opacity)
                }

                // Keep transient diagnostics out of the measured workspace
                // height. A late terminal error or clipboard acknowledgement
                // should not move the composer, keyboard, or PTY viewport.
                VStack(spacing: VampTerminalDesign.space2) {
                    if let message = workspace.lastTerminalError {
                        terminalErrorBanner(message)
                    }
                    if let message = workspace.clipboardStatusMessage {
                        clipboardToast(message)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, VampTerminalDesign.space3)
                .padding(.top, VampTerminalDesign.space3)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
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
                    Label("Open raw terminal", systemImage: "terminal")
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
                presentation == .chat ? "Stream" : "Raw PTY",
                systemImage: presentation.systemImage
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
    let onSendCommand: (String) -> Void
    let onOpenTerminal: () -> Void
    let onSendClipboardToHost: () -> Void
    let onRequestClipboardFromHost: () -> Void

    @State private var draft = ""
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    composerFocused = false
                }
                .font(.subheadline.weight(.semibold))
            }
        }
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
            Text("$ \(block.text)")
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
            .accessibilityLabel("Open raw terminal")

            TextField("Type a command…", text: $draft, axis: .vertical)
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
