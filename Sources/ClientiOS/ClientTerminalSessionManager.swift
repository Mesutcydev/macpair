import Foundation
import Combine
import SharedProtocol
import TransportWebRTC

/// Owns the lifecycle of a single Terminal Mode session on the client side.
///
/// The view binds to `output` to forward bytes into its emulator (SwiftTerm
/// `feed(byteArray:)`), to `state` to react to host-side shell exit / open
/// failures, and calls `sendInput`/`requestResize` from input/layout
/// callbacks. Bytes are forwarded as-is — escape interpretation is the
/// emulator's job.
@MainActor
final class ClientTerminalSessionManager: ObservableObject {

    enum State: Equatable {
        case idle
        case opening
        case open
        /// Host reported the shell exited or failed to spawn. `reason` is for
        /// diagnostics; the UI shows it under the prompt.
        case closed(exitCode: Int32?, signal: Int32?, reason: String?)
    }

    @Published private(set) var state: State = .idle
    /// Monotonically grows; the view observes count changes to feed new bytes
    /// to the emulator. We keep the last N chunks for diagnostics + replay
    /// when the view first attaches mid-session.
    @Published private(set) var output: [TerminalOutputMessage] = []

    private var sessionID: UUID?
    private var terminalID: UUID?
    private var sendEnvelope: ((DataChannelEnvelope) throws -> Void)?
    /// Drops chunks older than this once `outputBacklogCap` is reached so a
    /// long-lived session doesn't grow memory unboundedly.
    private let outputBacklogCap = 256
    private var lastObservedSequence: UInt64 = 0

    // MARK: - Session lifecycle

    func activate(sessionID: UUID, send: @escaping (DataChannelEnvelope) throws -> Void) {
        self.sessionID = sessionID
        self.sendEnvelope = send
        self.state = .idle
        self.output.removeAll()
        self.lastObservedSequence = 0
        self.terminalID = nil
    }

    func deactivate() {
        if let terminalID, let sessionID, state == .open || state == .opening {
            // Best-effort polite close so the host can teardown the shell.
            let message = TerminalCloseMessage(sessionID: sessionID, terminalID: terminalID, reason: "client-disconnect")
            if let envelope = try? DataChannelEnvelope.terminalClose(message) {
                try? sendEnvelope?(envelope)
            }
        }
        sessionID = nil
        terminalID = nil
        sendEnvelope = nil
        state = .idle
        output.removeAll()
        lastObservedSequence = 0
    }

    // MARK: - Outgoing

    func open(cols: UInt16, rows: UInt16) {
        guard let sessionID, let sendEnvelope else { return }
        let id = UUID()
        terminalID = id
        state = .opening
        output.removeAll()
        lastObservedSequence = 0
        let message = TerminalOpenMessage(sessionID: sessionID, terminalID: id, cols: cols, rows: rows)
        if let envelope = try? DataChannelEnvelope.terminalOpen(message) {
            try? sendEnvelope(envelope)
            // Optimistic: the host has no "ack" today; we'll mark open on
            // the first output chunk. Until then the view shows a spinner.
        }
    }

    func sendInput(_ data: Data) {
        guard let sessionID, let terminalID, let sendEnvelope,
              !data.isEmpty,
              data.count <= TerminalInputMessage.maxChunkBytes else { return }
        let message = TerminalInputMessage(sessionID: sessionID, terminalID: terminalID, data: data)
        if let envelope = try? DataChannelEnvelope.terminalInput(message) {
            try? sendEnvelope(envelope)
        }
    }

    func requestResize(cols: UInt16, rows: UInt16) {
        guard let sessionID, let terminalID, let sendEnvelope, cols > 0, rows > 0 else { return }
        let message = TerminalResizeMessage(sessionID: sessionID, terminalID: terminalID, cols: cols, rows: rows)
        if let envelope = try? DataChannelEnvelope.terminalResize(message) {
            try? sendEnvelope(envelope)
        }
    }

    func close(reason: String? = "user-closed") {
        guard let sessionID, let terminalID, let sendEnvelope else { return }
        let message = TerminalCloseMessage(sessionID: sessionID, terminalID: terminalID, reason: reason)
        if let envelope = try? DataChannelEnvelope.terminalClose(message) {
            try? sendEnvelope(envelope)
        }
        state = .closed(exitCode: nil, signal: nil, reason: reason)
        self.terminalID = nil
    }

    // MARK: - Incoming (called by ClientSessionCoordinator)

    func receiveOutput(_ message: TerminalOutputMessage) {
        guard message.sessionID == sessionID,
              message.terminalID == terminalID else { return }
        if message.sequence <= lastObservedSequence { return }
        lastObservedSequence = message.sequence
        if state == .opening { state = .open }
        output.append(message)
        if output.count > outputBacklogCap {
            output.removeFirst(output.count - outputBacklogCap)
        }
    }

    func receiveClose(_ message: TerminalCloseMessage) {
        guard message.sessionID == sessionID,
              message.terminalID == terminalID else { return }
        state = .closed(exitCode: message.exitCode, signal: message.signal, reason: message.reason)
        terminalID = nil
    }
}
