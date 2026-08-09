import Combine
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
        var provider: VampAgentProvider?
        var hasUnreadOutput = false

        @MainActor var state: ClientTerminalSessionManager.State { session.state }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var selectedTabID: UUID?
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var lastTerminalError: String?
    @Published private(set) var clipboardStatusMessage: String?

    private let coordinator: ClientSessionCoordinator
    private let clipboardSync = ClientClipboardSyncManager()
    private var sessionObservations: [UUID: AnyCancellable] = [:]
    private var phaseObservation: AnyCancellable?
    private var dataChannelObservation: Task<Void, Never>?
    private var openingRetryTasks: [UUID: Task<Void, Never>] = [:]

    init(coordinator: ClientSessionCoordinator) {
        self.coordinator = coordinator

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
            }
        }
    }

    deinit {
        phaseObservation?.cancel()
        dataChannelObservation?.cancel()
        sessionObservations.values.forEach { $0.cancel() }
        openingRetryTasks.values.forEach { $0.cancel() }
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
                return reason == "terminal-start-timeout"
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
        provider: VampAgentProvider? = nil
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
        let tab = Tab(
            id: tabID,
            title: title ?? nextDefaultTabTitle(),
            session: session,
            provider: provider
        )
        // Mount and observe the tab before sending TerminalOpen. This keeps a
        // very fast host-ready response from arriving before the tab is
        // routable in the workspace collection.
        tabs.append(tab)
        observe(session: session, tabID: tabID)
        _ = session.open(cols: 80, rows: 24, startupCommand: startupCommand)
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

    func retryStalledTabs() {
        lastTerminalError = nil
        for tab in tabs where tab.session.retryAfterOpeningFailure(cols: 80, rows: 24) {
            scheduleOpeningRetry(for: tab.id)
        }
    }

    // MARK: - Clipboard bridge

    /// Sends the phone's current plaintext clipboard to the Mac host. This is
    /// explicit so iOS never polls or silently exports clipboard contents.
    @discardableResult
    func sendClipboardToHost() -> Bool {
        let sent = clipboardSync.pushToHost()
        clipboardStatusMessage = sent ? "Phone clipboard sent to Mac" : "Nothing to send"
        return sent
    }

    /// Used by SwiftTerm's OSC 52 callback when a remote program explicitly
    /// writes a clipboard value.
    @discardableResult
    func sendClipboardTextToHost(_ text: String) -> Bool {
        let sent = clipboardSync.pushTextToHost(text)
        clipboardStatusMessage = sent ? "Terminal clipboard sent to Mac" : "Clipboard send failed"
        return sent
    }

    /// Requests the Mac clipboard. The response is placed in the phone
    /// clipboard by `ClientClipboardSyncManager`, ready for the terminal's
    /// Paste action or any other iOS app.
    @discardableResult
    func requestClipboardFromHost() -> Bool {
        let requested = clipboardSync.requestFromHost()
        clipboardStatusMessage = requested ? "Getting Mac clipboard…" : "Clipboard request failed"
        return requested
    }

    // MARK: - Routed incoming messages

    private func receiveReady(_ message: TerminalReadyMessage) {
        for tab in tabs where tab.session.receiveReady(message) {
            cancelOpeningRetry(for: tab.id)
            lastTerminalError = nil
            return
        }
    }

    private func receiveOutput(_ message: TerminalOutputMessage) {
        for index in tabs.indices where tabs[index].session.receiveOutput(message) {
            if tabs[index].id != selectedTabID {
                tabs[index].hasUnreadOutput = true
            }
            return
        }
    }

    private func receiveClose(_ message: TerminalCloseMessage) {
        for tab in tabs where tab.session.receiveClose(message) {
            cancelOpeningRetry(for: tab.id)
            if let reason = message.reason,
               reason == "terminal-disabled" || reason == "terminal-capacity" {
                lastTerminalError = reason == "terminal-disabled"
                    ? "Terminal Mode is disabled in Vamp Host settings."
                    : "The Mac has reached its 8-terminal limit."
            }
            return
        }
    }

    private func receiveClipboard(_ message: ClipboardSyncMessage) {
        guard message.sessionID == activeSessionID,
              message.source == "host" else { return }
        clipboardSync.receive(message)
        clipboardStatusMessage = "Mac clipboard copied to iPhone"
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
            let delays: [UInt64] = [200_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000]
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
            self.lastTerminalError = "\(tab.title) did not start. Check that Terminal Mode is enabled on the host, then retry."
        }
    }

    private func cancelOpeningRetry(for tabID: UUID) {
        openingRetryTasks[tabID]?.cancel()
        openingRetryTasks.removeValue(forKey: tabID)
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
