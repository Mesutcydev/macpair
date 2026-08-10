import Combine
import CryptoKit
import Foundation
import SharedProtocol
import TransportWebRTC

/// Provider launch profiles are shared with the package-level workspace model
/// so tests can validate stable tab identity without importing the app target's
/// SwiftUI-only visual layer.
enum VampAgentProvider: String, CaseIterable, Identifiable {
    case openCode
    case pi
    case commandCode
    case chatGPT
    case claude
    case kimi
    case qwen
    case codex
    case aider
    case grok

    var id: String { rawValue }

    var sessionDisplayName: String {
        switch self {
        case .openCode: return "OpenCode"
        case .pi: return "Pi"
        case .commandCode: return "CommandCode"
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        case .kimi: return "Kimi"
        case .qwen: return "Qwen"
        case .codex: return "Codex"
        case .aider: return "Aider"
        case .grok: return "Grok"
        }
    }
}

/// Input origins keep semantic chat events separate from raw terminal bytes.
/// A VT screen can echo, repaint, and reorder bytes; it is never a source of
/// truth for what the user submitted in Chat.
enum TerminalInputOrigin {
    case chatComposer
    case rawTerminalKeyboard
    case launcher
    case system
    case permissionResponse
}

/// The task-chat projection of one terminal session. It deliberately stores
/// only events Vamp knows semantically. PTY output belongs to SwiftTerm's VT
/// screen buffer and must never be scraped back into this transcript.
@MainActor
final class TerminalChatStore: ObservableObject {
    enum Role: Equatable {
        case system
        case command
        case output
        case success
        case warning
        case error
        case progress
    }

    struct Block: Identifiable, Equatable {
        let id: UUID
        var role: Role
        var title: String?
        var text: String
        var isStreaming: Bool

        init(
            id: UUID = UUID(),
            role: Role,
            title: String? = nil,
            text: String,
            isStreaming: Bool = false
        ) {
            self.id = id
            self.role = role
            self.title = title
            self.text = text
            self.isStreaming = isStreaming
        }
    }

    struct ActivityEvent: Identifiable, Equatable {
        let id: UUID
        let date: Date
        let text: String

        init(id: UUID = UUID(), date: Date = .now, text: String) {
            self.id = id
            self.date = date
            self.text = text
        }
    }

    @Published private(set) var blocks: [Block]
    @Published private(set) var activityEvents: [ActivityEvent] = []

    private let tabTitle: String
    private var didMarkReady = false
    private var didMarkClosed = false
    private let maxBlocks = 180
    private let maxActivityEvents = 120

    init(tabTitle: String) {
        self.tabTitle = tabTitle
        self.blocks = [
            Block(
                role: .system,
                title: "System",
                text: "\(tabTitle) is opening a shell…",
                isStreaming: true
            )
        ]
    }

    func recordStartupCommand(_ command: String) {
        recordActivity("Launcher started · \(command)")
    }

    /// Compatibility hook for raw-terminal input. Raw key events are sent to
    /// the PTY only; they are intentionally not reconstructed as Chat cards.
    func recordInput(_ data: Data) {
        guard !data.isEmpty else { return }
        recordActivity("Terminal input · \(data.count) bytes")
    }

    /// Kept as a no-op compatibility surface for older callers. Terminal
    /// bytes are rendered only by the mounted VT emulator, never as Chat text.
    func appendOutput(_ data: Data) {
        // Do not even decode the bytes here. A packet may end halfway through
        // UTF-8 or an ANSI sequence, and a terminal screen is not a log.
        guard !data.isEmpty else { return }
    }

    func markReady() {
        guard !didMarkReady, !didMarkClosed else { return }
        didMarkReady = true
        finishOpeningMessage()
        recordActivity("PTY ready")
    }

    func markClosed(reason: String?) {
        guard !didMarkClosed else { return }
        let hadReady = didMarkReady
        didMarkClosed = true
        finishOpeningMessage()
        let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFailure = !hadReady || normalizedReason == "terminal-start-timeout"
            || normalizedReason == "terminal-disabled"
            || normalizedReason == "terminal-capacity"
            || normalizedReason == "workspace-unavailable"
            || normalizedReason == "workspace-mismatch"
            || normalizedReason == "eof"
            || normalizedReason == "shell-exited"
            || normalizedReason?.hasPrefix("forkpty failed") == true
            || normalizedReason?.hasPrefix("read-error") == true
        let text: String
        if normalizedReason == "terminal-disabled" {
            text = "Terminal Mode is disabled on the host. Enable it in Vamp Host settings and retry."
        } else if normalizedReason == "terminal-capacity" {
            text = "The host has reached its 8-terminal limit. Close another tab before opening one."
        } else if normalizedReason == "terminal-start-timeout" {
            text = "The shell did not start. Check Terminal Mode on the host, then retry this tab."
        } else if normalizedReason == "workspace-unavailable" {
            text = "That workspace is no longer available on the Mac. Refresh workspaces and choose another folder."
        } else if normalizedReason == "workspace-mismatch" {
            text = "The selected workspace changed before launch. Refresh workspaces and try again."
        } else if !hadReady && (normalizedReason == "eof" || normalizedReason == "shell-exited") {
            text = "The host shell exited before it became ready. Check Terminal Mode and retry this tab."
        } else if normalizedReason?.hasPrefix("forkpty failed") == true {
            text = "The host could not create a shell. Check macOS permissions, then retry this tab."
        } else if normalizedReason?.hasPrefix("read-error") == true {
            text = "The host shell stopped reading before it became ready. Retry this tab."
        } else if let normalizedReason, !normalizedReason.isEmpty {
            text = "\(tabTitle) closed · \(normalizedReason)"
        } else {
            text = "\(tabTitle) closed."
        }
        recordActivity(text)
        if isFailure {
            append(Block(role: .error, title: "Terminal unavailable", text: text))
        }
    }

    func prepareForRetry() {
        guard didMarkClosed else { return }
        didMarkClosed = false
        didMarkReady = false
        append(
            Block(
                role: .system,
                title: "System",
                text: "\(tabTitle) is trying again…",
                isStreaming: true
            )
        )
    }

    /// Records the exact immutable value submitted by the Chat composer.
    /// Whitespace inside the message is preserved; only an empty outer value
    /// is rejected. The same value is then sent to the PTY by the workspace.
    func recordChatSubmission(_ rawCommand: String, provider: VampAgentProvider?) {
        let command = rawCommand.replacingOccurrences(of: "\u{0}", with: "")
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        finishOpeningMessage()
        let identity = provider?.sessionDisplayName ?? "Shell"
        append(
            Block(
                role: .command,
                title: "You · \(identity)",
                text: provider == nil ? "$ \(command)" : command,
                isStreaming: false
            )
        )
        recordActivity("Input submitted · \(identity)")
    }

    private func finishOpeningMessage() {
        // Opening is a transient lifecycle state, not a transcript event.
        // Removing it keeps the task-chat surface focused on the connected
        // session instead of leaving a stale "opening shell" prompt above
        // the ready card and streamed output.
        blocks.removeAll {
            $0.role == .system && $0.isStreaming
        }
    }

    func markWorking(provider: VampAgentProvider?) {
        let identity = provider?.sessionDisplayName ?? tabTitle
        if !blocks.contains(where: { $0.role == .progress && $0.text == "\(identity) is working…" }) {
            append(Block(role: .progress, title: identity, text: "\(identity) is working…", isStreaming: true))
        }
    }

    func recordActivity(_ text: String) {
        guard !text.isEmpty else { return }
        activityEvents.append(ActivityEvent(text: text))
        if activityEvents.count > maxActivityEvents {
            activityEvents.removeFirst(activityEvents.count - maxActivityEvents)
        }
    }

    private func append(_ block: Block) {
        blocks.append(block)
        if blocks.count > maxBlocks {
            blocks.removeFirst(blocks.count - maxBlocks)
        }
    }

}

/// Keeps the host-backed workspace catalog separate from live PTY tabs. The
/// catalog is persisted locally by host identity, while availability and Git
/// metadata always come from the connected host.
@MainActor
final class VampWorkspaceStore: ObservableObject {
    @Published private(set) var workspaces: [RemoteWorkspace] = []
    @Published private(set) var roots: [WorkspaceBrowseRoot] = []
    @Published private(set) var directoryEntries: [WorkspaceDirectoryEntry] = []
    @Published private(set) var browsePath: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isBrowsing = false
    @Published private(set) var errorMessage: String?

    private let coordinator: ClientSessionCoordinator
    private var hostID: UUID?
    private var persistenceKey: String?
    private var persistedWorkspaces: [RemoteWorkspace] = []
    private var pendingListRequestID: UUID?
    private var pendingDirectoryRequestID: UUID?

    init(coordinator: ClientSessionCoordinator) {
        self.coordinator = coordinator
        coordinator.onWorkspaceListResponse = { [weak self] response in
            self?.receive(response)
        }
        coordinator.onWorkspaceDirectoryResponse = { [weak self] response in
            self?.receive(response)
        }
    }

    func activate() {
        isLoading = true
        errorMessage = nil
        do {
            pendingListRequestID = try coordinator.requestWorkspaces(refresh: false)
        } catch {
            isLoading = false
            errorMessage = "Reconnect to the Mac to browse its workspaces."
        }
    }

    func retryWhenTransportIsReady() {
        guard coordinator.activeSessionID != nil else { return }
        do {
            pendingListRequestID = try coordinator.requestWorkspaces(refresh: false)
            isLoading = true
            errorMessage = nil
        } catch {
            // The data channel can transition to open before this callback is
            // scheduled. A later open notification will retry without turning
            // a transient transport race into a permanent empty state.
        }
    }

    func refresh() {
        isLoading = true
        errorMessage = nil
        do {
            pendingListRequestID = try coordinator.requestWorkspaces(refresh: true)
        } catch {
            isLoading = false
            errorMessage = "Reconnect to the Mac to refresh workspaces."
        }
    }

    func browse(path: String) {
        isBrowsing = true
        errorMessage = nil
        do {
            pendingDirectoryRequestID = try coordinator.requestWorkspaceDirectory(path: path)
        } catch {
            isBrowsing = false
            errorMessage = "Reconnect to the Mac to browse this folder."
        }
    }

    func browseParent() {
        guard let browsePath else { return }
        let parent = URL(fileURLWithPath: browsePath).deletingLastPathComponent().path
        guard parent != browsePath else { return }
        browse(path: parent)
    }

    func toggleFavorite(_ workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].isFavorite.toggle()
        persist()
    }

    /// Adds a folder selected from the host browser to this host's local
    /// recents without inventing any metadata. The next refresh replaces the
    /// lightweight browser entry with the host's full Git/project record.
    func adopt(_ workspace: RemoteWorkspace) {
        guard workspace.hostID == hostID || hostID == nil else { return }
        if let index = workspaces.firstIndex(where: { $0.path == workspace.path }) {
            workspaces[index].isAvailable = workspace.isAvailable
            if workspaces[index].gitInfo?.projectHints.isEmpty != false {
                workspaces[index].gitInfo = workspace.gitInfo
            }
        } else {
            workspaces.append(workspace)
        }
        hostID = workspace.hostID
        persistenceKey = "com.mesutcy.vamp-terminal.workspaces.\(workspace.hostID.uuidString)"
        persist()
    }

    func markOpened(_ workspace: RemoteWorkspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].lastOpenedAt = Date()
        persist()
    }

    func workspace(for entry: WorkspaceDirectoryEntry) -> RemoteWorkspace? {
        guard let hostID else { return nil }
        return RemoteWorkspace(
            id: stableWorkspaceID(path: entry.path, hostID: hostID),
            hostID: hostID,
            name: entry.name,
            path: entry.path,
            kind: entry.isGitRepository ? .gitRepository : .folder,
            gitInfo: GitWorkspaceInfo(projectHints: entry.projectHints),
            isAvailable: entry.isReadable
        )
    }

    private func receive(_ response: WorkspaceListResponseMessage) {
        guard response.sessionID == coordinator.activeSessionID,
              pendingListRequestID == nil || pendingListRequestID == response.requestID else { return }
        pendingListRequestID = nil
        hostID = response.hostID
        persistenceKey = "com.mesutcy.vamp-terminal.workspaces.\(response.hostID.uuidString)"
        loadPersisted()
        roots = response.roots
        workspaces = merge(server: response.workspaces)
        isLoading = false
        errorMessage = response.errorMessage
        persist()
    }

    private func receive(_ response: WorkspaceDirectoryResponseMessage) {
        guard response.sessionID == coordinator.activeSessionID,
              pendingDirectoryRequestID == nil || pendingDirectoryRequestID == response.requestID else { return }
        pendingDirectoryRequestID = nil
        browsePath = response.path
        directoryEntries = response.entries
        isBrowsing = false
        errorMessage = response.errorMessage
    }

    private func merge(server: [RemoteWorkspace]) -> [RemoteWorkspace] {
        let byPath = Dictionary(uniqueKeysWithValues: persistedWorkspaces.map { ($0.path, $0) })
        var merged = server.map { remote in
            var value = remote
            if let saved = byPath[remote.path] {
                value.lastOpenedAt = saved.lastOpenedAt
                value.isFavorite = saved.isFavorite
            }
            return value
        }
        let knownPaths = Set(server.map(\.path))
        merged.append(contentsOf: persistedWorkspaces.filter { !knownPaths.contains($0.path) }.map {
            var stale = $0
            stale.isAvailable = false
            return stale
        })
        return merged.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            let leftDate = lhs.lastOpenedAt ?? .distantPast
            let rightDate = rhs.lastOpenedAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func loadPersisted() {
        persistedWorkspaces = []
        guard let persistenceKey,
              let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([RemoteWorkspace].self, from: data) else { return }
        persistedWorkspaces = decoded
    }

    private func persist() {
        guard let persistenceKey,
              let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
        persistedWorkspaces = workspaces
    }

    private func stableWorkspaceID(path: String, hostID: UUID) -> UUID {
        var digest = Array(SHA256.hash(data: Data((hostID.uuidString + "\n" + path).utf8)))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        let bytes = digest.prefix(16)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }
}

/// Coordinates the terminal tabs that share one authenticated WebRTC session.
/// Each tab owns one ClientTerminalSessionManager, so shell state and output
/// stay independent while the SwiftUI panes remain mounted.
@MainActor
final class TerminalWorkspaceViewModel: ObservableObject {
    static let maxTabs = 8

    struct Tab: Identifiable {
        let id: UUID
        var title: String
        let session: ClientTerminalSessionManager
        let chat: TerminalChatStore
        var provider: VampAgentProvider?
        var workspaceID: UUID?
        var workingDirectory: String?
        var launchRequest: SessionLaunchRequest?
        var hasUnreadOutput = false
        var draft = ""

        @MainActor var state: ClientTerminalSessionManager.State { session.state }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var selectedTabID: UUID?
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var lastTerminalError: String?
    @Published private(set) var clipboardStatusMessage: String?

    private let coordinator: ClientSessionCoordinator
    let workspaceStore: VampWorkspaceStore
    private let clipboardSync = ClientClipboardSyncManager()
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    private var phaseObservation: AnyCancellable?
    private var dataChannelObservation: Task<Void, Never>?
    private var openingRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var clipboardStatusTask: Task<Void, Never>?

    init(coordinator: ClientSessionCoordinator) {
        self.coordinator = coordinator
        self.workspaceStore = VampWorkspaceStore(coordinator: coordinator)

        coordinator.onTerminalReady = { [weak self] message in
            self?.receiveReady(message)
        }
        coordinator.onTerminalOutput = { [weak self] message in
            self?.receiveOutput(message)
        }
        coordinator.onTerminalClose = { [weak self] message in
            self?.receiveClose(message)
        }
        coordinator.onClipboardSync = { [weak self] message in
            self?.receiveClipboard(message)
        }
        phaseObservation = coordinator.$phase.sink { [weak self] phase in
            self?.retryOpeningTabs(for: phase)
        }
        dataChannelObservation = Task { [weak self] in
            guard let self else { return }
            for await state in coordinator.terminalDataChannelStateUpdates() {
                guard !Task.isCancelled else { return }
                guard state == .open else { continue }
                self.retryOpeningTabs(for: coordinator.phase)
                self.workspaceStore.retryWhenTransportIsReady()
            }
        }
    }

    deinit {
        phaseObservation?.cancel()
        dataChannelObservation?.cancel()
        clipboardStatusTask?.cancel()
        sessionObservations.values.forEach { $0.cancel() }
        openingRetryTasks.values.forEach { $0.cancel() }
        clipboardStatusTask?.cancel()
        clipboardStatusTask = nil
    }

    var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    var canCreateTab: Bool {
        activeSessionID != nil && tabs.count < Self.maxTabs
    }

    var tabCountLabel: String {
        "\(tabs.count)/\(Self.maxTabs)"
    }

    var hasStalledTab: Bool {
        tabs.contains { tab in
            if case .closed(_, _, let reason) = tab.state {
                return Self.isRetryableOpeningFailure(reason)
            }
            return false
        }
    }

    func activate(sessionID: UUID) {
        guard activeSessionID != sessionID else {
            retryOpeningTabs(for: coordinator.phase)
            return
        }

        stop()
        activeSessionID = sessionID
        lastTerminalError = nil
        clipboardStatusMessage = nil
        clipboardSync.activate(sessionID: sessionID) { [weak self] envelope in
            guard let self else { throw WebRTCSessionError.dataChannelUnavailable }
            try self.coordinator.sendTerminalEnvelope(envelope)
        }
        workspaceStore.activate()
        _ = createTab()
    }

    /// Clears the workspace when the authenticated connection ends. Shells are
    /// intentionally not persisted; reconnecting starts a fresh workspace.
    func stop() {
        openingRetryTasks.values.forEach { $0.cancel() }
        openingRetryTasks.removeAll()
        for tab in tabs {
            tab.session.deactivate()
        }
        tabs.removeAll()
        sessionObservations.removeAll()
        selectedTabID = nil
        activeSessionID = nil
        clipboardSync.deactivate()
        clipboardStatusMessage = nil
    }

    @discardableResult
    func createTab(
        startupCommand: String? = nil,
        title: String? = nil,
        provider: VampAgentProvider? = nil,
        workspace: RemoteWorkspace? = nil,
        resumeMode: ResumeMode = .new,
        persistenceMode: PersistenceMode = .sessionOnly,
        launchExecutable: String? = nil,
        launchArguments: [String] = []
    ) -> Bool {
        guard canCreateTab, let sessionID = activeSessionID else { return false }

        let tabID = UUID()
        let session = ClientTerminalSessionManager()
        let coordinator = self.coordinator
        session.activate(sessionID: sessionID) { [weak coordinator] envelope in
            guard let coordinator else {
                throw WebRTCSessionError.dataChannelUnavailable
            }
            try coordinator.sendTerminalEnvelope(envelope)
        }
        let tabTitle = title ?? provider?.sessionDisplayName ?? nextDefaultTabTitle()
        let launchRequest: SessionLaunchRequest? = if let workspace, let provider {
            SessionLaunchRequest(
                hostID: workspace.hostID,
                workspaceID: workspace.id,
                workingDirectory: workspace.path,
                agent: provider.rawValue,
                resumeMode: resumeMode,
                persistenceMode: persistenceMode
            )
        } else {
            nil
        }
        let tab = Tab(
            id: tabID,
            title: tabTitle,
            session: session,
            chat: TerminalChatStore(tabTitle: tabTitle),
            provider: provider,
            workspaceID: workspace?.id,
            workingDirectory: workspace?.path,
            launchRequest: launchRequest
        )
        // Mount and observe the tab before sending TerminalOpen. This keeps a
        // very fast host-ready response from arriving before the tab is
        // routable in the workspace collection.
        tabs.append(tab)
        observe(session: session, tabID: tabID)
        if let startupCommand { tab.chat.recordStartupCommand(startupCommand) }
        _ = session.open(
            cols: 80,
            rows: 24,
            startupCommand: startupCommand,
            workspaceID: workspace?.id,
            workingDirectory: workspace?.path,
            launchExecutable: launchExecutable,
            launchArguments: launchArguments
        )
        if let workspace {
            workspaceStore.markOpened(workspace)
        }
        scheduleOpeningRetry(for: tabID)
        selectedTabID = tabID
        lastTerminalError = nil
        return true
    }

    func select(tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        selectedTabID = tabID
        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[index].hasUnreadOutput = false
        }
    }

    func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        openingRetryTasks[tabID]?.cancel()
        openingRetryTasks.removeValue(forKey: tabID)
        let wasSelected = selectedTabID == tabID
        tabs[index].session.close(reason: "user-closed")
        tabs[index].session.deactivate()
        sessionObservations[tabID]?.cancel()
        sessionObservations.removeValue(forKey: tabID)
        tabs.remove(at: index)

        guard !tabs.isEmpty else {
            selectedTabID = nil
            return
        }
        if wasSelected || selectedTabID == nil {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
            if let selectedTabID,
               let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                tabs[selectedIndex].hasUnreadOutput = false
            }
        }
    }

    func rename(tabID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].title = trimmed
    }

    func updateDraft(tabID: UUID, value: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].draft = value
    }

    func retryStalledTabs() {
        lastTerminalError = nil
        for index in tabs.indices {
            guard tabs[index].session.retryAfterOpeningFailure(cols: 80, rows: 24) else { continue }
            tabs[index].chat.prepareForRetry()
            scheduleOpeningRetry(for: tabs[index].id)
        }
    }

    // MARK: - Clipboard bridge

    /// Sends the phone's current plaintext clipboard to the Mac host. This is
    /// explicit so iOS never polls or silently exports clipboard contents.
    @discardableResult
    func sendClipboardToHost() -> Bool {
        let sent = clipboardSync.pushToHost()
        showClipboardStatus(sent ? "Phone clipboard sent to Mac" : "Nothing to send")
        return sent
    }

    /// Used by SwiftTerm's OSC 52 callback when a remote program explicitly
    /// writes a clipboard value.
    @discardableResult
    func sendClipboardTextToHost(_ text: String) -> Bool {
        let sent = clipboardSync.pushTextToHost(text)
        showClipboardStatus(sent ? "Terminal clipboard sent to Mac" : "Clipboard send failed")
        return sent
    }

    /// Sends the exact immutable Chat composer value once. The transcript is
    /// written before transport and never reconstructed from PTY echo.
    func sendCommand(tabID: UUID, text: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let command = text.replacingOccurrences(of: "\u{0}", with: "")
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              tabs[index].session.canSendInput else { return }
        let data = Data((command + "\n").utf8)
        tabs[index].chat.recordChatSubmission(command, provider: tabs[index].provider)
        tabs[index].chat.markWorking(provider: tabs[index].provider)
        tabs[index].session.sendInput(data)
    }

    /// Raw Terminal input is intentionally not added to Chat. It remains a
    /// byte-accurate PTY interaction and is visible in Terminal mode only.
    func recordInput(tabID: UUID, data: Data) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tab.chat.recordInput(data)
    }

    /// Requests the Mac clipboard. The response is placed in the phone
    /// clipboard by `ClientClipboardSyncManager`, ready for the terminal's
    /// Paste action or any other iOS app.
    @discardableResult
    func requestClipboardFromHost() -> Bool {
        let requested = clipboardSync.requestFromHost()
        showClipboardStatus(requested ? "Getting Mac clipboard…" : "Clipboard request failed")
        return requested
    }

    // MARK: - Routed incoming messages

    private func receiveReady(_ message: TerminalReadyMessage) {
        for tab in tabs where tab.session.receiveReady(message) {
            tab.chat.markReady()
            cancelOpeningRetry(for: tab.id)
            lastTerminalError = nil
            return
        }
    }

    private func receiveOutput(_ message: TerminalOutputMessage) {
        for index in tabs.indices where tabs[index].session.receiveOutput(message) {
            // The VT emulator is the only consumer of PTY bytes. Chat must
            // not infer prompts, commands, or assistant text from a repaint.
            tabs[index].chat.recordActivity("Terminal output received")
            if tabs[index].id != selectedTabID {
                tabs[index].hasUnreadOutput = true
            }
            return
        }
    }

    private func receiveClose(_ message: TerminalCloseMessage) {
        for tab in tabs {
            let wasOpening: Bool
            if case .opening = tab.session.state {
                wasOpening = true
            } else {
                wasOpening = false
            }
            guard tab.session.receiveClose(message) else { continue }
            tab.chat.markClosed(reason: message.reason)
            cancelOpeningRetry(for: tab.id)
            if let reason = message.reason {
                switch reason {
                case "terminal-disabled":
                    lastTerminalError = "Terminal Mode is disabled in Vamp Host settings. Turn it on, then retry this tab."
                case "terminal-capacity":
                    lastTerminalError = "The Mac has reached its 8-terminal limit. Close a tab on the Mac, then retry."
                case "workspace-unavailable", "workspace-mismatch":
                    lastTerminalError = "\(tab.title) could not start in that workspace. Refresh workspaces and choose an available folder."
                case "shell-exited":
                    lastTerminalError = wasOpening
                        ? "\(tab.title) exited before it became ready. Check Terminal Mode and retry."
                        : "\(tab.title) exited. Retry the tab if you want a new shell."
                case "eof":
                    lastTerminalError = "\(tab.title) closed before it became ready. Check Terminal Mode and retry."
                default:
                    if reason.hasPrefix("forkpty failed") {
                        lastTerminalError = "\(tab.title) could not create a shell on the Mac. Check permissions, then retry."
                    } else if reason.hasPrefix("read-error") {
                        lastTerminalError = "\(tab.title) could not start on the Mac: \(reason)."
                    }
                }
            }
            return
        }
    }

    private func receiveClipboard(_ message: ClipboardSyncMessage) {
        guard message.sessionID == activeSessionID,
              message.source == "host" else { return }
        clipboardSync.receive(message)
        showClipboardStatus("Mac clipboard copied to iPhone")
    }

    private func showClipboardStatus(_ message: String) {
        clipboardStatusTask?.cancel()
        clipboardStatusMessage = message
        clipboardStatusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.clipboardStatusMessage = nil
        }
    }

    private func observe(session: ClientTerminalSessionManager, tabID: UUID) {
        sessionObservations[tabID] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func retryOpeningTabs(for phase: ClientSessionCoordinator.SessionPhase) {
        guard phase == .waitingForMedia || phase == .receiving else { return }
        for tab in tabs where tab.state == .opening {
            _ = tab.session.retryOpen(cols: 80, rows: 24)
        }
    }

    private func scheduleOpeningRetry(for tabID: UUID) {
        openingRetryTasks[tabID]?.cancel()
        openingRetryTasks[tabID] = Task { [weak self] in
            // The first terminal can race the final WebRTC control-channel
            // transition, especially on a Tailscale path. Keep the tab in an
            // opening state long enough for that channel to become writable;
            // the host treats the stable terminal ID as an idempotency key.
            // WebRTC negotiation can legitimately take 20–30 seconds on a
            // waking Mac or a Tailscale path. Keep retrying the same stable
            // terminal ID until the data channel is writable instead of
            // declaring the shell dead while the connection is still opening.
            let delays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000, 12_000_000_000, 16_000_000_000, 20_000_000_000]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                guard self.activeSessionID != nil,
                      let tab = self.tabs.first(where: { $0.id == tabID }),
                      tab.state == .opening else {
                    return
                }
                _ = tab.session.retryOpen(cols: 80, rows: 24)
            }

            guard !Task.isCancelled,
                  let self,
                  let tab = self.tabs.first(where: { $0.id == tabID }),
                  tab.state == .opening else { return }
            tab.session.failOpening()
            tab.chat.markClosed(reason: "terminal-start-timeout")
            self.lastTerminalError = "\(tab.title) did not receive a terminal-ready response. Check that Terminal Mode is enabled and Vamp Host is updated, then retry."
        }
    }

    private func cancelOpeningRetry(for tabID: UUID) {
        openingRetryTasks[tabID]?.cancel()
        openingRetryTasks.removeValue(forKey: tabID)
    }

    private static func isRetryableOpeningFailure(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason == "terminal-start-timeout"
            || reason == "terminal-disabled"
            || reason == "terminal-capacity"
            || reason == "workspace-unavailable"
            || reason == "workspace-mismatch"
            || reason == "shell-exited"
            || reason == "eof"
            || reason.hasPrefix("forkpty failed")
            || reason.hasPrefix("read-error")
    }

    private func nextDefaultTabTitle() -> String {
        let existingTitles = Set(tabs.map(\.title))
        var number = 1
        while existingTitles.contains("Terminal \(number)") {
            number += 1
        }
        return "Terminal \(number)"
    }
}
