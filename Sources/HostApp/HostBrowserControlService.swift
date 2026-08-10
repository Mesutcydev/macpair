#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import Network
import SharedProtocol
import TransportWebRTC
import os

/// The web control plane is private to this Mac and its Tailscale interface.
/// When Tailscale is available the listener accepts loopback (for `tailscale
/// serve`) and tailnet traffic, while rejecting ordinary LAN paths. Without
/// Tailscale it remains loopback-only.
struct HostBrowserControlStatus: Equatable, Sendable {
    let running: Bool
    let port: UInt16?
    let tailscaleHost: String?
    let pairingCode: String
    let pairingCodeExpiresAt: Date
    let lastError: String?

    var serveCommand: String? {
        guard let port else { return nil }
        return "tailscale serve --bg http://127.0.0.1:\(port)"
    }
}

/// Normalizes the six-digit code shown by the host. Pairing codes can be
/// pasted with spaces or hyphens, and whole-number digits from another locale
/// should behave the same as ASCII digits.
enum HostBrowserPairingCode {
    static let length = 6

    static func normalize(_ raw: String) -> String? {
        var digits = ""
        digits.reserveCapacity(length)

        for character in raw {
            if character.isWhitespace || character == "-" || character == "·" {
                continue
            }
            guard let value = character.wholeNumberValue, (0...9).contains(value) else {
                return nil
            }
            digits.append(String(value))
        }

        return digits.count == length ? digits : nil
    }

    static func generate() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}

/// Builds the private URL encoded in the host QR card. The authenticated
/// browser token is still issued by POST /api/pair and is never placed in the
/// QR code or URL.
enum HostBrowserPairingLink {
    static func make(baseURL: String, code: String) -> String? {
        guard let normalizedCode = HostBrowserPairingCode.normalize(code),
              var components = URLComponents(string: baseURL),
              let scheme = components.scheme, !scheme.isEmpty,
              let host = components.host, !host.isEmpty else {
            return nil
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "pair" }
        queryItems.append(URLQueryItem(name: "pair", value: normalizedCode))
        components.queryItems = queryItems
        return components.url?.absoluteString
    }
}

/// A small, dependency-free browser gateway for terminal-only control.
///
/// The browser protocol is intentionally separate from the WebRTC media
/// session: Safari gets a focused task-chat terminal, not screen capture or
/// remote input. Each browser connection owns one bounded HostTerminalService
/// and therefore keeps up to eight shell tabs independent from one another.
final class HostBrowserControlService: @unchecked Sendable {
    static let defaultPort: UInt16 = 9475
    static let maxBrowserClients = 1
    static let pairingCodeLifetime: TimeInterval = 10 * 60
    static let browserTokenLifetime: TimeInterval = 30 * 60
    static let maxHTTPBodyBytes = 4 * 1024
    static let maxWebSocketFrameBytes = 64 * 1024

    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "BrowserControl")
    private let queue = DispatchQueue(label: "com.remotedesktop.host.browser-control", qos: .userInitiated)
    private var listener: NWListener?
    private var listenerReady = false
    private var tailscaleListenerHost: String?
    private var clients: [UUID: BrowserClient] = [:]
    private var pairingCode = HostBrowserPairingCode.generate()
    private var pairingCodeIssuedAt = Date()
    private var browserToken: String?
    private var browserTokenExpiresAt: Date?
    private var failedPairAttempts = 0
    private var firstFailedPairAttemptAt: Date?

    /// These providers are installed by HostAppEnvironment after all of its
    /// dependencies have been initialized.
    var terminalModeProvider: () -> Bool = { false }
    var readClipboard: () -> String? = { nil }
    var writeClipboard: (String) -> Void = { _ in }
    var onStatusChange: (@Sendable (HostBrowserControlStatus) -> Void)?

    deinit {
        stop()
    }

    func start(port: UInt16 = HostBrowserControlService.defaultPort, tailscaleHost: String? = nil) {
        queue.async { [weak self] in
            // Resolve again on the service queue. The host environment may
            // start the browser service while the Tailscale daemon is still
            // waking up, and the direct tailnet endpoint should not depend on
            // a single early probe.
            let resolvedTailscaleHost = tailscaleHost ?? getTailscaleConnectionInfo()?.ipAddress
            self?._start(port: port, tailscaleHost: resolvedTailscaleHost)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?._stop()
        }
    }

    @discardableResult
    func rotatePairingCode() -> HostBrowserControlStatus {
        queue.sync {
            issuePairingCode()
            revokeBrowserSessions(reason: "pairing-code-rotated")
            publishStatus()
            return currentStatusOnQueue()
        }
    }

    func currentStatus() -> HostBrowserControlStatus {
        queue.sync {
            HostBrowserControlStatus(
                running: listener != nil && listenerReady,
                port: listener?.port?.rawValue,
                tailscaleHost: tailscaleListenerHost,
                pairingCode: pairingCode,
                pairingCodeExpiresAt: pairingCodeIssuedAt.addingTimeInterval(Self.pairingCodeLifetime),
                lastError: nil
            )
        }
    }

    // MARK: Listener lifecycle

    private func _start(port: UInt16, tailscaleHost: String?) {
        let hasTailscaleHost = tailscaleHost.map { !$0.isEmpty } ?? false

        // Network.framework reserves a TCP port process-wide when a listener
        // is bound to loopback, so a second listener on the same port cannot
        // be added for the 100.x Tailscale address. Bind once to all local
        // interfaces when Tailscale is available; keep loopback-only mode
        // when no tailnet address is detected.
        if listener != nil,
           hasTailscaleHost,
           tailscaleListenerHost == nil {
            listener?.cancel()
            listener = nil
            listenerReady = false
        } else if listener != nil {
            publishStatus()
            return
        }

        let bindHost = hasTailscaleHost ? NWEndpoint.Host("0.0.0.0") : .ipv4(.loopback)
        let label = hasTailscaleHost ? "loopback + Tailscale" : "loopback"
        do {
            let newListener = try makeListener(port: port, host: bindHost, label: label) { [weak self] stoppedListener in
                // A loopback listener can be replaced by the all-interface
                // listener once Tailscale wakes up. Its cancellation callback
                // may arrive after the replacement is installed, so it must
                // never clear a newer listener.
                guard let self, self.listener === stoppedListener else { return }
                self.listenerReady = false
                self.listener = nil
                self.tailscaleListenerHost = nil
            }
            listener = newListener
            listenerReady = false
            tailscaleListenerHost = hasTailscaleHost ? tailscaleHost : nil
            newListener.start(queue: queue)
        } catch {
            logger.error("Could not create browser control listener: \(error.localizedDescription, privacy: .public)")
            listener = nil
            listenerReady = false
            tailscaleListenerHost = nil
            publishStatus(error: error.localizedDescription)
        }
        publishStatus()
    }

    private func makeListener(
        port: UInt16,
        host: NWEndpoint.Host,
        label: String,
        onStopped: @escaping @Sendable (NWListener) -> Void
    ) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: host,
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        let newListener = try NWListener(using: parameters)
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info("Browser control \(label, privacy: .public) listener ready on port \(newListener?.port?.rawValue ?? 0)")
                if let newListener, self.listener === newListener {
                    self.listenerReady = true
                    // Issue the code only after the active listener is ready.
                    // A code shown while a replacement socket is still
                    // binding can otherwise look valid but hit the old host.
                    self.issuePairingCode()
                }
                self.publishStatus()
            case .failed(let error):
                self.logger.error("Browser control \(label, privacy: .public) listener failed: \(error.localizedDescription, privacy: .public)")
                if let newListener { onStopped(newListener) }
                self.publishStatus(error: error.localizedDescription)
            case .cancelled:
                if let newListener { onStopped(newListener) }
                self.publishStatus()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return newListener
    }

    private func _stop() {
        listener?.cancel()
        listener = nil
        listenerReady = false
        tailscaleListenerHost = nil
        revokeBrowserSessions(reason: "browser-server-stopped")
        browserToken = nil
        browserTokenExpiresAt = nil
        publishStatus()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let client = BrowserClient(id: id, connection: connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard self.allowsBrowserPath(connection?.currentPath) else {
                    self.logger.warning("Rejecting browser connection outside loopback or Tailscale")
                    self.remove(clientID: id, connection: connection)
                    return
                }
                self.receive(on: client)
            case .failed, .cancelled:
                self.remove(clientID: id, connection: connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func allowsBrowserPath(_ path: NWPath?) -> Bool {
        guard tailscaleListenerHost != nil else { return true }
        guard let path else { return false }
        // Tailscale's utun interface is reported by Network.framework as
        // `.other`; loopback remains required for `tailscale serve`.
        return path.usesInterfaceType(.loopback) || path.usesInterfaceType(.other)
    }

    private func remove(clientID: UUID, connection: NWConnection?) {
        guard let client = clients.removeValue(forKey: clientID) else { return }
        client.terminalService?.sessionDidEnd(reason: "browser-disconnected")
        if connection == nil || connection === client.connection {
            client.connection.cancel()
        }
    }

    // MARK: HTTP

    private func receive(on client: BrowserClient) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxWebSocketFrameBytes) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            if let error {
                self.logger.debug("Browser connection read ended: \(error.localizedDescription, privacy: .public)")
                self.remove(clientID: client.id, connection: client.connection)
                return
            }
            if let data, !data.isEmpty {
                client.receiveBuffer.append(data)
                if client.mode == .http {
                    self.handleHTTPBuffer(for: client)
                } else {
                    self.handleWebSocketBuffer(for: client)
                }
            }
            if isComplete {
                self.remove(clientID: client.id, connection: client.connection)
            } else if self.clients[client.id] != nil {
                // Re-arm on the next turn of the service queue. Re-entering
                // NWConnection.receive from inside its completion can leave a
                // manually upgraded TCP stream with no second read request;
                // that is especially visible when Safari/Chrome sends its
                // first WebSocket command after the 101 response.
                self.queue.async { [weak self, weak client] in
                    guard let self, let client, self.clients[client.id] != nil else { return }
                    self.receive(on: client)
                }
            }
        }
    }

    private func handleHTTPBuffer(for client: BrowserClient) {
        guard let headerEnd = client.receiveBuffer.range(of: Data("\r\n\r\n".utf8)) else {
            if client.receiveBuffer.count > 16 * 1024 {
                remove(clientID: client.id, connection: client.connection)
            }
            return
        }

        let headerData = client.receiveBuffer.subdata(in: 0..<headerEnd.lowerBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first,
              let request = Self.parseRequestLine(requestLine) else {
            sendHTTP(.badRequest, body: "Bad request", to: client)
            return
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsedContentLength = Int(rawContentLength),
                  parsedContentLength >= 0,
                  parsedContentLength <= Self.maxHTTPBodyBytes else {
                sendHTTP(.badRequest, body: "Invalid request body", to: client)
                return
            }
            contentLength = parsedContentLength
        } else {
            contentLength = 0
        }
        let bodyStart = headerEnd.upperBound
        guard client.receiveBuffer.count >= bodyStart + contentLength else { return }
        let body = client.receiveBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        client.receiveBuffer.removeSubrange(0..<(bodyStart + contentLength))

        if request.path == "/socket",
           request.method == "GET",
           headers["upgrade"]?.lowercased() == "websocket",
           let websocketKey = headers["sec-websocket-key"] {
            upgradeToWebSocket(client, request: request, key: websocketKey)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            sendHTTP(.ok, contentType: "text/html; charset=utf-8", body: BrowserControlWebAssets.indexHTML, to: client)
        case ("GET", "/api/status"):
            sendHTTP(.ok, contentType: "application/json", body: statusJSON(), to: client)
        case ("POST", "/api/pair"):
            handlePair(body: body, client: client)
        default:
            sendHTTP(.notFound, body: "Not found", to: client)
        }
    }

    private func handlePair(body: Data, client: BrowserClient) {
        guard terminalModeProvider() else {
            sendHTTP(.forbidden, contentType: "application/json", body: "{\"error\":\"terminal-disabled\"}", to: client)
            return
        }
        guard canAttemptPairing() else {
            sendHTTP(.tooManyRequests, body: "Too many pairing attempts", to: client)
            return
        }
        guard let payload = try? JSONDecoder().decode(BrowserPairRequest.self, from: body),
              let code = payload.code.flatMap(HostBrowserPairingCode.normalize),
              Self.constantTimeEqual(code, pairingCode),
              Date().timeIntervalSince(pairingCodeIssuedAt) < Self.pairingCodeLifetime else {
            recordPairFailure()
            sendHTTP(.unauthorized, contentType: "application/json", body: "{\"error\":\"invalid-code\"}", to: client)
            return
        }

        failedPairAttempts = 0
        firstFailedPairAttemptAt = nil
        let token = Self.makeToken()
        browserToken = token
        browserTokenExpiresAt = Date().addingTimeInterval(Self.browserTokenLifetime)
        let response = BrowserPairResponse(token: token, expiresAt: browserTokenExpiresAt ?? Date())
        sendHTTP(.ok, contentType: "application/json", body: Self.jsonString(response), to: client)
    }

    private func canAttemptPairing() -> Bool {
        if let first = firstFailedPairAttemptAt,
           Date().timeIntervalSince(first) >= 60 {
            failedPairAttempts = 0
            firstFailedPairAttemptAt = nil
        }
        return failedPairAttempts < 8
    }

    private func recordPairFailure() {
        firstFailedPairAttemptAt = firstFailedPairAttemptAt ?? Date()
        failedPairAttempts += 1
    }

    private func statusJSON() -> String {
        let status = currentStatusOnQueue()
        let response = BrowserStatusResponse(
            terminalModeEnabled: terminalModeProvider(),
            maxTerminals: HostTerminalService.maxActiveTerminals,
            running: status.running,
            tailscaleHost: status.tailscaleHost,
            pairingCodeExpiresAt: status.pairingCodeExpiresAt
        )
        return Self.jsonString(response)
    }

    private func upgradeToWebSocket(_ client: BrowserClient, request: BrowserHTTPRequest, key: String) {
        guard let token = request.query["token"],
              let storedToken = browserToken,
              let expiresAt = browserTokenExpiresAt,
              Date() < expiresAt,
              Self.constantTimeEqual(token, storedToken) else {
            sendHTTP(.unauthorized, body: "Pair this browser first", to: client)
            return
        }
        guard terminalModeProvider() else {
            sendHTTP(.forbidden, contentType: "application/json", body: "{\"error\":\"terminal-disabled\"}", to: client)
            return
        }
        guard clients.values.filter({ $0.mode == .webSocket }).count < Self.maxBrowserClients else {
            sendHTTP(.conflict, contentType: "application/json", body: "{\"error\":\"browser-capacity\"}", to: client)
            return
        }

        let accept = Self.websocketAcceptValue(key: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

        // Switch the client into WebSocket mode before writing the 101
        // response. Chrome can send the first terminal-open frame as soon as
        // it observes the handshake, while NWConnection may still deliver
        // that frame through the receive callback that started in HTTP mode.
        // Deferring this state change until the send completion races the
        // browser and leaves tabs stuck at "Opening shell…" with no PTY.
        client.mode = .webSocket
        client.sessionID = UUID()
        let terminalService = HostTerminalService()
        terminalService.sendEnvelope = { [weak self, weak client] envelope in
            guard let self, let client else { return }
            self.queue.async {
                self.sendTerminalEnvelope(envelope, to: client)
            }
        }
        client.terminalService = terminalService

        let hello = BrowserHelloEvent(
            sessionID: client.sessionID ?? UUID(),
            maxTerminals: HostTerminalService.maxActiveTerminals,
            capabilities: ["terminal", "multiple-terminals", "clipboard", "approval-cards", "tmux", "screen"]
        )
        sendRaw(Data(response.utf8), to: client) { [weak self, weak client] in
            guard let self, let client, self.clients[client.id] != nil else { return }
            self.sendJSON(hello, to: client)
        }

        // A client is allowed to pipeline its first frame with the upgrade
        // request. Process anything already buffered now that the protocol
        // mode has changed; otherwise it would sit until another frame arrives.
        if !client.receiveBuffer.isEmpty {
            handleWebSocketBuffer(for: client)
        }
    }

    // MARK: WebSocket terminal protocol

    private func handleWebSocketBuffer(for client: BrowserClient) {
        while let frame = Self.decodeFrame(from: &client.receiveBuffer) {
            switch frame.opcode {
            case 0x8: // close
                sendWebSocketFrame(Data(), opcode: 0x8, to: client)
                remove(clientID: client.id, connection: client.connection)
                return
            case 0x9: // ping
                sendWebSocketFrame(frame.payload, opcode: 0xA, to: client)
            case 0x1: // text
                handleWebSocketCommand(frame.payload, client: client)
            default:
                sendError("unsupported-frame", to: client)
            }
        }
    }

    private func handleWebSocketCommand(_ data: Data, client: BrowserClient) {
        guard data.count <= Self.maxWebSocketFrameBytes,
              let command = try? JSONDecoder().decode(BrowserTerminalCommand.self, from: data),
              let type = command.type?.lowercased(),
              let sessionID = client.sessionID,
              let terminalService = client.terminalService else {
            sendError("invalid-command", to: client)
            return
        }
        guard terminalModeProvider() else {
            sendError("terminal-disabled", terminalID: command.terminalID, to: client)
            return
        }

        switch type {
        case "open":
            guard let terminalID = command.terminalID,
                  let cols = command.cols, let rows = command.rows,
                  cols > 0, rows > 0, cols <= 1000, rows <= 1000 else {
                sendError("invalid-terminal-size", terminalID: command.terminalID, to: client)
                return
            }
            if let startupCommand = command.startupCommand, startupCommand.utf8.count > TerminalOpenMessage.maxStartupCommandLength {
                sendError("startup-command-too-large", terminalID: command.terminalID, to: client)
                return
            }
            terminalService.handleOpen(TerminalOpenMessage(
                sessionID: sessionID,
                terminalID: terminalID,
                cols: cols,
                rows: rows,
                term: command.term ?? "xterm-256color",
                startupCommand: command.startupCommand
            ))
        case "input":
            guard let terminalID = command.terminalID,
                  let encoded = command.data,
                  let input = Data(base64Encoded: encoded),
                  !input.isEmpty,
                  input.count <= TerminalInputMessage.maxChunkBytes else {
                sendError("invalid-input", terminalID: command.terminalID, to: client)
                return
            }
            terminalService.handleInput(TerminalInputMessage(sessionID: sessionID, terminalID: terminalID, data: input))
        case "resize":
            guard let terminalID = command.terminalID,
                  let cols = command.cols, let rows = command.rows,
                  cols > 0, rows > 0, cols <= 1000, rows <= 1000 else {
                sendError("invalid-terminal-size", terminalID: command.terminalID, to: client)
                return
            }
            terminalService.handleResize(TerminalResizeMessage(sessionID: sessionID, terminalID: terminalID, cols: cols, rows: rows))
        case "close":
            guard let terminalID = command.terminalID else { sendError("invalid-terminal", to: client); return }
            terminalService.handleClose(TerminalCloseMessage(sessionID: sessionID, terminalID: terminalID, reason: "browser-requested"))
        case "clipboardget":
            let text = String((readClipboard() ?? "").prefix(ClipboardSyncMessage.maxContentLength))
            sendJSON(BrowserClipboardEvent(text: text), to: client)
        case "clipboardset":
            guard let text = command.text, text.utf8.count <= ClipboardSyncMessage.maxContentLength else {
                sendError("clipboard-too-large", terminalID: command.terminalID, to: client)
                return
            }
            writeClipboard(text)
            sendJSON(BrowserClipboardEvent(text: text), to: client)
        case "ping":
            sendJSON(BrowserPongEvent(), to: client)
        default:
            sendError("unknown-command", terminalID: command.terminalID, to: client)
        }
    }

    private func sendTerminalEnvelope(_ envelope: DataChannelEnvelope, to client: BrowserClient) {
        guard client.mode == .webSocket else {
            logger.warning("Dropping terminal envelope because browser client is not in WebSocket mode")
            return
        }
        switch envelope.kind {
        case .terminalReady:
            guard let message = try? envelope.decodeTerminalReady() else {
                logger.error("Could not decode terminal-ready envelope for browser")
                return
            }
            sendJSON(BrowserReadyEvent(terminalID: message.terminalID, cols: message.cols, rows: message.rows), to: client)
        case .terminalOutput:
            guard let message = try? envelope.decodeTerminalOutput() else {
                logger.error("Could not decode terminal-output envelope for browser")
                return
            }
            sendJSON(BrowserOutputEvent(terminalID: message.terminalID, data: message.data.base64EncodedString(), sequence: message.sequence), to: client)
        case .terminalClose:
            guard let message = try? envelope.decodeTerminalClose() else {
                logger.error("Could not decode terminal-close envelope for browser")
                return
            }
            sendJSON(BrowserCloseEvent(terminalID: message.terminalID, reason: message.reason ?? "closed"), to: client)
        default:
            break
        }
    }

    private func sendError(_ code: String, terminalID: UUID? = nil, to client: BrowserClient) {
        sendJSON(BrowserErrorEvent(code: code, terminalID: terminalID), to: client)
    }

    // MARK: Wire helpers

    private func sendHTTP(
        _ status: HTTPStatus,
        contentType: String = "text/plain; charset=utf-8",
        body: String,
        to client: BrowserClient
    ) {
        let data = Data(body.utf8)
        let response = "HTTP/1.1 \(status.code) \(status.reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'\r\n"
            + "Connection: close\r\n\r\n"
        sendRaw(Data(response.utf8) + data, to: client) { [weak self] in
            self?.remove(clientID: client.id, connection: client.connection)
        }
    }

    private func sendJSON<T: Encodable>(_ value: T, to client: BrowserClient) {
        guard let data = try? JSONEncoder().encode(value) else {
            logger.error("Could not encode browser WebSocket event")
            return
        }
        sendWebSocketFrame(data, opcode: 0x1, to: client)
    }

    private func sendRaw(_ data: Data, to client: BrowserClient, completion: (() -> Void)? = nil) {
        client.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { completion?() }
        })
    }

    private func sendWebSocketFrame(_ payload: Data, opcode: UInt8, to client: BrowserClient) {
        guard payload.count <= Self.maxWebSocketFrameBytes else {
            sendError("response-too-large", to: client)
            return
        }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(126)
            frame.append(contentsOf: UInt16(payload.count).bigEndianBytes)
        } else {
            frame.append(127)
            frame.append(contentsOf: UInt64(payload.count).bigEndianBytes)
        }
        frame.append(payload)
        sendRaw(frame, to: client)
    }

    private func publishStatus(error: String? = nil) {
        let status = HostBrowserControlStatus(
            running: listener != nil && listenerReady,
            port: listener?.port?.rawValue,
            tailscaleHost: tailscaleListenerHost,
            pairingCode: pairingCode,
            pairingCodeExpiresAt: pairingCodeIssuedAt.addingTimeInterval(Self.pairingCodeLifetime),
            lastError: error
        )
        onStatusChange?(status)
    }

    private func currentStatusOnQueue() -> HostBrowserControlStatus {
        HostBrowserControlStatus(
            running: listener != nil && listenerReady,
            port: listener?.port?.rawValue,
            tailscaleHost: tailscaleListenerHost,
            pairingCode: pairingCode,
            pairingCodeExpiresAt: pairingCodeIssuedAt.addingTimeInterval(Self.pairingCodeLifetime),
            lastError: nil
        )
    }

    private static func parseRequestLine(_ line: String) -> BrowserHTTPRequest? {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, let url = URLComponents(string: parts[1]) else { return nil }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return BrowserHTTPRequest(method: parts[0].uppercased(), path: url.path.isEmpty ? "/" : url.path, query: query)
    }

    private static func websocketAcceptValue(key: String) -> String {
        let source = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return Data(Insecure.SHA1.hash(data: source)).base64EncodedString()
    }

    private static func decodeFrame(from buffer: inout Data) -> BrowserWebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        // Browser-to-server frames must be final, unfragmented, masked frames.
        // Rejecting anything else keeps this intentionally small parser from
        // accepting protocol variants it cannot safely reassemble.
        guard first & 0x80 != 0,
              first & 0x70 == 0,
              second & 0x80 != 0 else {
            buffer.removeAll()
            return BrowserWebSocketFrame(opcode: 0x8, payload: Data())
        }
        let opcode = first & 0x0F
        let masked = true
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            // readUInt16 already assembles the network-order bytes into a
            // host-order value. Applying a second endian swap makes every
            // launcher command over 125 bytes appear incomplete forever.
            length = Int(buffer.readUInt16(at: offset))
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            let longLength = buffer.readUInt64(at: offset)
            guard longLength <= UInt64(Self.maxWebSocketFrameBytes) else {
                buffer.removeAll()
                return BrowserWebSocketFrame(opcode: 0x8, payload: Data())
            }
            length = Int(longLength)
            offset += 8
        }
        guard length <= Self.maxWebSocketFrameBytes,
              opcode != 0,
              opcode < 0x8 || length <= 125 else {
            buffer.removeAll()
            return BrowserWebSocketFrame(opcode: 0x8, payload: Data())
        }
        var mask: [UInt8] = []
        guard buffer.count >= offset + 4 else { return nil }
        mask = Array(buffer[offset..<(offset + 4)])
        offset += 4
        guard buffer.count >= offset + length else { return nil }
        var payload = Data(buffer[offset..<(offset + length)])
        buffer.removeSubrange(0..<(offset + length))
        if masked {
            for index in 0..<payload.count {
                payload[index] ^= mask[index % 4]
            }
        }
        return BrowserWebSocketFrame(opcode: opcode, payload: payload)
    }

    private func issuePairingCode() {
        pairingCode = HostBrowserPairingCode.generate()
        pairingCodeIssuedAt = Date()
        browserToken = nil
        browserTokenExpiresAt = nil
        failedPairAttempts = 0
        firstFailedPairAttemptAt = nil
    }

    private func revokeBrowserSessions(reason: String) {
        let currentClients = Array(clients.values)
        clients.removeAll()
        for client in currentClients {
            client.terminalService?.sessionDidEnd(reason: reason)
            client.connection.cancel()
        }
    }

    private static func makeToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Data(lhs.utf8)
        let right = Data(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(left, right) { difference |= a ^ b }
        return difference == 0
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class BrowserClient: @unchecked Sendable {
    enum Mode { case http, webSocket }

    let id: UUID
    let connection: NWConnection
    var mode: Mode = .http
    var receiveBuffer = Data()
    var sessionID: UUID?
    var terminalService: HostTerminalService?

    init(id: UUID, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }
}

private struct BrowserHTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
}

private struct BrowserWebSocketFrame {
    let opcode: UInt8
    let payload: Data
}

private enum HTTPStatus {
    case ok, badRequest, unauthorized, forbidden, notFound, conflict, tooManyRequests

    var code: Int {
        switch self {
        case .ok: return 200
        case .badRequest: return 400
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .conflict: return 409
        case .tooManyRequests: return 429
        }
    }

    var reason: String {
        switch self {
        case .ok: return "OK"
        case .badRequest: return "Bad Request"
        case .unauthorized: return "Unauthorized"
        case .forbidden: return "Forbidden"
        case .notFound: return "Not Found"
        case .conflict: return "Conflict"
        case .tooManyRequests: return "Too Many Requests"
        }
    }
}

private struct BrowserPairRequest: Decodable {
    let code: String?
}

private struct BrowserPairResponse: Encodable {
    let token: String
    let expiresAt: Date
}

private struct BrowserStatusResponse: Encodable {
    let terminalModeEnabled: Bool
    let maxTerminals: Int
    let running: Bool
    let tailscaleHost: String?
    let pairingCodeExpiresAt: Date
}

private struct BrowserTerminalCommand: Decodable {
    let type: String?
    let terminalID: UUID?
    let cols: UInt16?
    let rows: UInt16?
    let term: String?
    let startupCommand: String?
    let data: String?
    let text: String?
}

private struct BrowserHelloEvent: Encodable {
    let type = "hello"
    let sessionID: UUID
    let maxTerminals: Int
    let capabilities: [String]
}

private struct BrowserReadyEvent: Encodable {
    let type = "ready"
    let terminalID: UUID
    let cols: UInt16
    let rows: UInt16
}

private struct BrowserOutputEvent: Encodable {
    let type = "output"
    let terminalID: UUID
    let data: String
    let sequence: UInt64
}

private struct BrowserCloseEvent: Encodable {
    let type = "close"
    let terminalID: UUID
    let reason: String
}

private struct BrowserErrorEvent: Encodable {
    let type = "error"
    let code: String
    let terminalID: UUID?
}

private struct BrowserClipboardEvent: Encodable {
    let type = "clipboard"
    let text: String
}

private struct BrowserPongEvent: Encodable {
    let type = "pong"
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}

private extension UInt64 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 56) & 0xFF), UInt8((self >> 48) & 0xFF),
            UInt8((self >> 40) & 0xFF), UInt8((self >> 32) & 0xFF),
            UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)
        ]
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        let a = UInt16(self[self.startIndex + offset])
        let b = UInt16(self[self.startIndex + offset + 1])
        return (a << 8) | b
    }

    func readUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(self[self.startIndex + offset + index])
        }
        return value
    }
}

private enum BrowserControlWebAssets {
    static let indexHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#151515"><title>Vamp Terminal · Task chat</title>
<style>
:root{color-scheme:dark;--bg:#151515;--panel:rgba(44,44,44,.76);--panel2:rgba(30,30,30,.88);--line:rgba(255,255,255,.12);--muted:#a3a3a3;--text:#f1f1f1;--accent:#f5f5f5;--good:#42d392;--warn:#ffc857;--danger:#ff756b;--u:4px;--s1:4px;--s2:8px;--s3:12px;--s4:16px;--s5:20px;--s6:24px;--control:44px;--radius-card:20px;--radius-control:12px}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 20% -10%,#383838 0,transparent 40%),linear-gradient(145deg,#111,#191919 55%,#101010);color:var(--text);font:15px -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;min-height:100vh}button,input{font:inherit}button{color:inherit;border:0;cursor:pointer}.shell{max-width:980px;margin:auto;min-height:100vh;padding:env(safe-area-inset-top) 14px env(safe-area-inset-bottom);display:flex;flex-direction:column}.top{height:54px;display:flex;align-items:center;gap:11px;border-bottom:1px solid var(--line)}.back{background:none;color:#bbb;font-size:22px;width:32px}.title{font-weight:650;font-size:17px}.top .state{margin-left:auto;color:var(--muted);font-size:12px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--muted);margin-right:6px}.dot.connected{background:var(--good)}.dot.connecting,.dot.pairing{background:var(--warn)}.dot.offline,.dot.error,.dot.disabled{background:var(--danger)}.tabs{display:flex;align-items:center;gap:8px;padding:12px 0 9px;overflow-x:auto;scrollbar-width:none}.tabs::-webkit-scrollbar{display:none}.tab{display:flex;align-items:center;gap:7px;white-space:nowrap;background:rgba(255,255,255,.08);border:1px solid transparent;border-radius:17px;padding:8px 12px;color:#bbb}.tab.active{border-color:rgba(255,255,255,.22);background:rgba(255,255,255,.14);color:#fff}.tab .close{color:#888;background:none;padding:0 0 0 3px}.newtab{background:rgba(255,255,255,.1);border-radius:16px;padding:8px 11px;font-size:18px}.content{display:flex;flex:1;min-height:0}.chat{flex:1;min-width:0;padding:12px 0 120px}.stream{display:none}.stream.active{display:block}.message{margin:0 0 18px;line-height:1.55}.message .meta{color:#777;font-size:12px;margin-bottom:6px}.message .body{white-space:pre-wrap;word-break:break-word}.explore{color:#bbb;font-size:13px;margin:12px 0 18px}.explore span{color:#666;margin:0 6px}.command-card{background:rgba(45,45,45,.8);border:1px solid var(--line);border-radius:17px;padding:12px;margin:13px 0 20px;box-shadow:0 10px 34px rgba(0,0,0,.16)}.command-card .eyebrow{color:#aaa;font-size:13px;margin-bottom:10px}.command-card .approval{color:#aaa;margin:7px 0 11px}.command{background:rgba(15,15,15,.7);border:1px solid rgba(255,255,255,.1);border-radius:12px;padding:12px;white-space:pre-wrap;overflow:auto;font:14px ui-monospace,SFMono-Regular,Menlo,monospace;color:#e8e8e8}.command .prompt{color:#aaa}.approval-actions{display:flex;gap:8px;align-items:center;margin-top:11px}.approval-actions button{border-radius:11px;padding:10px 13px;background:#eee;color:#161616;font-weight:650}.approval-actions button.secondary{background:rgba(255,255,255,.12);color:#eee}.approval-actions button.danger{background:rgba(255,117,107,.16);color:#ffb4ae}.terminal{background:#0b0b0b;border:1px solid rgba(255,255,255,.12);border-radius:14px;padding:14px;min-height:150px;max-height:48vh;overflow:auto;font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;color:#e8e8e8;white-space:pre-wrap;word-break:break-word}.terminal:focus{outline:2px solid rgba(255,255,255,.35);outline-offset:2px}.quick{display:flex;gap:7px;overflow:auto;padding:10px 0;scrollbar-width:none}.quick::-webkit-scrollbar{display:none}.quick button{background:rgba(255,255,255,.1);border:1px solid var(--line);border-radius:9px;padding:8px 11px;white-space:nowrap;color:#ddd}.composer{position:fixed;left:14px;right:14px;bottom:max(12px,env(safe-area-inset-bottom));margin:auto;max-width:952px;background:rgba(44,44,44,.9);border:1px solid rgba(255,255,255,.16);border-radius:16px;padding:8px;display:flex;gap:7px;box-shadow:0 12px 40px rgba(0,0,0,.35);backdrop-filter:blur(18px)}.composer input{flex:1;min-width:0;background:transparent;border:0;outline:0;color:#fff;padding:8px}.composer input::placeholder{color:#777}.composer button{width:42px;height:38px;border-radius:11px;background:rgba(255,255,255,.1);font-size:17px}.composer button.send{background:#f5f5f5;color:#111;font-weight:700}.empty{color:#999;padding:35px 8px;text-align:center}.badge{color:#999;font-size:12px;margin:5px 0 15px}.modal{position:fixed;inset:0;background:rgba(0,0,0,.62);display:flex;align-items:center;justify-content:center;padding:20px;z-index:3}.modal.hidden{display:none}.modal-card{width:min(420px,100%);background:#2b2b2b;border:1px solid rgba(255,255,255,.18);border-radius:18px;padding:18px;box-shadow:0 18px 70px #000}.modal-card h2{margin:0 0 7px;font-size:20px}.modal-card p{color:#aaa;line-height:1.45}.modal-card input{width:100%;background:#171717;border:1px solid var(--line);border-radius:10px;padding:12px;color:#fff;letter-spacing:.18em;text-align:center}.modal-card button{margin-top:12px;border-radius:11px;padding:11px 14px;background:#eee;color:#111;font-weight:650}.modal-card .error{color:#ffaaa4;min-height:18px;font-size:13px}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}@media(min-width:720px){.shell{padding-left:28px;padding-right:28px}.composer{left:28px;right:28px}.terminal{max-height:50vh}.chat{padding-top:20px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
/* The browser surface follows the same four-point rhythm as the iOS client.
   Keep the original CSS above intentionally small; these rules provide the
   responsive controls without making the embedded asset depend on a bundle. */
.tab{min-height:40px}.newtab{min-width:44px;min-height:44px}.quick button{min-height:40px}.composer{z-index:4}.composer input{min-height:44px}.clipboard-wrap{position:relative;flex:0 0 auto}.clipboard-trigger{width:auto!important;min-width:44px;padding:0 12px;display:flex;align-items:center;justify-content:center;gap:6px}.clipboard-label{font-size:13px;font-weight:600}.clipboard-menu{position:absolute;left:0;bottom:calc(100% + 8px);z-index:6;min-width:230px;padding:8px;background:rgba(43,43,43,.96);border:1px solid rgba(255,255,255,.18);border-radius:14px;box-shadow:0 18px 48px rgba(0,0,0,.42);backdrop-filter:blur(18px)}.clipboard-menu.hidden{display:none}.clipboard-menu button{width:100%!important;height:auto!important;min-height:40px;padding:10px 12px;text-align:left;background:transparent;border-radius:9px;font-size:14px}.clipboard-menu button:hover,.clipboard-menu button:focus-visible{background:rgba(255,255,255,.12)}.approval-actions{flex-wrap:wrap}.tab-dot{color:var(--muted);font-size:11px}.tab-dot.open{color:var(--good)}.tab-dot.opening{color:var(--warn)}.modal-card input,.modal-card button{min-height:44px}@media(max-width:520px){.clipboard-label{display:none}.clipboard-trigger{padding:0 10px}}
</style></head>
<body><div class="shell">
<header class="top"><button class="back" id="back" aria-label="Open sessions dashboard" title="Open sessions dashboard" onclick="vampToggleDashboard()">‹</button><div class="title" id="page-title">Task chat</div><div class="state"><span class="dot"></span><span id="state">Pairing</span></div></header>
<nav class="tabs" id="tabs" aria-label="Terminal tabs"><button class="newtab" id="newtab" aria-label="New terminal">＋</button></nav>
<main class="content">
<section class="dashboard hidden" id="dashboard" aria-labelledby="dashboard-title">
  <div class="dashboard-heading"><div><div class="dashboard-kicker">VAMP TERMINAL</div><h1 id="dashboard-title">Sessions</h1><p>Choose a live shell or return to the task stream. Tabs stay independent while you switch.</p></div><button class="dashboard-open" id="dashboard-open" type="button">Open task chat</button></div>
  <article class="host-card"><div><div class="dashboard-kicker">HOST CONNECTION</div><h2 id="dashboard-host-title">This Mac</h2><p id="dashboard-host-detail">Checking Vamp Host…</p></div><span class="host-state" id="dashboard-host-state">●</span></article>
  <div class="session-heading"><h2>Active sessions</h2><span id="dashboard-count">0 / 8</span></div>
  <div class="session-grid" id="session-grid"></div>
</section>
<section class="chat" id="chat"><div class="empty" id="empty">Pair this browser to start a terminal task.</div></section>
</main>
<div class="composer" id="composer"><div class="clipboard-wrap"><button id="clipboard" class="clipboard-trigger" type="button" title="Clipboard actions" aria-label="Clipboard actions" aria-expanded="false">▣ <span class="clipboard-label">Clipboard</span></button><div id="clipboard-menu" class="clipboard-menu hidden" role="menu" aria-label="Clipboard actions"><button id="paste" type="button" role="menuitem">Paste into terminal</button><button id="copyhost" type="button" role="menuitem">Copy Mac clipboard to Safari</button><button id="sethost" type="button" role="menuitem">Send Safari clipboard to Mac</button></div></div><input id="input" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Type a command…"><button id="more" type="button" title="More controls" aria-label="More controls">•••</button><button class="send" id="send" type="button" title="Review command" aria-label="Review command">↑</button></div>
</div>
<div class="modal" id="pair"><div class="modal-card"><h2>Open this workspace</h2><p>Scan the QR code from Vamp Host, or enter the six-digit code shown in Settings → Browser control. The code expires after ten minutes.</p><input id="code" inputmode="numeric" maxlength="18" placeholder="000000" aria-label="Pairing code" autocomplete="one-time-code"><div class="error" id="pair-error"></div><button id="pair-button">Pair browser</button></div></div>
<div class="modal hidden" id="more-modal"><div class="modal-card more-card"><div class="more-kicker">Terminal actions</div><h2>Open a session</h2><p>Start a fresh shell, attach a persistent tmux or screen session, or open a coding agent in a new tab.</p><div class="more-actions"><button id="more-shell" type="button"><span class="provider-mark" style="--provider:#e8e8e8">›_</span><span><b>New shell</b><br><small>Open an independent terminal tab</small></span></button><button id="more-tmux" type="button" class="secondary"><span class="provider-mark" style="--provider:#9dd6ff">▣</span><span><b>Attach / create tmux</b><br><small>Resume a named workspace</small></span></button><button id="more-screen" type="button" class="secondary"><span class="provider-mark" style="--provider:#b8a6ff">▤</span><span><b>Attach screen</b><br><small>Resume a GNU screen session</small></span></button></div><div class="provider-title">Agent launchers</div><div class="provider-grid"><button type="button" data-provider="opencode" style="--provider:#00c8ce"><span class="provider-mark">◈</span><span>OpenCode</span></button><button type="button" data-provider="pi" style="--provider:#f57a48"><span class="provider-mark">π</span><span>Pi</span></button><button type="button" data-provider="commandcode" style="--provider:#b883ff"><span class="provider-mark">⌘</span><span>CommandCode</span></button><button type="button" data-provider="chatgpt" style="--provider:#10a37f"><span class="provider-mark">◌</span><span>ChatGPT CLI</span></button><button type="button" data-provider="claude" style="--provider:#dc6a42"><span class="provider-mark">✦</span><span>Claude Code</span></button><button type="button" data-provider="kimi" style="--provider:#4c8dff"><span class="provider-mark">K</span><span>Kimi</span></button><button type="button" data-provider="qwen" style="--provider:#4678f2"><span class="provider-mark">Q</span><span>Qwen Code</span></button><button type="button" data-provider="codex" style="--provider:#10a37f"><span class="provider-mark">⌘</span><span>Codex CLI</span></button><button type="button" data-provider="aider" style="--provider:#66c28c"><span class="provider-mark">A</span><span>Aider</span></button><button type="button" data-provider="grok" style="--provider:#e6a94f"><span class="provider-mark">G</span><span>Grok CLI</span></button></div><label class="more-command">Custom command or session<input id="more-command" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="tmux attach -t work"></label><div class="more-footer"><button id="more-cancel" class="secondary" type="button">Cancel</button><button id="more-open" type="button">Open tab</button></div></div></div>
<script>
const $=id=>document.getElementById(id);let ws=null,token=null,sessionId=null,active=null,order=[],tabs=new Map(),approved=new Set();
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}function strip(s){return s.replace(/[\u001b\u009b]\[[0-?]*[ -\/]*[@-~]/g,'').replace(/[\u001b\u009b][^\n]/g,'')}
function addMessage(html,tab=active){let el=document.createElement('div');el.className='message';el.innerHTML=html;$('chat').appendChild(el);el.scrollIntoView({block:'nearest'});return el}
function setState(s){$('state').textContent=s;const dot=document.querySelector('.dot');if(dot){const key=String(s||'').toLowerCase().replace(/\s+/g,'-');dot.className='dot '+(key==='connected'?'connected':key==='connecting'?'connecting':key==='pairing'?'pairing':key==='disabled'?'disabled':key==='offline'||key.includes('error')?'offline':'pairing')}}
function renderTabs(){let nav=$('tabs');nav.querySelectorAll('.tab').forEach(x=>x.remove());order.forEach(id=>{let t=tabs.get(id),b=document.createElement('button');b.className='tab '+(id===active?'active':'');b.dataset.id=id;b.innerHTML='<span class="tab-dot">'+(t.unread?'● ':'')+'</span>'+esc(t.title)+'<span class="close" aria-label="Close">×</span>';b.onclick=e=>{if(e.target.classList.contains('close'))closeTab(id);else selectTab(id)};nav.insertBefore(b,$('newtab'))})}
function createTab(startup=null,title=null){if(order.length>=8){addMessage('<div class="badge">Terminal capacity reached (8 tabs).</div>');return}let id=vampNewUUID(),t={id,title:title||'Terminal '+(order.length+1),startupCommand:startup,out:'',unread:false,opened:false};tabs.set(id,t);order.push(id);active=id;renderTabs();if(ws&&ws.readyState===1){send({type:'open',terminalID:id,cols:Math.max(40,Math.floor(innerWidth/8)),rows:Math.max(12,Math.floor((innerHeight-250)/21)),startupCommand:startup})}else{showPair();}$('input').focus();return id}
function selectTab(id){if(!tabs.has(id))return;active=id;tabs.get(id).unread=false;document.querySelectorAll('.stream').forEach(x=>x.classList.toggle('active',x.dataset.id===id));renderTabs();$('input').focus()}
function closeTab(id){if(ws&&ws.readyState===1)send({type:'close',terminalID:id});document.querySelector('.stream[data-id="'+id+'"]')?.remove();tabs.delete(id);order=order.filter(x=>x!==id);if(active===id)active=order[0]||null;if(!active)createTab();renderTabs()}
function ensureStream(id){let t=tabs.get(id);if(!t)return null;let el=document.querySelector('.stream[data-id="'+id+'"]');if(!el){el=document.createElement('div');el.className='stream '+(active===id?'active':'');el.dataset.id=id;el.innerHTML='<div class="terminal" tabindex="0" aria-label="Terminal output"></div><div class="quick"><button data-k="ctrlc">Ctrl-C</button><button data-k="esc">Esc</button><button data-k="tab">Tab</button><button data-k="up">↑</button><button data-k="down">↓</button><button data-k="left">←</button><button data-k="right">→</button><button data-k="ctrld">Ctrl-D</button><button data-k="clear">Clear</button></div>';let keys={ctrlc:'\u0003',esc:'\u001b',tab:'\t',up:'\u001b[A',down:'\u001b[B',left:'\u001b[D',right:'\u001b[C',ctrld:'\u0004',clear:'\u000c'};el.querySelectorAll('[data-k]').forEach(b=>b.onclick=()=>{sendInput(id,keys[b.dataset.k]||'')});$('chat').appendChild(el)}return el}
function appendOutput(id,text){let t=tabs.get(id);if(!t)return;t.out+=strip(text);if(t.out.length>200000)t.out=t.out.slice(-200000);let el=ensureStream(id),term=el.querySelector('.terminal');term.textContent=t.out;term.scrollTop=term.scrollHeight;if(active!==id){t.unread=true;renderTabs()}}
function sendInput(id,text){let bytes=new TextEncoder().encode(text),bin='';bytes.forEach(x=>bin+=String.fromCharCode(x));send({type:'input',terminalID:id,data:btoa(bin)})}
function send(o){if(ws&&ws.readyState===1){ws.send(JSON.stringify(o));return true}return false}
function reviewCommand(){let value=$('input').value.trim();if(!value||!active)return;$('input').value='';if(approved.has(value)){sendInput(active,value+'\n');appendCommand(value,'Approved');return}let card=document.createElement('div');card.className='command-card';card.innerHTML='<div class="eyebrow">⌁ Permission required</div><div class="approval">Awaiting approval</div><div class="command"><span class="prompt">$ </span>'+esc(value)+'<br><span style="color:#888">No output yet.</span></div><div class="approval-actions"><button>Allow</button><button class="secondary">Always allow here</button><button class="danger">Deny</button></div>';card.querySelectorAll('button')[0].onclick=()=>{sendInput(active,value+'\n');appendCommand(value,'Allowed');card.remove()};card.querySelectorAll('button')[1].onclick=()=>{approved.add(value);sendInput(active,value+'\n');appendCommand(value,'Always allowed here');card.remove()};card.querySelectorAll('button')[2].onclick=()=>{appendCommand(value,'Denied');card.remove()};$('chat').appendChild(card);card.scrollIntoView({block:'center',inline:'nearest'})}
function appendCommand(v,status){addMessage('<div class="meta">You · '+esc(status)+'</div><div class="body"><span style="color:#aaa">$ </span>'+esc(v)+'</div>')}
function showPair(){$('pair').classList.remove('hidden');$('code').focus()}
async function pair(){let code=$('code').value.trim(),r=await fetch('/api/pair',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code})});if(!r.ok){$('pair-error').textContent='That code is invalid or expired.';return}let x=await r.json();token=x.token;$('pair').classList.add('hidden');connect()}
function connect(){setState('Connecting');ws=new WebSocket(location.origin.replace('http','ws')+'/socket?token='+encodeURIComponent(token));ws.onopen=()=>{setState('Connected');if(order.length===0)createTab();else order.forEach(id=>{let t=tabs.get(id);if(t&&!t.opened)send({type:'open',terminalID:id,cols:Math.max(40,Math.floor(innerWidth/8)),rows:Math.max(12,Math.floor((innerHeight-250)/21)),startupCommand:t.startupCommand||null})});};ws.onclose=()=>{setState('Offline');tabs.forEach(t=>{t.opened=false;t.out='';t.unread=false});document.querySelectorAll('.stream').forEach(x=>x.remove());addMessage('<div class="badge">Browser session ended. Pair again to reconnect.</div>');};ws.onerror=()=>setState('Connection error');ws.onmessage=e=>{let x;try{x=JSON.parse(e.data)}catch{return}if(x.type==='hello'){sessionId=x.sessionID;setState('Connected')}else if(x.type==='ready'){let t=tabs.get(x.terminalID);if(t){t.opened=true;ensureStream(x.terminalID);addMessage('<div class="meta">System · terminal ready</div><div class="body">'+esc(t.title)+' is connected.</div>')}}else if(x.type==='output'){appendOutput(x.terminalID,new TextDecoder().decode(Uint8Array.from(atob(x.data),c=>c.charCodeAt(0))));}else if(x.type==='close'){let t=tabs.get(x.terminalID);if(t){t.opened=false;t.unread=active!==x.terminalID;renderTabs()}addMessage('<div class="meta">System · terminal closed</div><div class="body">'+esc(x.reason||'closed')+'</div>')}else if(x.type==='clipboard'){navigator.clipboard?.writeText(x.text||'');addMessage('<div class="meta">System · clipboard</div><div class="body">Host clipboard copied to this browser.</div>')}else if(x.type==='error'){addMessage('<div class="badge">'+esc(x.code)+'</div>')}}}
$('newtab').onclick=()=>createTab();$('send').onclick=reviewCommand;$('input').addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();reviewCommand()}});$('pair-button').onclick=pair;$('code').addEventListener('keydown',e=>{if(e.key==='Enter')pair()});$('paste').onclick=async()=>{let text=await navigator.clipboard?.readText();if(text&&active)sendInput(active,text)};$('copyhost').onclick=()=>{if(ws&&ws.readyState===1)send({type:'clipboardGet'})};$('more').onclick=()=>{let action=prompt('Attach a tmux or screen session, or launch an agent. Example: tmux attach -t work');if(action)createTab(action,'Session '+(order.length+1))};showPair();
</script>
<script>
// Harden the embedded browser client after the initial lightweight boot code:
// keep approvals and input tied to the tab that created them, preserve UTF-8
// across output chunks, expose both clipboard directions, and make reconnect
// and resize paths explicit.
let vampStatus = null;
let vampResizeFrame = 0;
const vampUpdateViewportInset = () => {
  const viewport = window.visualViewport;
  const layoutHeight = document.documentElement.clientHeight || window.innerHeight;
  const visibleBottom = viewport ? viewport.height + viewport.offsetTop : layoutHeight;
  const inset = Math.max(0, Math.round(layoutHeight - visibleBottom));
  document.documentElement.style.setProperty('--vamp-bottom-inset', inset + 'px');
  // iOS Safari may report the entire keyboard height here while the shell is
  // already sized to the visual viewport. Capping the composer lift avoids a
  // second full-height compensation that would strand the composer halfway
  // up the page instead of just above the keyboard.
  document.documentElement.style.setProperty('--vamp-composer-inset', Math.min(20, inset) + 'px');
  const visibleHeight = viewport ? Math.max(240, Math.round(viewport.height)) : layoutHeight;
  document.documentElement.style.setProperty('--vamp-visual-height', visibleHeight + 'px');
  const terminalHeight = Math.min(460, Math.max(160, Math.round(visibleHeight * 0.42)));
  document.documentElement.style.setProperty('--vamp-terminal-height', terminalHeight + 'px');
};
const vampRestoreShellPosition = () => {
  document.activeElement?.blur();
  const content = document.querySelector('.content');
  if (content) content.scrollTop = 0;
  window.scrollTo(0, 0);
  requestAnimationFrame(() => {
    if (content) content.scrollTop = 0;
    window.scrollTo(0, 0);
  });
};
const vampTerminalSize = (id = active) => {
  // The terminal screen is intentionally not rendered in Safari anymore. Use
  // a stable, readable PTY size instead of measuring a hidden DOM node. Safari
  // changes visualViewport.height when its URL bar or keyboard moves; using
  // that value here makes agent TUIs reflow while the user is only scrolling.
  const width = Math.max(320, innerWidth - 28);
  const height = 480;
  return {
    cols: Math.max(64, Math.min(120, Math.floor((width - 28) / 8.4))),
    rows: Math.max(24, Math.min(28, Math.floor((height - 28) / 20)))
  };
};

const vampScrollChatToLatest = () => {
  const content = document.querySelector('.content');
  if (!content) return;
  requestAnimationFrame(() => {
    // Keep the latest assistant/approval card visible while output streams.
    // This is deliberately an immediate scroll: a long command must not
    // queue dozens of overlapping smooth animations in Safari.
    content.scrollTop = content.scrollHeight;
  });
};

addMessage = (html, tabID = active) => {
  const element = document.createElement('article');
  element.className = 'message';
  if (tabID) element.dataset.tabId = tabID;
  element.innerHTML = html;
  $('chat').appendChild(element);
  vampScrollChatToLatest();
  return element;
};

const vampNormalizeChatOutput = (text, tab) => {
  let value = String(text || '')
    .replace(/\u001b\][\s\S]*?(?:\u0007|\u001b\\)/g, '')
    .replace(/\u001b(?:\[[0-?]*[ -\/]*[@-~]|[()][0-2A-Z0-9]|.)/g, '')
    .replace(/\u009b[0-?]*[ -\/]*[@-~]/g, '')
    .replace(/\r/g, '')
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '');
  const pending = String(tab?.pendingCommand || '').trim();
  const lines = value.split('\n').map((line) => line.trimEnd()).filter((line) => {
    const normalized = line.trim();
    if (!normalized) return false;
    if (/^(?:~|[$%❯>#]|~\s*[%$#❯>])\s*$/.test(normalized)) return false;
    if (pending && (normalized === pending || normalized === '$ ' + pending || normalized === '% ' + pending || normalized === '❯ ' + pending)) return false;
    if (pending && normalized.endsWith(pending) && /(?:^|[\s~\/])[%$#❯>]\s/.test(normalized)) return false;
    if (/^(?:~|\/[^ ]*|[\w.-]+@[\w.-]+).*[%$#❯>]\s*$/.test(normalized)) return false;
    return true;
  });
  return lines.join('\n').trim();
};

// PTYs echo input with cursor movement and may split that echo across several
// WebSocket frames. Normalising each raw frame independently can turn a clean
// command such as `date` into `ddate` or `eec\nho`. The browser terminal already
// applies carriage returns, backspaces, and ANSI cursor movement, so use its
// rendered screen to locate the command echo and expose only the response.
const vampRenderedCommandResponse = (tab) => {
  const pending = String(tab?.pendingCommand || '').trim();
  const rendered = tab?.terminal?.render?.() || '';
  if (!pending || !rendered) return { found: false, text: '' };
  const lines = rendered.split('\n');
  let commandIndex = -1;
  lines.forEach((line, index) => {
    const normalized = line.trim();
    if (!normalized) return;
    if (normalized === pending || normalized.endsWith(pending)) commandIndex = index;
  });
  if (commandIndex < 0) return { found: false, text: '' };
  return {
    found: true,
    text: vampNormalizeChatOutput(lines.slice(commandIndex + 1).join('\n'), { pendingCommand: null })
  };
};

const vampSetChatOutput = (id, text) => {
  const tab = tabs.get(id);
  if (!tab || !text) return;
  if (!tab.outputCard || !tab.outputCard.isConnected) {
    const card = document.createElement('article');
    card.className = 'message output-message';
    card.dataset.tabId = id;
    card.innerHTML = '<div class="meta"><span>Vamp · ' + esc(tab.title) + '</span><span class="live-label">Live</span></div><div class="body"></div>';
    $('chat').appendChild(card);
    tab.outputCard = card;
    tab.outputText = '';
  }
  const next = String(text).slice(-24000);
  if (tab.outputText === next) return;
  tab.outputText = next;
  tab.outputCard.querySelector('.body').textContent = next;
  if (id === active) vampScrollChatToLatest();
};

const vampAppendChatOutput = (id, text) => {
  const tab = tabs.get(id);
  if (!tab || !text) return;
  if (!tab.outputCard || !tab.outputCard.isConnected) {
    const card = document.createElement('article');
    card.className = 'message output-message';
    card.dataset.tabId = id;
    card.innerHTML = '<div class="meta"><span>Vamp · ' + esc(tab.title) + '</span><span class="live-label">Live</span></div><div class="body"></div>';
    $('chat').appendChild(card);
    tab.outputCard = card;
    tab.outputText = '';
  }
  tab.outputText = ((tab.outputText || '') + (tab.outputText ? '\n' : '') + text).slice(-24000);
  tab.outputCard.querySelector('.body').textContent = tab.outputText;
  if (id === active) vampScrollChatToLatest();
};

const vampMoreStyle = document.createElement('style');
vampMoreStyle.textContent = `
  .tab-dot.closed,.tab-dot.error,.tab-dot.offline { color: var(--danger); }
  .composer { box-sizing: border-box; width: calc(100% - 32px); min-height: 60px; height: 60px; padding: 8px; gap: 8px; }
  .composer input { box-sizing: border-box; height: 44px; min-height: 44px; padding: 8px 10px; }
  .composer > button { box-sizing: border-box; flex: 0 0 44px; width: 44px; height: 44px; min-height: 44px; padding: 0; }
  .clipboard-trigger { flex: 0 0 auto !important; min-width: 44px; height: 44px !important; }
  .more-card { max-height: min(720px, calc(100dvh - 40px)); overflow: auto; }
  .more-kicker { color: #999; font-size: 12px; text-transform: uppercase; letter-spacing: .08em; }
  .more-actions { display: grid; gap: 8px; margin: 14px 0; }
  .more-actions button, .provider-grid button { display: flex; align-items: center; gap: 10px; width: 100%; margin: 0; background: rgba(255,255,255,.08); color: #eee; text-align: left; font-weight: 600; }
  .more-actions button:hover, .more-actions button:focus-visible, .provider-grid button:hover, .provider-grid button:focus-visible { background: rgba(255,255,255,.14); }
  .more-actions button.secondary { background: rgba(255,255,255,.04); color: #ccc; }
  .more-command { display: block; margin-top: 12px; color: #aaa; font-size: 13px; }
  .more-command input { margin-top: 7px; letter-spacing: 0; text-align: left; }
  .provider-title { color: #aaa; font-size: 13px; margin: 18px 0 8px; }
  .provider-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
  .provider-grid button { min-width: 0; padding: 9px 10px; font-size: 13px; }
  .provider-mark { display: grid; place-items: center; flex: 0 0 28px; width: 28px; height: 28px; border-radius: 9px; background: color-mix(in srgb, var(--provider) 18%, transparent); color: var(--provider); border: 1px solid color-mix(in srgb, var(--provider) 45%, transparent); font-weight: 750; }
  .more-footer { display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; }
  .more-footer button { margin: 0; }
  .more-footer .secondary { background: rgba(255,255,255,.10); color: #eee; }
  [hidden], .hidden { display: none !important; }
  html, body { height: 100%; overflow: hidden; }
  body { overscroll-behavior-y: none; }
  .shell { position: fixed; inset: 0; width: 100%; height: var(--vamp-visual-height, 100svh); min-height: 0; padding-bottom: 0; overflow: hidden; }
  .content { min-height: 0; overflow: auto; overscroll-behavior: contain; }
  .chat { min-height: 100%; padding-bottom: 24px; }
  /* Safari is a task-chat surface. The PTY emulator remains mounted in
     JavaScript for ANSI/cursor parsing, but its raw screen and desktop-style
     quick-key rail must never compete with the conversation or composer. */
  .stream, .terminal, .quick { display: none !important; }
  .message { max-width: 820px; }
  .message.user-message { margin-top: 18px; }
  .message.output-message { margin-top: 8px; }
  .message.output-message .meta { display: flex; align-items: center; gap: 8px; }
  .message.output-message .body { padding-left: 0; color: #f1f1f1; }
  .message.output-message .live-label { color: var(--good); font-size: 11px; }
  .message.output-message .live-label::before { content: '●'; margin-right: 4px; }
  .message.system-message .body { color: #ddd; }
  .command-card { margin-bottom: 18px; }
  .approval-actions { display: grid; gap: 8px; }
  .approval-choice { display: flex; align-items: center; gap: 10px; width: 100%; min-height: 48px; padding: 9px 12px; border: 1px solid rgba(255,255,255,.10); border-radius: 12px; background: rgba(255,255,255,.06); color: #eee; text-align: left; }
  .approval-choice.selected { border-color: rgba(255,255,255,.34); background: rgba(255,255,255,.14); }
  .approval-choice .choice-number { color: #aaa; flex: 0 0 20px; }
  .approval-choice strong { display: block; }
  .approval-choice small { display: block; margin-top: 2px; color: #999; font-size: 12px; }
  .approval-footer { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-top: 12px; }
  .approval-footer .hint { margin: 0; color: #999; font-size: 12px; line-height: 1.35; }
  .approval-footer .confirm { flex: 0 0 auto; min-height: 44px; border-radius: 11px; padding: 0 16px; background: #f5f5f5; color: #111; font-weight: 700; }
  .composer { position: fixed; left: 14px; right: 14px; bottom: calc(max(12px, env(safe-area-inset-bottom)) + var(--vamp-bottom-inset, 0px)); width: min(calc(100% - 28px), 952px); margin: 0 auto; }
  .modal { z-index: 20; height: var(--vamp-visual-height, 100svh); bottom: auto; }
  .modal-card { max-height: calc(var(--vamp-visual-height, 100svh) - 32px); overflow: auto; }
  .dashboard, .dashboard-heading, .dashboard-heading > div, .host-card, .session-card, .session-card-top { min-width: 0; max-width: 100%; }
  .dashboard { width: 100%; min-height: 100%; padding: 24px 0 40px; overflow-x: hidden; }
  .dashboard-heading { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; margin-bottom: 20px; }
  .dashboard-kicker { color: #999; font-size: 11px; font-weight: 700; letter-spacing: .12em; }
  .dashboard h1, .dashboard h2, .dashboard p { margin: 0; }
  .dashboard h1 { margin-top: 6px; font-size: clamp(26px, 7vw, 36px); letter-spacing: -.03em; }
  .dashboard-heading p { max-width: 560px; margin-top: 8px; color: #aaa; line-height: 1.5; overflow-wrap: anywhere; word-break: break-word; }
  .dashboard-open { min-height: 44px; padding: 0 14px; border: 1px solid rgba(255,255,255,.18); border-radius: 12px; background: rgba(255,255,255,.9); color: #111; font-weight: 700; white-space: nowrap; }
  .host-card, .session-card { border: 1px solid rgba(255,255,255,.16); border-radius: 18px; background: linear-gradient(145deg, rgba(61,61,61,.72), rgba(28,28,28,.72)); box-shadow: 0 18px 46px rgba(0,0,0,.20), inset 0 1px 0 rgba(255,255,255,.08); backdrop-filter: blur(18px); }
  .host-card { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 18px; }
  .host-card h2 { margin-top: 5px; font-size: 19px; }
  .host-card p { margin-top: 7px; color: #aaa; font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }
  .host-state { color: var(--good); font-size: 18px; }
  .session-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 26px 0 10px; }
  .session-heading h2 { font-size: 15px; }
  .session-heading span { color: #999; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
  .session-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
  .session-card { min-height: 138px; display: flex; flex-direction: column; justify-content: space-between; padding: 15px; }
  .session-card-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }
  .session-card-title { display: flex; align-items: center; gap: 8px; min-width: 0; font-weight: 700; }
  .session-card-title span:last-child { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .session-card-dot { width: 9px; height: 9px; flex: 0 0 auto; border-radius: 50%; background: #999; }
  .session-card-dot.open { background: var(--good); }
  .session-card-dot.opening { background: var(--warn); }
  .session-card-dot.closed, .session-card-dot.error, .session-card-dot.offline { background: var(--danger); }
  .session-card-meta { margin-top: 10px; color: #aaa; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; line-height: 1.45; }
  .session-card-action { align-self: flex-start; min-height: 36px; margin-top: 14px; padding: 0 11px; border: 1px solid rgba(255,255,255,.16); border-radius: 10px; background: rgba(255,255,255,.09); color: #eee; font-size: 13px; font-weight: 650; }
  .dashboard-empty { grid-column: 1 / -1; padding: 34px 18px; border: 1px dashed rgba(255,255,255,.18); border-radius: 16px; color: #999; text-align: center; }
  @media (min-width: 720px) { .composer { width: min(calc(100% - 56px), 952px); } }
  @media (max-width: 520px) {
    .shell { padding-top: max(44px, env(safe-area-inset-top)); }
    .composer { left: 0; right: 0; width: 100%; min-height: 60px; height: 60px; padding: 8px; border-radius: 14px; }
    .composer > button { flex-basis: 44px; width: 44px; }
    .approval-footer { align-items: flex-end; }
    .approval-footer .hint { max-width: 58%; }
    .provider-grid { grid-template-columns: 1fr; }
    .dashboard-heading { display: block; }
    .dashboard-heading p { max-width: 100%; }
    .dashboard-open { width: 100%; margin-top: 16px; }
    .session-grid { grid-template-columns: 1fr; }
  }
`;
document.head.appendChild(vampMoreStyle);

// Swift's UUID Codable representation is uppercase while crypto.randomUUID()
// returns lowercase. IDs are case-insensitive on the wire, but Map keys are
// not; normalize host events before routing them to the tab that opened them.
const vampNewUUID = () => {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') {
    return globalThis.crypto.randomUUID();
  }
  const bytes = new Uint8Array(16);
  if (globalThis.crypto && typeof globalThis.crypto.getRandomValues === 'function') {
    globalThis.crypto.getRandomValues(bytes);
  } else {
    for (let index = 0; index < bytes.length; index += 1) bytes[index] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('');
  return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
};
const vampTerminalKey = (value) => String(value || '').toLowerCase();

// A small, dependency-free terminal emulator for Safari. Rendering PTY bytes
// with `textContent` is not enough: carriage returns, cursor movement, erase
// commands, and alternate-screen TUIs are what make agents such as Grok and
// Claude look like joined text with replacement boxes. This keeps a bounded
// screen + scrollback buffer and handles the control sequences used by common
// shells and coding agents while preserving UTF-8 text.
class VampBrowserTerminal {
  constructor(cols = 80, rows = 24) {
    this.cols = Math.max(1, cols); this.rows = Math.max(1, rows);
    this.reset();
  }
  blank() { return Array(this.cols).fill(' '); }
  reset() {
    this.scrollback = []; this.screen = Array.from({length: this.rows}, () => this.blank());
    this.row = 0; this.col = 0; this.saved = {row: 0, col: 0}; this.alt = null; this.pending = '';
  }
  resize(cols, rows) {
    cols = Math.max(1, cols); rows = Math.max(1, rows);
    if (cols === this.cols && rows === this.rows) return;
    const old = this.screen.map((line) => line.join(''));
    this.cols = cols; this.rows = rows;
    this.screen = Array.from({length: rows}, () => this.blank());
    old.slice(-rows).forEach((line, index) => {
      [...line.slice(0, cols)].forEach((character, column) => { this.screen[index][column] = character; });
    });
    this.row = Math.min(this.row, rows - 1); this.col = Math.min(this.col, cols - 1);
  }
  scroll() {
    this.scrollback.push(this.screen.shift().join('').replace(/\s+$/, ''));
    if (this.scrollback.length > 2000) this.scrollback.splice(0, this.scrollback.length - 2000);
    this.screen.push(this.blank()); this.row = this.rows - 1;
  }
  lineFeed() { if (this.row >= this.rows - 1) this.scroll(); else this.row += 1; }
  carriageReturn() { this.col = 0; }
  put(character) {
    if (this.col >= this.cols) { this.col = 0; this.lineFeed(); }
    this.screen[this.row][this.col] = character; this.col += 1;
  }
  eraseLine(mode = 0) {
    const start = mode === 1 ? 0 : this.col;
    const end = mode === 1 ? this.col : this.cols - 1;
    if (mode === 2) { for (let index = 0; index < this.cols; index += 1) this.screen[this.row][index] = ' '; return; }
    for (let index = start; index <= end; index += 1) this.screen[this.row][index] = ' ';
  }
  eraseDisplay(mode = 0) {
    if (mode === 2 || mode === 3) {
      this.screen = Array.from({length: this.rows}, () => this.blank()); this.row = 0; this.col = 0;
      if (mode === 3) this.scrollback = [];
      return;
    }
    if (mode === 0) { this.eraseLine(0); for (let index = this.row + 1; index < this.rows; index += 1) this.screen[index] = this.blank(); }
    if (mode === 1) { this.eraseLine(1); for (let index = 0; index < this.row; index += 1) this.screen[index] = this.blank(); }
  }
  params(raw) {
    const privateMode = raw.startsWith('?');
    const value = privateMode ? raw.slice(1) : raw;
    const values = value === '' ? [] : value.split(';').map((entry) => parseInt(entry, 10) || 0);
    return { privateMode, values };
  }
  csi(raw, final) {
    const parsed = this.params(raw); const values = parsed.values; const first = values[0] || 1;
    if (parsed.privateMode && (final === 'h' || final === 'l')) {
      if (values.includes(1049) || values.includes(47)) {
        if (final === 'h' && !this.alt) {
          this.alt = {screen: this.screen, scrollback: this.scrollback, row: this.row, col: this.col};
          this.scrollback = []; this.screen = Array.from({length: this.rows}, () => this.blank()); this.row = 0; this.col = 0;
        } else if (final === 'l' && this.alt) {
          const saved = this.alt; this.screen = saved.screen; this.scrollback = saved.scrollback; this.row = saved.row; this.col = saved.col; this.alt = null;
        }
      }
      return;
    }
    switch (final) {
      case 'A': this.row = Math.max(0, this.row - first); break;
      case 'B': case 'e': this.row = Math.min(this.rows - 1, this.row + first); break;
      case 'C': case 'a': this.col = Math.min(this.cols - 1, this.col + first); break;
      case 'D': this.col = Math.max(0, this.col - first); break;
      case 'E': this.row = Math.min(this.rows - 1, this.row + first); this.col = 0; break;
      case 'F': this.row = Math.max(0, this.row - first); this.col = 0; break;
      case 'G': case '`': this.col = Math.max(0, Math.min(this.cols - 1, first - 1)); break;
      case 'd': this.row = Math.max(0, Math.min(this.rows - 1, first - 1)); break;
      case 'H': case 'f': {
        const row = Math.max(1, values[0] || 1); const col = Math.max(1, values[1] || 1);
        this.row = Math.min(this.rows - 1, row - 1); this.col = Math.min(this.cols - 1, col - 1); break;
      }
      case 'J': this.eraseDisplay(values[0] || 0); break;
      case 'K': this.eraseLine(values[0] || 0); break;
      case 'P': {
        const count = Math.min(first, this.cols - this.col);
        this.screen[this.row].splice(this.col, count); this.screen[this.row].push(...Array(count).fill(' ')); break;
      }
      case '@': {
        const count = Math.min(first, this.cols - this.col);
        this.screen[this.row].splice(this.col, 0, ...Array(count).fill(' ')); this.screen[this.row].splice(this.cols); break;
      }
      case 's': this.saved = {row: this.row, col: this.col}; break;
      case 'u': this.row = Math.min(this.rows - 1, this.saved.row); this.col = Math.min(this.cols - 1, this.saved.col); break;
      case 'L': {
        const count = Math.min(first, this.rows - this.row);
        for (let index = 0; index < count; index += 1) { this.screen.splice(this.row, 0, this.blank()); this.screen.pop(); } break;
      }
      case 'M': {
        const count = Math.min(first, this.rows - this.row);
        for (let index = 0; index < count; index += 1) { this.screen.splice(this.row, 1); this.screen.push(this.blank()); } break;
      }
      case 'h': case 'l': case 'm': case 'n': case 'r': case 't': case 'c': break;
      default: break;
    }
  }
  feed(text) {
    const input = (this.pending || '') + text; this.pending = '';
    for (let index = 0; index < input.length; index += 1) {
      const code = input.charCodeAt(index); const character = input[index];
      if (character === '\u001b' || character === '\u009b') {
        if (index + 1 >= input.length) { this.pending = input.slice(index); break; }
        const next = character === '\u009b' ? null : input[index + 1];
        if (character === '\u009b' || next === '[') {
          const start = character === '\u009b' ? index + 1 : index + 2;
          let end = start; while (end < input.length && !(/[\x40-\x7e]/.test(input[end]))) end += 1;
          if (end < input.length) { this.csi(input.slice(start, end), input[end]); index = end; continue; }
          this.pending = input.slice(index); break;
        }
        if (next === ']') {
          let end = index + 2; while (end < input.length && input.charCodeAt(end) !== 7 && !(input[end] === '\u001b' && input[end + 1] === '\\')) end += 1;
          if (end >= input.length) { this.pending = input.slice(index); break; }
          index = input[end] === '\u001b' ? end + 1 : end; continue;
        }
        if (next === '7') this.saved = {row: this.row, col: this.col};
        else if (next === '8') { this.row = this.saved.row; this.col = this.saved.col; }
        else if (next === 'D') this.lineFeed();
        else if (next === 'M') { if (this.row > 0) this.row -= 1; }
        else if (next === 'E') { this.carriageReturn(); this.lineFeed(); }
        else if (next === 'c') this.reset();
        index += 1; continue;
      }
      if (character === '\r') { this.carriageReturn(); continue; }
      if (character === '\n') { this.lineFeed(); continue; }
      if (character === '\b') { this.col = Math.max(0, this.col - 1); continue; }
      if (character === '\t') { this.col = Math.min(this.cols - 1, this.col + (8 - (this.col % 8))); continue; }
      if (code < 0x20 || code === 0x7f) continue;
      this.put(character);
    }
  }
  clearScreen() { this.screen = Array.from({length: this.rows}, () => this.blank()); this.row = 0; this.col = 0; }
  render() { return this.scrollback.concat(this.screen.map((line) => line.join('').replace(/\s+$/, ''))).join('\n'); }
}

const vampNextTerminalTitle = () => {
  const titles = new Set([...tabs.values()].map((tab) => tab.title));
  let number = 1;
  while (titles.has('Terminal ' + number)) number += 1;
  return 'Terminal ' + number;
};

const vampOpenTerminal = (id) => {
  const tab = tabs.get(id);
  if (!tab || !ws || ws.readyState !== WebSocket.OPEN) return false;
  tab.state = 'opening';
  tab.readyNotified = false;
  renderTabs();
  ensureStream(id);
  const size = vampTerminalSize(id);
  tab.lastSize = size;
  tab.terminal ||= new VampBrowserTerminal(size.cols, size.rows);
  tab.terminal.resize(size.cols, size.rows);
  const sent = send({
    type: 'open',
    terminalID: id,
    cols: size.cols,
    rows: size.rows,
    startupCommand: tab.startupCommand || null
  });
  if (!sent) {
    tab.state = 'error';
    addMessage('<div class="badge">The host connection is not ready. Reconnect and retry this terminal.</div>', id);
  }
  return sent;
};

const vampResizeTerminal = (id) => {
  const tab = tabs.get(id);
  if (!tab || !tab.opened || !ws || ws.readyState !== WebSocket.OPEN || id !== active) return;
  const size = vampTerminalSize(id);
  if (tab.lastSize && tab.lastSize.cols === size.cols && tab.lastSize.rows === size.rows) return;
  tab.lastSize = size;
  tab.terminal?.resize(size.cols, size.rows);
  const element = ensureStream(id);
  const terminal = element?.querySelector('.terminal');
  if (terminal && tab.terminal) terminal.textContent = tab.terminal.render();
  send({ type: 'resize', terminalID: id, cols: size.cols, rows: size.rows });
};

renderTabs = () => {
  const navigation = $('tabs');
  navigation.querySelectorAll('.tab').forEach((element) => element.remove());
  order.forEach((id) => {
    const tab = tabs.get(id);
    if (!tab) return;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'tab ' + (id === active ? 'active' : '');
    button.dataset.id = id;
    button.setAttribute('aria-pressed', String(id === active));
    const stateClass = tab.opened ? 'open' : (tab.state || 'opening');
    button.innerHTML = '<span class="tab-dot ' + stateClass + '" aria-hidden="true">●</span>' +
      '<span>' + esc(tab.title) + '</span>' +
      (tab.unread ? '<span class="tab-dot" aria-label="Unread output">•</span>' : '') +
      '<span class="close" aria-label="Close">×</span>';
    button.onclick = (event) => {
      if (event.target.classList.contains('close')) closeTab(id);
      else selectTab(id);
    };
    button.oncontextmenu = (event) => {
      event.preventDefault();
      const title = prompt('Rename terminal', tab.title);
      if (title && title.trim()) {
        tab.title = title.trim().slice(0, 48);
        renderTabs();
      }
    };
    navigation.insertBefore(button, $('newtab'));
  });
  const selected = navigation.querySelector('.tab.active');
  if (selected) {
    requestAnimationFrame(() => {
      const margin = 12;
      const left = selected.offsetLeft;
      const right = left + selected.offsetWidth;
      const newTab = $('newtab');
      const focusRight = selected.nextElementSibling === newTab
        ? Math.max(right, newTab.offsetLeft + newTab.offsetWidth)
        : right;
      const visibleLeft = navigation.scrollLeft;
      const visibleRight = visibleLeft + navigation.clientWidth;
      if (focusRight > visibleRight - margin) {
        navigation.scrollLeft = Math.min(
          navigation.scrollWidth - navigation.clientWidth,
          focusRight - navigation.clientWidth + margin
        );
      } else if (left < visibleLeft + margin) {
        navigation.scrollLeft = Math.max(0, left - margin);
      }
    });
  }
  renderDashboard();
};

function renderDashboard() {
  const grid = $('session-grid');
  const count = $('dashboard-count');
  if (!grid || !count) return;
  count.textContent = order.length + ' / 8';
  const status = vampStatus;
  // The WebSocket is the authoritative signal once a browser is paired. The
  // status endpoint can still contain the previous pre-pair result while its
  // refresh is in flight, which used to make a live dashboard look offline.
  const socketReady = Boolean(ws && ws.readyState === WebSocket.OPEN);
  const hostReady = Boolean(status?.running) || socketReady;
  const hostDetail = status?.tailscaleHost
    ? 'Tailscale · ' + status.tailscaleHost + ':' + (status.port || 9475)
    : hostReady ? 'Connected to Vamp Host' : 'Host control is offline';
  $('dashboard-host-detail').textContent = hostDetail;
  const state = $('dashboard-host-state');
  state.textContent = hostReady ? '●' : '○';
  state.style.color = hostReady ? 'var(--good)' : 'var(--danger)';
  grid.innerHTML = '';
  if (order.length === 0) {
    grid.innerHTML = '<div class="dashboard-empty">No shell tabs yet. Open task chat to start a session.</div>';
    return;
  }
  order.forEach((id) => {
    const tab = tabs.get(id); if (!tab) return;
    const card = document.createElement('article'); card.className = 'session-card';
    const stateClass = tab.opened ? 'open' : (tab.state || 'opening');
    const stateText = tab.opened ? 'Connected' : (tab.state === 'opening' ? 'Opening' : (tab.state || 'Closed'));
    card.innerHTML = '<div class="session-card-top"><div class="session-card-title"><span class="session-card-dot ' + stateClass + '"></span><span>' + esc(tab.title) + '</span></div>' +
      (tab.unread ? '<span class="tab-dot open" aria-label="Unread output">●</span>' : '') +
      '</div><div class="session-card-meta">' + esc(stateText) + '<br>Independent PTY session</div>';
    const action = document.createElement('button'); action.type = 'button'; action.className = 'session-card-action'; action.textContent = id === active ? 'In task chat' : 'Open session';
    action.onclick = () => { selectTab(id); vampToggleDashboard(false); };
    card.append(action); grid.append(card);
  });
}

function vampToggleDashboard(force) {
  const dashboard = $('dashboard');
  const show = typeof force === 'boolean' ? force : dashboard.classList.contains('hidden');
  dashboard.classList.toggle('hidden', !show);
  $('chat').classList.toggle('hidden', show);
  $('tabs').classList.toggle('hidden', show);
  $('composer').classList.toggle('hidden', show);
  $('page-title').textContent = show ? 'Sessions' : 'Task chat';
  $('back').textContent = show ? '×' : '‹';
  $('back').setAttribute('aria-label', show ? 'Close sessions dashboard' : 'Open sessions dashboard');
  $('back').setAttribute('title', show ? 'Close sessions dashboard' : 'Open sessions dashboard');
  if (show) renderDashboard();
  else {
    vampRestoreShellPosition();
    if (active) { selectTab(active); requestAnimationFrame(() => vampResizeTerminal(active)); }
  }
}

$('dashboard-open').onclick = () => vampToggleDashboard(false);

createTab = (startup = null, title = null) => {
  if (order.length >= 8) {
    addMessage('<div class="badge">Terminal capacity reached (8 tabs).</div>');
    return null;
  }
  const id = vampNewUUID();
  const tab = {
    id,
    title: title || vampNextTerminalTitle(),
    startupCommand: startup,
    out: '',
    outputCard: null,
    outputText: '',
    pendingCommand: null,
    pendingInput: null,
    unread: false,
    opened: false,
    readyNotified: false,
    followOutput: false,
    startupSeen: false,
    state: 'opening',
    decoder: new TextDecoder(),
    approvals: new Set(),
    terminal: new VampBrowserTerminal()
  };
  tabs.set(id, tab);
  order.push(id);
  active = id;
  renderTabs();
  ensureStream(id);
  document.querySelectorAll('.stream').forEach((element) => {
    element.classList.toggle('active', element.dataset.id === id);
  });
  if (ws && ws.readyState === WebSocket.OPEN) vampOpenTerminal(id);
  else showPair();
  return id;
};

selectTab = (id) => {
  const tab = tabs.get(id);
  if (!tab) return;
  active = id;
  tab.unread = false;
  if (tab.opened) ensureStream(id);
  document.querySelectorAll('.stream').forEach((element) => {
    element.classList.toggle('active', element.dataset.id === id);
  });
  renderTabs();
  requestAnimationFrame(() => vampResizeTerminal(id));
  vampScrollChatToLatest();
};

closeTab = (id) => {
  const tab = tabs.get(id);
  if (!tab) return;
  if (tab.opened && !window.confirm('Close ' + tab.title + '? This ends the shell unless it is inside tmux or screen.')) return;
  if (tab.opened && ws && ws.readyState === WebSocket.OPEN) {
    send({ type: 'close', terminalID: id });
  }
  document.querySelector('.stream[data-id="' + id + '"]')?.remove();
  tabs.delete(id);
  order = order.filter((value) => value !== id);
  if (active === id) active = order[0] || null;
  if (!active) createTab();
  if (active) selectTab(active);
  renderTabs();
};

ensureStream = (id) => {
  const tab = tabs.get(id);
  if (!tab) return null;
  let element = document.querySelector('.stream[data-id="' + id + '"]');
  if (!element) {
    element = document.createElement('div');
    element.className = 'stream';
    element.dataset.id = id;
    element.setAttribute('aria-hidden', 'true');
    $('chat').appendChild(element);
  }
  return element;
};

appendOutput = (id, text) => {
  const tab = tabs.get(id);
  if (!tab) return;
  tab.decoder ||= new TextDecoder();
  tab.approvals ||= new Set();
  tab.terminal ||= new VampBrowserTerminal();
  tab.terminal.feed(text);
  tab.out = tab.terminal.render();
  const commandResponse = vampRenderedCommandResponse(tab);
  if (commandResponse.found) {
    tab.pendingCommand = null;
    if (commandResponse.text) vampSetChatOutput(id, commandResponse.text);
    if (active !== id) {
      tab.unread = true;
      renderTabs();
    }
    return;
  }
  if (tab.pendingCommand) {
    // Hold back PTY echo fragments until the terminal emulator has a complete
    // command line. This keeps the task stream readable while bytes arrive.
    if (active !== id) {
      tab.unread = true;
      renderTabs();
    }
    return;
  }
  const visibleText = vampNormalizeChatOutput(text, tab);
  if (visibleText) {
    vampAppendChatOutput(id, visibleText);
    // Ignore only the echoed command. Subsequent output belongs to the
    // response card even when it happens to contain the same prompt symbols.
    tab.pendingCommand = null;
  }
  if (active !== id) {
    tab.unread = true;
    renderTabs();
  }
};

const vampAppendOutputChunk = (id, encoded) => {
  const tab = tabs.get(id);
  if (!tab) return;
  tab.decoder ||= new TextDecoder();
  const bytes = Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
  appendOutput(id, tab.decoder.decode(bytes, { stream: true }));
};

sendInput = (id, text) => {
  const tab = tabs.get(id);
  if (!tab || !ws || ws.readyState !== WebSocket.OPEN || tab.state === 'error' || tab.state === 'closed' || tab.state === 'offline') return false;
  const bytes = new TextEncoder().encode(text);
  if (!tab.opened) {
    const queued = tab.pendingInput || '';
    if (new TextEncoder().encode(queued).length + bytes.length > 16 * 1024) return false;
    tab.pendingInput = queued + text;
    return true;
  }
  let binary = '';
  bytes.forEach((value) => { binary += String.fromCharCode(value); });
  return send({ type: 'input', terminalID: id, data: btoa(binary) });
};

appendCommand = (value, status, tabID = active) => {
  const tab = tabs.get(tabID);
  if (tab) {
    tab.pendingCommand = value;
    tab.outputCard = null;
    tab.outputText = '';
  }
  const title = tab?.title || 'Terminal';
  const element = addMessage('<div class="meta">You · ' + esc(title) + ' · ' + esc(status) +
    '</div><div class="body"><span style="color:#aaa">$ </span>' + esc(value) + '</div>', tabID);
  element.classList.add('user-message');
  return element;
};

reviewCommand = () => {
  const value = $('input').value.trim();
  const tabID = active;
  const tab = tabs.get(tabID);
  if (!value || !tabID) return;
  if (!tab || !ws || ws.readyState !== WebSocket.OPEN) {
    addMessage('<div class="badge">This terminal is still opening. Your command is still in the composer.</div>', tabID);
    return;
  }
  if (!tab.opened) {
    if (tab.pendingInput) {
      addMessage('<div class="badge">One command is already queued. It will run when this terminal is ready.</div>', tabID);
      return;
    }
    tab.pendingInput = value + '\n';
    $('input').value = '';
    appendCommand(value, 'Queued · starting', tabID);
    vampScrollChatToLatest();
    return;
  }
  tab.approvals ||= new Set();
  if (tab.approvals.has(value)) {
    if (sendInput(tabID, value + '\n')) {
      $('input').value = '';
      appendCommand(value, 'Running', tabID);
    } else {
      addMessage('<div class="badge">The host connection is not ready. Try again; your command is still in the composer.</div>', tabID);
    }
    return;
  }
  const card = document.createElement('div');
  card.className = 'command-card';
  card.innerHTML =
    '<div class="eyebrow">⌁ Permission required</div>' +
    '<div class="approval">Awaiting approval · ' + esc(tab.title) + '</div>' +
    '<div class="command"><span class="prompt">$ </span>' + esc(value) +
    '<br><span style="color:#888">No output yet.</span></div>' +
    '<div class="approval-actions">' +
    '<button type="button" class="approval-choice selected" data-choice="once"><span class="choice-number">1.</span><span><strong>Allow</strong><small>Allow only this time</small></span></button>' +
    '<button type="button" class="approval-choice" data-choice="always"><span class="choice-number">2.</span><span><strong>Always allow</strong><small>Do not ask again for this command</small></span></button>' +
    '<button type="button" class="approval-choice" data-choice="deny"><span class="choice-number">3.</span><span><strong>Deny</strong><small>Reject it for now</small></span></button>' +
    '</div><div class="approval-footer"><p class="hint">Choose an action, then press Confirm.</p><button type="button" class="confirm">Confirm</button></div>';
  let choice = 'once';
  card.querySelectorAll('[data-choice]').forEach((button) => {
    button.onclick = () => {
      choice = button.dataset.choice || 'once';
      card.querySelectorAll('[data-choice]').forEach((candidate) => candidate.classList.toggle('selected', candidate === button));
    };
  });
  card.querySelector('.confirm').onclick = () => {
    card.remove();
    if (choice === 'deny') {
      $('input').value = '';
      appendCommand(value, 'Denied', tabID);
      return;
    }
    const current = tabs.get(tabID);
    if (choice === 'always' && current) {
      current.approvals ||= new Set();
      current.approvals.add(value);
    }
    if (sendInput(tabID, value + '\n')) {
      $('input').value = '';
      appendCommand(value, choice === 'always' ? 'Always allowed · running' : 'Running', tabID);
    } else {
      if (choice === 'always' && current) current.approvals.delete(value);
      $('input').value = value;
      addMessage('<div class="badge">The host connection closed before the command was sent. Try again.</div>', tabID);
    }
  };
  $('chat').appendChild(card);
  $('input').value = '';
  vampScrollChatToLatest();
};

showPair = () => {
  $('pair').classList.remove('hidden');
  $('composer').classList.add('hidden');
  $('pair-error').textContent = '';
  if (!$('pair-button').disabled) $('code').focus();
};

const vampRefreshStatus = async () => {
  try {
    const response = await fetch('/api/status', { cache: 'no-store' });
    const status = await response.json();
    vampStatus = status;
    if (!status.terminalModeEnabled) {
      setState('Disabled');
      $('empty').textContent = 'Turn on Terminal Mode in Vamp Host before pairing this browser.';
      $('pair-error').textContent = 'Terminal Mode is disabled on the Mac.';
      $('pair-button').disabled = true;
    } else {
      $('pair-button').disabled = false;
      if (!ws || ws.readyState !== WebSocket.OPEN) setState('Pairing');
      $('empty').textContent = 'Pair this browser to start a terminal task.';
    }
    renderDashboard();
  } catch (_) {
    vampStatus = { running: false };
    setState('Offline');
    $('pair-error').textContent = 'Vamp Host is not reachable.';
    renderDashboard();
  }
};

const vampNormalizePairingCode = (raw) => {
  const value = String(raw || '').normalize('NFKC');
  let digits = '';
  for (const character of Array.from(value)) {
    if (/\s/.test(character) || character === '-' || character === '·') continue;
    if (/^[0-9]$/.test(character)) {
      digits += character;
      continue;
    }
    const codePoint = character.codePointAt(0);
    if (codePoint >= 0x660 && codePoint <= 0x669) digits += String(codePoint - 0x660);
    else if (codePoint >= 0x6f0 && codePoint <= 0x6f9) digits += String(codePoint - 0x6f0);
    else return '';
  }
  return digits.length === 6 ? digits : '';
};

pair = async () => {
  const code = vampNormalizePairingCode($('code').value);
  if (!code) {
    $('pair-error').textContent = 'Enter the six-digit code from Vamp Host.';
    return;
  }
  $('code').value = code;
  const button = $('pair-button');
  button.disabled = true;
  try {
    const response = await fetch('/api/pair', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code })
    });
    if (!response.ok) {
      if (response.status === 403) {
        $('pair-error').textContent = 'Terminal Mode is disabled on the Mac.';
      } else if (response.status === 409) {
        $('pair-error').textContent = 'Another browser is already connected to this host.';
      } else {
        $('pair-error').textContent = 'That code is invalid or expired.';
      }
      return;
    }
    const result = await response.json();
    token = result.token;
    $('pair').classList.add('hidden');
    $('composer').classList.remove('hidden');
    vampRestoreShellPosition();
    connect();
  } catch (_) {
    $('pair-error').textContent = 'Could not reach Vamp Host.';
  } finally {
    button.disabled = false;
  }
};

connect = () => {
  if (!token) return;
  setState('Connecting');
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const connection = new WebSocket(
    protocol + '//' + location.host + '/socket?token=' + encodeURIComponent(token)
  );
  ws = connection;
  connection.onopen = () => {
    setState('Connected');
    // A reconnect can follow a temporarily unavailable browser socket. Do
    // not leave that transient notice above the fresh task stream once the
    // new session is actually live.
    document.querySelectorAll('.message').forEach((element) => {
      if (element.textContent?.trim() === 'Browser session ended. Pair again to reconnect.') element.remove();
    });
    // A reconnect starts a fresh PTY workspace. Remove cards from the prior
    // socket so ready/output history cannot be mistaken for live state.
    chat.querySelectorAll('[data-tab-id], .explore-row[data-tab-id]').forEach((element) => element.remove());
    tabs.forEach((tab) => {
      tab.readyNotified = false;
      tab.outputCard = null;
      tab.outputText = '';
      tab.pendingCommand = null;
      tab.pendingInput = null;
      tab.commandCount = 0;
      tab.followOutput = false;
      tab.startupSeen = false;
    });
    // Refresh the host card after pairing/reconnect so the dashboard reflects
    // the same live host that accepted this WebSocket.
    void vampRefreshStatus();
    renderDashboard();
    $('empty').hidden = true;
    if (order.length === 0) createTab();
    else order.forEach((id) => {
      const tab = tabs.get(id);
      if (tab && !tab.opened) vampOpenTerminal(id);
    });
  };
  connection.onclose = () => {
    if (ws !== connection) return;
    ws = null;
    token = null;
    setState('Offline');
    $('empty').hidden = false;
    $('empty').textContent = 'Pair this browser to start a terminal task.';
    tabs.forEach((tab) => {
      tab.opened = false;
      tab.state = 'offline';
      tab.out = '';
      tab.unread = false;
      tab.decoder = new TextDecoder();
      tab.terminal = new VampBrowserTerminal();
      tab.lastSize = null;
      tab.readyNotified = false;
      tab.pendingInput = null;
      tab.followOutput = false;
      tab.startupSeen = false;
    });
    document.querySelectorAll('.stream').forEach((element) => element.remove());
    chat.querySelectorAll('[data-tab-id], .explore-row[data-tab-id]').forEach((element) => element.remove());
    const notice = addMessage('<div class="badge">Browser session ended. Pair again to reconnect.</div>');
    notice.classList.add('session-ended');
    showPair();
    vampRefreshStatus();
  };
  connection.onerror = () => setState('Connection error');
  connection.onmessage = (event) => {
    let value;
    try { value = JSON.parse(event.data); } catch (_) { return; }
    const terminalErrorText = (code) => {
      const messages = {
        'terminal-disabled': 'Terminal Mode is disabled on the host. Enable it in Vamp Host, then retry this tab.',
        'terminal-capacity': 'This host already has 8 terminal tabs. Close one, then retry.',
        'terminal-start-timeout': 'The shell did not start in time. Check Terminal Mode and retry.',
        'shell-exited': 'The shell exited. Retry this tab to open a fresh shell.',
        'eof': 'The host closed the shell. Retry this tab to open a fresh shell.',
        'user-closed': 'This terminal was closed.',
        'invalid-terminal-size': 'The terminal size was rejected. Resize the browser and retry.',
        'invalid-input': 'That input was rejected by the host.',
        'startup-command-too-large': 'The launcher command is too long.',
        'unknown-command': 'The browser sent an unsupported terminal action.',
        'browser-capacity': 'The host already has another browser connected.'
      };
      if (messages[code]) return messages[code];
      if (String(code || '').startsWith('forkpty failed')) return 'The host could not create a shell. Check macOS permissions and retry.';
      if (String(code || '').startsWith('read-error')) return 'The host shell stopped reading. Retry this tab.';
      return code ? 'Host rejected this terminal action: ' + code : 'The host rejected this terminal action.';
    };
    if (value.type === 'hello') {
      sessionId = value.sessionID;
      setState('Connected');
    } else if (value.type === 'ready') {
      const terminalID = vampTerminalKey(value.terminalID);
      const tab = tabs.get(terminalID);
      if (tab) {
        // A reconnect or host-side PTY notification can repeat ready for the
        // same terminal. Keep the session state idempotent and do not duplicate
        // the visible system card in the task stream.
        if (tab.readyNotified || chat.querySelector('.ready-message[data-tab-id="' + terminalID + '"]')) return;
        const queuedInput = tab.pendingInput;
        tab.pendingInput = null;
        tab.readyNotified = true;
        tab.opened = true;
        tab.state = 'open';
        tab.terminal ||= new VampBrowserTerminal(value.cols, value.rows);
        tab.terminal.resize(value.cols, value.rows);
        ensureStream(terminalID);
        vampResizeTerminal(terminalID);
        renderTabs();
        const readyMessage = addMessage('<span class="check" aria-hidden="true">✓</span><span>' +
          esc(tab.title) + ' ready</span>', terminalID);
        readyMessage.classList.add('status-chip', 'ready-message');
        if (queuedInput && !sendInput(terminalID, queuedInput)) {
          tab.pendingInput = queuedInput;
          addMessage('<div class="badge">The host connection closed before the queued input was sent. Try again.</div>', terminalID);
        }
      }
    } else if (value.type === 'output') {
      vampAppendOutputChunk(vampTerminalKey(value.terminalID), value.data);
    } else if (value.type === 'close') {
      const terminalID = vampTerminalKey(value.terminalID);
      const tab = tabs.get(terminalID);
      if (tab) {
        const remainder = tab.decoder?.decode() || '';
        if (remainder) appendOutput(terminalID, remainder);
        tab.opened = false;
        tab.state = String(value.reason || '').startsWith('terminal-') ? 'error' : 'closed';
        tab.readyNotified = false;
        tab.pendingInput = null;
        tab.unread = active !== terminalID;
        renderTabs();
      }
      addMessage('<div class="meta">System · ' + (String(value.reason || '').startsWith('terminal-') ? 'terminal unavailable' : 'terminal closed') +
        '</div><div class="body">' + esc(terminalErrorText(value.reason || 'closed')) + '</div>', terminalID || active);
    } else if (value.type === 'clipboard') {
      void (async () => {
        try {
          await navigator.clipboard.writeText(value.text || '');
          addMessage('<div class="meta">System · clipboard</div><div class="body">' +
            'Mac clipboard copied to Safari.</div>');
        } catch (_) {
          addMessage('<div class="badge">Safari blocked clipboard writing. Open Clipboard and use the copy action again.</div>');
        }
      })();
    } else if (value.type === 'error') {
      const terminalID = vampTerminalKey(value.terminalID);
      const tab = tabs.get(terminalID);
      if (tab) {
        tab.opened = false;
        tab.state = 'error';
        tab.readyNotified = false;
        tab.pendingInput = null;
        tab.unread = active !== terminalID;
        renderTabs();
      }
      if (value.code === 'terminal-disabled') setState('Disabled');
      addMessage('<div class="badge">' + esc(terminalErrorText(value.code)) + '</div>', terminalID || active);
    }
  };
};

const clipboardButton = $('clipboard');
const clipboardMenu = $('clipboard-menu');
const closeClipboardMenu = () => {
  clipboardMenu.classList.add('hidden');
  clipboardButton.setAttribute('aria-expanded', 'false');
};
clipboardButton.onclick = (event) => {
  event.stopPropagation();
  const hidden = clipboardMenu.classList.toggle('hidden');
  clipboardButton.setAttribute('aria-expanded', String(!hidden));
};
clipboardMenu.onclick = (event) => event.stopPropagation();
document.addEventListener('click', closeClipboardMenu);
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closeClipboardMenu();
});

$('newtab').onclick = () => createTab();
$('send').onclick = reviewCommand;
$('pair-button').onclick = pair;
$('paste').title = 'Paste browser clipboard into the active terminal';
$('paste').setAttribute('aria-label', 'Paste browser clipboard into the active terminal');
$('paste').onclick = async () => {
  try {
    const text = await navigator.clipboard?.readText();
    if (text && active) sendInput(active, text);
  } catch (_) {
    addMessage('<div class="badge">Browser clipboard permission was not granted.</div>');
  }
};
$('copyhost').onclick = () => {
  if (ws && ws.readyState === WebSocket.OPEN) send({ type: 'clipboardGet' });
  closeClipboardMenu();
};
$('sethost').onclick = async () => {
  closeClipboardMenu();
  try {
    const text = await navigator.clipboard.readText();
    if (!text) {
      addMessage('<div class="badge">Your Safari clipboard is empty.</div>');
    } else if (ws && ws.readyState === WebSocket.OPEN) {
      send({ type: 'clipboardSet', text });
      addMessage('<div class="meta">System · clipboard</div><div class="body">Safari clipboard sent to the Mac.</div>');
    }
  } catch (_) {
    addMessage('<div class="badge">Safari clipboard permission was not granted.</div>');
  }
};
$('paste').onclick = async () => {
  closeClipboardMenu();
  try {
    const text = await navigator.clipboard.readText();
    if (text && active) sendInput(active, text);
    else if (!text) addMessage('<div class="badge">Your Safari clipboard is empty.</div>');
  } catch (_) {
    addMessage('<div class="badge">Safari clipboard permission was not granted.</div>');
  }
};
const moreModal = $('more-modal');
const moreCommand = $('more-command');
const closeMoreModal = () => moreModal.classList.add('hidden');
const openMoreModal = () => {
  moreCommand.value = '';
  moreModal.classList.remove('hidden');
  moreCommand.focus();
};
const openMoreTab = (command, title) => {
  closeMoreModal();
  if (order.length >= 8) {
    addMessage('<div class="badge">Terminal capacity reached (8 tabs).</div>');
    return;
  }
  createTab(command || null, title || null);
};
$('more').onclick = openMoreModal;
$('more-cancel').onclick = closeMoreModal;
$('more-shell').onclick = () => openMoreTab(null, null);
$('more-tmux').onclick = () => { moreCommand.value = 'tmux new-session -A -s work'; moreCommand.focus(); };
$('more-screen').onclick = () => { moreCommand.value = 'screen -D -RR work'; moreCommand.focus(); };
$('more-open').onclick = () => {
  const command = moreCommand.value.trim();
  openMoreTab(command || null, command ? 'Session ' + (order.length + 1) : null);
};
const vampShellQuote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
const vampProviderCommand = (executable, session, label) => {
  const quotedExecutable = vampShellQuote(executable);
  const quotedSession = vampShellQuote(session);
  const quotedLabel = vampShellQuote(label);
  return [`if ! command -v tmux >/dev/null 2>&1; then printf '\\nVamp Terminal: tmux is not installed or not on PATH.\\n'; elif ! command -v ${quotedExecutable} >/dev/null 2>&1; then printf '\\nVamp Terminal: ${quotedLabel} CLI (${quotedExecutable}) is not installed or not on PATH.\\n'; else tmux new-session -A -s ${quotedSession} -- ${quotedExecutable}; fi`, label];
};
const providerCommands = {
  opencode: vampProviderCommand('opencode', 'opencode', 'OpenCode'),
  pi: vampProviderCommand('pi', 'pi', 'Pi'),
  commandcode: vampProviderCommand('cmd', 'command-code', 'CommandCode'),
  chatgpt: vampProviderCommand('codex', 'chatgpt', 'ChatGPT / Codex CLI'),
  claude: vampProviderCommand('claude', 'claude', 'Claude Code'),
  kimi: vampProviderCommand('kimi', 'kimi', 'Kimi'),
  qwen: vampProviderCommand('qwen', 'qwen', 'Qwen Code'),
  codex: vampProviderCommand('codex', 'codex', 'Codex CLI'),
  aider: vampProviderCommand('aider', 'aider', 'Aider'),
  grok: vampProviderCommand('grok', 'grok', 'Grok CLI')
};
document.querySelectorAll('[data-provider]').forEach((button) => {
  button.onclick = () => {
    const value = providerCommands[button.dataset.provider];
    if (value) openMoreTab(value[0], value[1]);
  };
});
moreModal.addEventListener('click', (event) => { if (event.target === moreModal) closeMoreModal(); });
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeMoreModal(); });
moreCommand.addEventListener('keydown', (event) => { if (event.key === 'Enter') openMoreTab(moreCommand.value.trim(), null); });
document.addEventListener('visibilitychange', vampUpdateViewportInset);
window.addEventListener('resize', () => {
  vampUpdateViewportInset();
  cancelAnimationFrame(vampResizeFrame);
  vampResizeFrame = requestAnimationFrame(() => { if (active) vampResizeTerminal(active); });
});
window.visualViewport?.addEventListener('resize', () => {
  vampUpdateViewportInset();
  cancelAnimationFrame(vampResizeFrame);
  vampResizeFrame = requestAnimationFrame(() => { if (active) vampResizeTerminal(active); });
});
window.visualViewport?.addEventListener('scroll', vampUpdateViewportInset);
window.addEventListener('orientationchange', vampUpdateViewportInset);
vampUpdateViewportInset();
if (!$('pair').classList.contains('hidden')) $('composer').classList.add('hidden');
renderDashboard();
window.addEventListener('beforeunload', () => ws?.close());
vampRefreshStatus();
const vampPairFromURL = vampNormalizePairingCode(new URLSearchParams(location.search).get('pair'));
if (vampPairFromURL) {
  $('code').value = vampPairFromURL;
  // Keep the one-time code out of browser history after it has been read.
  history.replaceState(null, '', location.pathname + location.hash);
  setTimeout(() => pair(), 350);
}
</script>
<script>
// The browser client is a task stream, not a miniature terminal window. Keep
// the PTY emulator mounted for protocol correctness, then project its useful
// events into a readable, z.ai-style conversation surface.
(() => {
  const shell = document.querySelector('.shell');
  const chat = $('chat');
  const content = document.querySelector('.content');
  if (!shell || !chat || !content) return;

  const style = document.createElement('style');
  style.textContent = `
    :root { --vamp-surface: rgba(38,38,38,.82); --vamp-surface-strong: rgba(48,48,48,.94); --vamp-border: rgba(255,255,255,.14); --vamp-grid: rgba(255,255,255,.045); }
    html, body { position: fixed !important; inset: 0 !important; width: 100% !important; height: 100% !important; min-height: 0 !important; overflow: hidden !important; overscroll-behavior: none !important; }
    body { background: #121212 !important; }
    .shell { position: fixed !important; inset: 0 !important; width: 100% !important; max-width: 1080px !important; height: 100dvh !important; min-height: 0 !important; margin: 0 auto !important; padding: env(safe-area-inset-top) clamp(12px, 3vw, 28px) 0 !important; overflow: hidden !important; transform: none !important; }
    .shell.vamp-keyboard-open { height: var(--vamp-keyboard-height, 100dvh) !important; }
    .top { flex: 0 0 54px; height: 54px !important; }
    .task-context { flex: 0 0 52px; min-width: 0; display: flex; align-items: center; gap: 8px; border-bottom: 1px solid var(--line); overflow: hidden; }
    .task-context .workspace { min-width: 0; max-width: min(42vw, 270px); color: #f3f3f3; font-size: 15px; font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .context-pill, .context-icon { flex: 0 0 auto; min-height: 34px; border: 1px solid rgba(255,255,255,.10); border-radius: 11px; background: rgba(255,255,255,.075); color: #c8c8c8; }
    .context-pill { max-width: 38vw; padding: 0 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .context-icon { width: 36px; padding: 0; font-size: 16px; }
    .context-icon:active, .context-pill:active { background: rgba(255,255,255,.16); }
    .tabs { flex: 0 0 64px; min-height: 64px; padding: 10px 0 !important; }
    .content { flex: 1 1 auto !important; height: 0 !important; min-height: 0 !important; display: block !important; overflow-x: hidden !important; overflow-y: auto !important; overscroll-behavior: contain !important; -webkit-overflow-scrolling: touch; scrollbar-gutter: stable; }
    .chat { min-height: 100% !important; padding: 18px 0 calc(112px + env(safe-area-inset-bottom)) !important; }
    .chat > .hidden, .chat > [data-tab-id].vamp-tab-hidden { display: none !important; }
    .message, .command-card, .stream-card, .explore-row { max-width: 820px; margin-left: auto; margin-right: auto; }
    .message { margin-bottom: 22px; line-height: 1.62; }
    .message .meta { display: flex; align-items: center; gap: 8px; color: #858585; font-size: 12px; letter-spacing: .01em; }
    .message .body { color: #ededed; }
    .message.user-message { margin-top: 18px; }
    .message.user-message .body { color: #dcdcdc; }
    .message.system-message { margin-top: 8px; }
    .message.system-message .body { color: #d7d7d7; }
    .explore-row { display: flex; align-items: center; gap: 7px; width: 100%; margin: 15px auto 16px; color: #808080; font-size: 13px; }
    .explore-row .explore-icon { color: #6b6b6b; font-size: 18px; line-height: 1; }
    .explore-row .explore-kind { color: #bcbcbc; font-weight: 650; }
    .explore-row .explore-detail { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .status-chip { display: inline-flex; align-items: center; gap: 7px; width: fit-content; max-width: 100%; margin: 0 0 18px; padding: 8px 12px; border: 1px solid rgba(66,211,146,.24); border-radius: 999px; background: rgba(66,211,146,.10); color: #d7f7e7; font-size: 13px; font-weight: 650; }
    .status-chip .check { color: var(--good); }
    .stream-card { margin-top: 12px; margin-bottom: 24px; padding: 14px; border: 1px solid var(--vamp-border); border-radius: 18px; background: linear-gradient(145deg, rgba(45,45,45,.78), rgba(25,25,25,.88)); box-shadow: 0 16px 44px rgba(0,0,0,.20), inset 0 1px 0 rgba(255,255,255,.045); }
    .stream-card-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; min-width: 0; }
    .stream-card-title { display: flex; align-items: center; gap: 9px; min-width: 0; color: #f3f3f3; font-weight: 700; }
    .stream-card-title span:last-child { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .card-glyph { display: grid; place-items: center; width: 28px; height: 28px; flex: 0 0 28px; border-radius: 9px; background: rgba(255,255,255,.10); color: #e9e9e9; font-size: 17px; }
    .stream-state { flex: 0 0 auto; color: var(--good); font-size: 11px; font-weight: 700; letter-spacing: .04em; text-transform: uppercase; }
    .stream-state::before { content: '●'; margin-right: 5px; }
    .stream-caption { margin: 9px 0 12px 37px; color: #8f8f8f; font-size: 12px; }
    .rich-body { min-width: 0; color: #ededed; overflow-wrap: anywhere; }
    .rich-body p { margin: 0 0 12px; line-height: 1.6; }
    .rich-body p:last-child { margin-bottom: 0; }
    .rich-body h3 { margin: 0 0 10px; color: #f5f5f5; font-size: 16px; }
    .inline-code { display: inline; padding: 2px 5px; border: 1px solid rgba(255,255,255,.12); border-radius: 5px; background: rgba(255,255,255,.09); color: #f2f2f2; font: .92em ui-monospace, SFMono-Regular, Menlo, monospace; }
    .rich-code, .rich-box { margin: 0 0 12px; padding: 12px; border: 1px solid rgba(255,255,255,.11); border-radius: 12px; background: rgba(10,10,10,.74); color: #e7e7e7; font: 13px/1.52 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-x: auto; }
    .rich-code:last-child, .rich-box:last-child { margin-bottom: 0; }
    .rich-code .code-language { display: block; margin-bottom: 7px; color: #8d8d8d; font: 10px -apple-system, BlinkMacSystemFont, sans-serif; letter-spacing: .10em; text-transform: uppercase; }
    .rich-table-wrap { margin: 0 0 12px; overflow-x: auto; border: 1px solid rgba(255,255,255,.11); border-radius: 12px; background: rgba(10,10,10,.50); }
    .rich-table { width: 100%; min-width: 360px; border-collapse: collapse; font-size: 13px; }
    .rich-table th, .rich-table td { padding: 9px 10px; border-bottom: 1px solid rgba(255,255,255,.10); text-align: left; vertical-align: top; }
    .rich-table th { color: #f0f0f0; background: rgba(255,255,255,.07); font-weight: 700; }
    .rich-table td { color: #d1d1d1; }
    .rich-table tr:last-child td { border-bottom: 0; }
    .rich-step { display: flex; align-items: flex-start; gap: 8px; margin: 0 0 10px; padding: 9px 10px; border-left: 2px solid rgba(255,255,255,.22); color: #dedede; }
    .rich-step.good { border-color: var(--good); background: rgba(66,211,146,.07); }
    .rich-step.warn { border-color: var(--warn); background: rgba(255,200,87,.07); }
    .rich-step.bad { border-color: var(--danger); background: rgba(255,117,107,.07); }
    .rich-step .step-mark { flex: 0 0 auto; font-weight: 800; }
    .rich-step.good .step-mark { color: var(--good); }
    .rich-step.warn .step-mark { color: var(--warn); }
    .rich-step.bad .step-mark { color: var(--danger); }
    .rich-empty { color: #969696; font-size: 13px; }
    .command-card { margin-top: 14px; margin-bottom: 24px; padding: 16px; border: 1px solid rgba(255,255,255,.15); border-radius: 18px; background: linear-gradient(145deg, rgba(52,52,52,.88), rgba(35,35,35,.94)); box-shadow: 0 18px 48px rgba(0,0,0,.24); }
    .command-card .eyebrow { color: #d0d0d0; font-size: 15px; font-weight: 700; }
    .command-card .approval { color: #a7a7a7; margin: 6px 0 13px; font-size: 13px; }
    .command-card .command { padding: 13px; border-radius: 13px; background: rgba(12,12,12,.76); font-size: 13px; line-height: 1.5; }
    .command-card .command .prompt { color: #aaa; }
    .approval-actions { gap: 7px !important; }
    .approval-choice { min-height: 52px; padding: 10px 12px; border: 1px solid rgba(255,255,255,.12); color: #f1f1f1 !important; background: rgba(255,255,255,.055) !important; }
    .approval-choice strong { color: #f1f1f1 !important; }
    .approval-choice small { color: #a7a7a7 !important; }
    .approval-choice.selected { border-color: rgba(66,211,146,.62); background: rgba(66,211,146,.13) !important; }
    .approval-choice:focus-visible, .confirm:focus-visible, .context-icon:focus-visible, .context-pill:focus-visible { outline: 2px solid rgba(255,255,255,.72); outline-offset: 2px; }
    .approval-footer { margin-top: 14px; }
    .approval-footer .hint { color: #a7a7a7; }
    .composer { left: 12px !important; right: 12px !important; bottom: max(10px, env(safe-area-inset-bottom)) !important; width: min(calc(100% - 24px), 952px) !important; height: 60px !important; min-height: 60px !important; margin: 0 auto !important; }
    .modal { height: 100% !important; }
    .modal-card { max-height: calc(100% - 32px) !important; }
    @media (min-width: 720px) { .shell { left: 50% !important; right: auto !important; width: min(100%, 1080px) !important; transform: translateX(-50%) !important; } .chat { padding-left: 24px !important; padding-right: 24px !important; } }
    @media (max-width: 520px) { .shell { padding-left: 12px !important; padding-right: 12px !important; } .task-context .workspace { max-width: 36vw; } .context-pill { max-width: 31vw; } .message, .command-card, .stream-card, .explore-row { max-width: none; } }
    @media (prefers-reduced-motion: reduce) { .content { scroll-behavior: auto !important; } }
    /* Final iPhone fit pass. Safari zooms the page when a text field is below
       16px and fixed left/right/width combinations can create a second
       horizontal layout viewport. Keep every mobile surface inside the
       device bounds and let the browser resize the visual viewport naturally. */
    html { -webkit-text-size-adjust: 100%; overflow-x: hidden !important; }
    body { width: 100% !important; max-width: 100% !important; overflow-x: hidden !important; }
    .shell { left: 0 !important; right: auto !important; width: 100% !important; max-width: none !important; margin: 0 !important; transform: none !important; overflow-x: hidden !important; }
    .top { position: relative !important; z-index: 8 !important; display: flex !important; visibility: visible !important; opacity: 1 !important; color: #f1f1f1 !important; background: rgba(18,18,18,.96) !important; }
    .top .back, .top .title, .top .state, .top .state .dot, .top .state span { visibility: visible !important; opacity: 1 !important; color: #f1f1f1 !important; -webkit-text-fill-color: #f1f1f1 !important; }
    .top .back { display: grid !important; place-items: center !important; flex: 0 0 32px !important; width: 32px !important; min-width: 32px !important; }
    .top .title { display: block !important; flex: 0 1 auto !important; min-width: 0 !important; }
    .top .state { display: flex !important; align-items: center !important; white-space: nowrap !important; }
    .task-context { width: 100% !important; max-width: 100% !important; padding-left: 0 !important; padding-right: 0 !important; gap: 5px !important; }
    .task-context .workspace { flex: 1 1 auto !important; width: auto !important; max-width: none !important; min-width: 0 !important; }
    .task-context .context-pill { flex: 0 1 108px !important; width: auto !important; max-width: 108px !important; min-width: 0 !important; padding-left: 8px !important; padding-right: 8px !important; }
    .task-context .context-icon { flex: 0 0 32px !important; width: 32px !important; min-width: 32px !important; }
    .tabs { width: 100% !important; max-width: 100% !important; min-width: 0 !important; }
    .content { width: 100% !important; max-width: 100% !important; min-width: 0 !important; }
    .chat { width: 100% !important; max-width: 100% !important; min-width: 0 !important; }
    .composer { left: 12px !important; right: auto !important; width: calc(100% - 24px) !important; max-width: none !important; margin: 0 !important; transform: none !important; }
    .composer input, .modal-card input, .more-command input { font-size: 16px !important; line-height: 22px !important; -webkit-text-size-adjust: 100%; }
    @media (min-width: 720px) {
      .shell { left: 50% !important; right: auto !important; width: min(100%, 1080px) !important; max-width: 1080px !important; margin: 0 !important; transform: translateX(-50%) !important; }
      .composer { left: 50% !important; right: auto !important; width: min(calc(100% - 56px), 952px) !important; transform: translateX(-50%) !important; }
    }
    /* iOS Safari can pan a flex document when its keyboard is presented even
       when the document has no page scroll. Pin the navigation chrome to the
       visual viewport in that mode and give the conversation its own bounded
       scrolling region. This keeps the task header, tabs, latest text, and
       composer on the same screen while typing. */
    @media (max-width: 719px) {
      .shell.vamp-keyboard-open { padding-top: 0 !important; }
      .shell.vamp-keyboard-open .top,
      .shell.vamp-keyboard-open .task-context,
      .shell.vamp-keyboard-open .tabs {
        position: fixed !important;
        left: 12px !important;
        right: 12px !important;
        width: auto !important;
        max-width: none !important;
        margin: 0 !important;
        background: rgba(18,18,18,.98) !important;
      }
      .shell.vamp-keyboard-open .top {
        top: max(44px, env(safe-area-inset-top)) !important;
        height: 54px !important;
        z-index: 12 !important;
      }
      .shell.vamp-keyboard-open .task-context {
        top: calc(max(44px, env(safe-area-inset-top)) + 54px) !important;
        height: 52px !important;
        z-index: 11 !important;
      }
      .shell.vamp-keyboard-open .tabs {
        top: calc(max(44px, env(safe-area-inset-top)) + 106px) !important;
        height: 64px !important;
        z-index: 10 !important;
      }
      .shell.vamp-keyboard-open .content {
        position: fixed !important;
        top: calc(max(44px, env(safe-area-inset-top)) + 170px) !important;
        left: 12px !important;
        right: 12px !important;
        bottom: 72px !important;
        width: auto !important;
        height: auto !important;
        max-width: none !important;
        overflow-x: hidden !important;
        overflow-y: auto !important;
        z-index: 1 !important;
      }
      .shell.vamp-keyboard-open .composer {
        z-index: 20 !important;
      }
    }
    /* Final viewport-canvas pass. iOS Safari can move the visual viewport
       over the layout viewport while the keyboard is opening. A fixed root
       then paints its chrome outside the visible screen. Keep one absolute
       canvas sized from VisualViewport and place every mobile surface inside
       it; the JS offset tracks Safari's pan without competing z-index layers. */
    html {
      position: relative !important;
      inset: auto !important;
      width: 100% !important;
      height: 100% !important;
      overflow: hidden !important;
    }
    body {
      position: relative !important;
      inset: auto !important;
      width: 100% !important;
      height: 100% !important;
      min-height: 0 !important;
      overflow: hidden !important;
    }
    .shell {
      position: absolute !important;
      left: var(--vamp-vv-left, 0px) !important;
      top: var(--vamp-vv-top, 0px) !important;
      right: auto !important;
      bottom: auto !important;
      width: var(--vamp-visual-width, 100%) !important;
      height: var(--vamp-visual-height, 100dvh) !important;
      max-width: none !important;
      min-height: 0 !important;
      margin: 0 !important;
      transform: none !important;
      padding: env(safe-area-inset-top) clamp(12px, 3vw, 28px) env(safe-area-inset-bottom) !important;
      overflow: hidden !important;
    }
    .top, .task-context, .tabs {
      position: relative !important;
      top: auto !important;
      left: auto !important;
      right: auto !important;
      bottom: auto !important;
      width: 100% !important;
      transform: none !important;
    }
    .task-context .context-pill {
      flex: 0 0 76px !important;
      width: 76px !important;
      max-width: 76px !important;
      padding-left: 8px !important;
      padding-right: 8px !important;
    }
    .task-context .context-pill span {
      min-width: 0 !important;
      overflow: hidden !important;
      text-overflow: ellipsis !important;
      white-space: nowrap !important;
    }
    .content {
      position: relative !important;
      top: auto !important;
      left: auto !important;
      right: auto !important;
      bottom: auto !important;
      width: 100% !important;
      height: 0 !important;
      flex: 1 1 auto !important;
      min-height: 0 !important;
      overflow-x: hidden !important;
      overflow-y: auto !important;
      transform: none !important;
    }
    .composer {
      position: absolute !important;
      left: 12px !important;
      right: auto !important;
      bottom: max(10px, env(safe-area-inset-bottom)) !important;
      width: calc(100% - 24px) !important;
      max-width: none !important;
      margin: 0 !important;
      transform: none !important;
      z-index: 30 !important;
    }
    .modal {
      position: absolute !important;
      top: var(--vamp-vv-top, 0px) !important;
      left: var(--vamp-vv-left, 0px) !important;
      right: auto !important;
      bottom: auto !important;
      width: var(--vamp-visual-width, 100%) !important;
      height: var(--vamp-visual-height, 100dvh) !important;
      z-index: 50 !important;
    }
    @media (max-width: 520px) {
      .task-context { gap: 4px !important; }
      .task-context .workspace { font-size: 14px !important; }
      .task-context .context-pill { flex-basis: 66px !important; width: 66px !important; max-width: 66px !important; }
      .task-context .context-pill span { font-size: 12px !important; }
      .task-context .context-icon { flex-basis: 30px !important; width: 30px !important; min-width: 30px !important; }
    }
    @media (min-width: 720px) {
      .shell {
        left: 50% !important;
        width: min(var(--vamp-visual-width, 100%), 1080px) !important;
        transform: translateX(-50%) !important;
      }
      .composer {
        left: 50% !important;
        width: min(calc(100% - 56px), 952px) !important;
        transform: translateX(-50%) !important;
      }
    }
    @media (max-width: 719px) {
      .shell.vamp-keyboard-open { padding-top: env(safe-area-inset-top) !important; }
      .shell.vamp-keyboard-open .top,
      .shell.vamp-keyboard-open .task-context,
      .shell.vamp-keyboard-open .tabs,
      .shell.vamp-keyboard-open .content {
        position: relative !important;
        top: auto !important;
        left: auto !important;
        right: auto !important;
        bottom: auto !important;
        width: 100% !important;
        transform: none !important;
      }
      .shell.vamp-keyboard-open .content {
        height: 0 !important;
        flex: 1 1 auto !important;
        min-height: 0 !important;
        overflow-x: hidden !important;
        overflow-y: auto !important;
      }
      .shell.vamp-keyboard-open .composer { position: absolute !important; z-index: 30 !important; }
    }
    /* Final chat projection contract: one stacking context, one scroll owner,
       and a visual hierarchy that reads like a task conversation instead of
       a terminal window. */
    :root {
      --vamp-z-content: 1;
      --vamp-z-chrome: 10;
      --vamp-z-composer: 30;
      --vamp-z-menu: 40;
      --vamp-z-modal: 50;
    }
    .shell { isolation: isolate !important; }
    .top, .task-context, .tabs { z-index: var(--vamp-z-chrome) !important; }
    .tabs { padding-right: 12px !important; }
    .tabs > .tab, .tabs > .newtab { flex: 0 0 auto; }
    .content { z-index: var(--vamp-z-content) !important; touch-action: pan-y; }
    .composer { z-index: var(--vamp-z-composer) !important; }
    .clipboard-menu { z-index: var(--vamp-z-menu) !important; }
    .modal { z-index: var(--vamp-z-modal) !important; }
    .message, .command-card, .stream-card, .explore-row { width: 100%; min-width: 0; }
    .message.ready-message.status-chip {
      display: flex !important;
      align-items: center;
      gap: 8px;
      width: fit-content;
      max-width: min(100%, 360px);
      margin: 12px 0 20px auto !important;
      padding: 9px 13px;
      border: 1px solid rgba(66,211,146,.25);
      border-radius: 999px;
      background: rgba(66,211,146,.10);
      color: #d7f7e7;
      font-size: 13px;
      font-weight: 650;
      line-height: 1.25;
    }
    .message.ready-message .check { color: var(--good); font-size: 16px; line-height: 1; }
    .stream-card.output-message {
      padding: 0;
      border-color: transparent;
      background: transparent;
      box-shadow: none;
    }
    .stream-card.output-message:not(.structured-output) .rich-body {
      padding-left: 37px;
    }
    .stream-card.output-message:not(.structured-output) .rich-body p {
      color: #f0f0f0;
      font-size: 16px;
      line-height: 1.62;
    }
    .stream-card.output-message.structured-output {
      padding: 16px;
      border-color: var(--vamp-border);
      background: linear-gradient(145deg, rgba(45,45,45,.78), rgba(25,25,25,.90));
      box-shadow: 0 16px 44px rgba(0,0,0,.20), inset 0 1px 0 rgba(255,255,255,.045);
    }
    .stream-card.output-message.structured-output .rich-body { margin-top: 12px; }
    .rich-body .rich-code, .rich-body .rich-box, .rich-body .rich-table-wrap {
      max-width: 100%;
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
    }
    .rich-body .rich-code, .rich-body .rich-box { white-space: pre-wrap; overflow-wrap: anywhere; }
    @media (max-width: 719px) {
      html, body { overscroll-behavior: none !important; }
      .content { overscroll-behavior-y: contain !important; }
      .stream-card.output-message:not(.structured-output) .rich-body { padding-left: 0; }
    }
  `;
  document.head.appendChild(style);

  const context = document.createElement('div');
  context.className = 'task-context';
  context.id = 'task-context';
  context.innerHTML = '<div class="workspace" id="context-workspace">Task workspace</div>' +
    '<button class="context-pill" id="context-repo" type="button" aria-label="Workspace source">▣ <span>Host</span></button>' +
    '<button class="context-icon" id="context-branch" type="button" aria-label="Session routing">⑂</button>' +
    '<button class="context-icon" id="context-more" type="button" aria-label="Terminal actions">•••</button>' +
    '<button class="context-icon" id="context-panel" type="button" aria-label="Open sessions dashboard">◧</button>';
  document.querySelector('.top')?.insertAdjacentElement('afterend', context);

  const keyboardViewportUpdate = () => {
    const viewport = window.visualViewport;
    const layoutWidth = document.documentElement.clientWidth || window.innerWidth;
    const layoutHeight = document.documentElement.clientHeight || window.innerHeight;
    const visibleWidth = viewport?.width || layoutWidth;
    const visibleHeight = viewport?.height || layoutHeight;
    // iOS Safari moves the visual viewport over the layout viewport while the
    // keyboard or its browser chrome is visible. The shell is positioned at
    // this offset so absolute children behave like device-fixed UI without
    // relying on Safari's unreliable position:fixed compositor path.
    const offsetLeft = Number.isFinite(viewport?.offsetLeft) ? viewport.offsetLeft : 0;
    const offsetTop = Number.isFinite(viewport?.offsetTop) ? viewport.offsetTop : 0;
    const inset = Math.max(0, Math.round(layoutHeight - visibleHeight - Math.max(0, offsetTop)));
    const keyboardOpen = visibleHeight < layoutHeight - 80 || inset > 100;
    document.documentElement.style.setProperty('--vamp-visual-width', Math.max(280, Math.round(visibleWidth)) + 'px');
    document.documentElement.style.setProperty('--vamp-visual-height', Math.max(240, Math.round(visibleHeight)) + 'px');
    document.documentElement.style.setProperty('--vamp-vv-left', Math.round(offsetLeft) + 'px');
    document.documentElement.style.setProperty('--vamp-vv-top', Math.round(offsetTop) + 'px');
    shell.classList.toggle('vamp-keyboard-open', keyboardOpen);
    document.documentElement.classList.toggle('vamp-keyboard-open', keyboardOpen);
    if (keyboardOpen) document.documentElement.style.setProperty('--vamp-keyboard-height', Math.max(240, Math.round(visibleHeight)) + 'px');
    else document.documentElement.style.removeProperty('--vamp-keyboard-height');
  };
  const resetPagePosition = () => {
    document.documentElement.scrollTop = 0;
    document.body.scrollTop = 0;
    window.scrollTo(0, 0);
    content.dataset.userScrolled = 'false';
    requestAnimationFrame(() => { document.documentElement.scrollTop = 0; document.body.scrollTop = 0; window.scrollTo(0, 0); });
  };
  const isNearBottom = () => content.scrollHeight - content.scrollTop - content.clientHeight < 96;
  const scrollLatest = (force = false) => {
    if (!force && !isNearBottom()) return;
    requestAnimationFrame(() => {
      content.dataset.vampProgrammatic = '1';
      content.scrollTop = content.scrollHeight;
      requestAnimationFrame(() => { delete content.dataset.vampProgrammatic; });
    });
  };
  content.addEventListener('scroll', () => {
    if (!content.dataset.vampProgrammatic) {
      const nearBottom = isNearBottom();
      content.dataset.userScrolled = content.scrollTop > 4 && !nearBottom ? 'true' : 'false';
      const tab = tabs.get(active);
      if (tab) tab.followOutput = nearBottom;
    }
  }, { passive: true });
  window.addEventListener('resize', keyboardViewportUpdate, { passive: true });
  window.visualViewport?.addEventListener('resize', keyboardViewportUpdate, { passive: true });
  window.visualViewport?.addEventListener('scroll', keyboardViewportUpdate, { passive: true });
  window.addEventListener('orientationchange', () => { keyboardViewportUpdate(); resetPagePosition(); }, { passive: true });
  document.addEventListener('focusin', () => setTimeout(keyboardViewportUpdate, 60), { passive: true });
  document.addEventListener('visibilitychange', keyboardViewportUpdate, { passive: true });
  keyboardViewportUpdate();

  // The page itself is a visual-viewport canvas. Only the conversation owns
  // vertical scrolling; allowing the body to rubber-band is what exposes a
  // clipped header and makes users pull the whole page down to "fit" it.
  document.addEventListener('touchmove', (event) => {
    const target = event.target instanceof Element ? event.target : null;
    if (target?.closest('.content, .tabs, .task-context, .composer, .modal')) return;
    event.preventDefault();
  }, { passive: false });

  const filterTabContent = () => {
    chat.querySelectorAll('[data-tab-id]').forEach((element) => {
      element.classList.toggle('vamp-tab-hidden', Boolean(active) && element.dataset.tabId !== active);
    });
  };

  const inline = (value) => {
    const source = String(value || '');
    const matcher = /`([^`\n]+)`/g;
    let result = '';
    let cursor = 0;
    let match;
    while ((match = matcher.exec(source))) {
      result += esc(source.slice(cursor, match.index));
      result += '<code class="inline-code">' + esc(match[1]) + '</code>';
      cursor = match.index + match[0].length;
    }
    return result + esc(source.slice(cursor));
  };
  const cells = (line) => {
    let value = String(line || '').trim();
    if (value.startsWith('|')) value = value.slice(1);
    if (value.endsWith('|')) value = value.slice(0, -1);
    return value.split('|').map((cell) => cell.trim());
  };
  const delimiter = (line) => {
    const values = cells(line);
    return values.length > 0 && values.every((value) => /^:?-{3,}:?$/.test(value));
  };
  const pipeRow = (line) => String(line || '').includes('|');
  const boxRow = (line) => /[┌┐└┘├┤┬┴┼│─╭╮╰╯╠╣╦╩╬]/.test(line) || /^\s*[+|-]{4,}\s*$/.test(line);
  const stepRow = (line) => /^\s*(?:✓|✔|✗|✘|⚠|!|→|›|•)\s+/.test(line);

  const renderBlocks = (raw) => {
    const lines = String(raw || '').replace(/\r/g, '').split('\n');
    const blocks = [];
    let index = 0;
    while (index < lines.length) {
      const line = lines[index];
      if (!line.trim()) { index += 1; continue; }
      const fence = line.trim().match(/^```\s*([\w.+-]*)/);
      if (fence) {
        const language = fence[1] || 'output';
        index += 1;
        const code = [];
        while (index < lines.length && !/^\s*```/.test(lines[index])) { code.push(lines[index]); index += 1; }
        if (index < lines.length) index += 1;
        blocks.push('<pre class="rich-code"><span class="code-language">' + esc(language) + '</span>' + esc(code.join('\n')) + '</pre>');
        continue;
      }
      if (index + 1 < lines.length && pipeRow(line) && delimiter(lines[index + 1])) {
        const header = cells(line);
        const rows = [];
        index += 2;
        while (index < lines.length && pipeRow(lines[index]) && lines[index].trim()) { rows.push(cells(lines[index])); index += 1; }
        blocks.push('<div class="rich-table-wrap"><table class="rich-table"><thead><tr>' + header.map((value) => '<th>' + inline(value) + '</th>').join('') + '</tr></thead><tbody>' + rows.map((row) => '<tr>' + header.map((_, cellIndex) => '<td>' + inline(row[cellIndex] || '') + '</td>').join('') + '</tr>').join('') + '</tbody></table></div>');
        continue;
      }
      if (boxRow(line)) {
        const box = [];
        while (index < lines.length && lines[index].trim() && boxRow(lines[index])) { box.push(lines[index]); index += 1; }
        blocks.push('<pre class="rich-box">' + esc(box.join('\n')) + '</pre>');
        continue;
      }
      const heading = line.match(/^\s*#{1,3}\s+(.+)/);
      if (heading) { blocks.push('<h3>' + inline(heading[1]) + '</h3>'); index += 1; continue; }
      if (stepRow(line)) {
        const step = line.trim().match(/^([^\s]+)\s+(.+)/);
        const mark = step?.[1] || '•';
        const body = step?.[2] || line.trim();
        const kind = /^(?:✓|✔)/.test(mark) ? 'good' : /^(?:⚠|!)/.test(mark) ? 'warn' : /^(?:✗|✘)/.test(mark) ? 'bad' : '';
        blocks.push('<div class="rich-step ' + kind + '"><span class="step-mark">' + esc(mark) + '</span><span>' + inline(body) + '</span></div>');
        index += 1;
        continue;
      }
      const paragraph = [line];
      index += 1;
      while (index < lines.length && lines[index].trim() && !/^```/.test(lines[index].trim()) && !(index + 1 < lines.length && pipeRow(lines[index]) && delimiter(lines[index + 1])) && !boxRow(lines[index]) && !stepRow(lines[index]) && !/^\s*#{1,3}\s+/.test(lines[index])) {
        paragraph.push(lines[index]);
        index += 1;
      }
      blocks.push('<p>' + inline(paragraph.join('\n')) + '</p>');
    }
    return blocks.join('');
  };

  const ensureOutputCard = (id) => {
    const tab = tabs.get(id);
    if (!tab) return null;
    if (!tab.outputCard || !tab.outputCard.isConnected) {
      const card = document.createElement('article');
      card.className = 'message stream-card output-message';
      card.dataset.tabId = id;
      card.innerHTML = '<div class="stream-card-head"><div class="stream-card-title"><span class="card-glyph">⌁</span><span>' + esc(tab.title) + '</span></div><span class="stream-state">Streaming</span></div><div class="stream-caption">Terminal output · live</div><div class="rich-body" role="log" aria-live="polite"></div>';
      chat.appendChild(card);
      tab.outputCard = card;
    }
    return tab.outputCard;
  };
  const updateOutputCard = (id, text, replace = true) => {
    const tab = tabs.get(id);
    if (!tab) return;
    const stickToLatest = id === active && (tab.followOutput === true || isNearBottom());
    const card = ensureOutputCard(id);
    if (!card) return;
    const value = String(text || '').slice(-24000);
    const meaningful = value.trim() && value.trim() !== 'No output.' && value.trim() !== 'No output yet.';
    if (replace) tab.outputText = meaningful ? value : '';
    else tab.outputText = ((tab.outputText || '') + value).slice(-24000);
    const body = card.querySelector('.rich-body');
    if (body) {
      const rendered = renderBlocks(tab.outputText) || '<div class="rich-empty">Waiting for terminal output…</div>';
      body.innerHTML = rendered;
      card.classList.toggle('structured-output', /rich-(?:code|box|table-wrap|step)/.test(rendered));
    }
    const state = card.querySelector('.stream-state');
    if (state) state.textContent = tab.pendingCommand ? 'Streaming' : 'Live';
    filterTabContent();
    // Measure stickiness before the card grows. Checking after rendering
    // makes a long response look like the user scrolled away and breaks the
    // chat-following behavior once the card becomes taller than the viewport.
    if (stickToLatest) scrollLatest(true);
  };
  const addExplore = (id, detail) => {
    const tab = tabs.get(id);
    if (!tab || !detail) return;
    const row = document.createElement('div');
    row.className = 'explore-row';
    row.dataset.tabId = id;
    row.innerHTML = '<span class="explore-icon" aria-hidden="true">⌕</span><span class="explore-kind">Explore</span><span>·</span><span class="explore-detail">' + esc(detail) + '</span>';
    chat.appendChild(row);
    filterTabContent();
    if (id === active) scrollLatest(false);
  };

  addMessage = (html, tabID = active) => {
    const stick = isNearBottom();
    const element = document.createElement('article');
    element.className = 'message';
    if (tabID) element.dataset.tabId = tabID;
    element.innerHTML = html;
    if (/terminal ready/i.test(element.textContent || '')) element.classList.add('system-message');
    chat.appendChild(element);
    filterTabContent();
    if (stick) scrollLatest(true);
    return element;
  };

  appendOutput = (id, text) => {
    const tab = tabs.get(id);
    if (!tab) return;
    tab.decoder ||= new TextDecoder();
    tab.approvals ||= new Set();
    tab.terminal ||= new VampBrowserTerminal();
    tab.terminal.feed(text);
    tab.out = tab.terminal.render();
    const commandResponse = vampRenderedCommandResponse(tab);
    if (commandResponse.found) {
      tab.pendingCommand = null;
      updateOutputCard(id, commandResponse.text || 'No output.', true);
      if (active !== id) { tab.unread = true; renderTabs(); }
      return;
    }
    if (tab.pendingCommand) {
      // A shell or agent is allowed to suppress/transform PTY echo. Waiting
      // forever for an exact rendered copy of the command made the Chat view
      // look frozen even though the host was producing a real response. Once
      // this frame contains visible non-prompt text, promote it immediately;
      // the terminal buffer remains the source of truth for Raw mode.
      const visible = vampNormalizeChatOutput(text, tab);
      if (visible) {
        tab.pendingCommand = null;
        updateOutputCard(id, visible, false);
      }
      if (active !== id) { tab.unread = true; renderTabs(); }
      return;
    }
    // Do not project the shell prompt or an agent's alternate-screen startup
    // banner into the conversation. The z.ai-style surface starts with a
    // compact ready chip and only promotes deliberate command responses into
    // readable assistant cards. This prevents Grok/Claude/OpenCode TUIs from
    // becoming a giant raw terminal screenshot when a tab first connects.
    if (!tab.commandCount) {
      tab.startupSeen = true;
    } else {
      const visible = vampNormalizeChatOutput(text, { pendingCommand: null });
      if (visible) updateOutputCard(id, visible, false);
    }
    if (active !== id) { tab.unread = true; renderTabs(); }
  };

  appendCommand = (value, status, tabID = active) => {
    const tab = tabs.get(tabID);
    if (tab) {
      tab.pendingCommand = value;
      tab.pendingOutputFrames = 0;
      tab.followOutput = true;
      tab.outputCard = null;
      tab.outputText = '';
      tab.commandCount = (tab.commandCount || 0) + 1;
    }
    const title = tab?.title || 'Terminal';
    const element = addMessage('<div class="meta">You · ' + esc(title) + ' · ' + esc(status) + '</div><div class="body"><span style="color:#aaa">$ </span>' + esc(value) + '</div>', tabID);
    element.classList.add('user-message');
    addExplore(tabID, 'Running ' + value);
    return element;
  };

  reviewCommand = () => {
    const value = $('input').value.trim();
    const tabID = active;
    const tab = tabs.get(tabID);
    if (!value || !tabID) return;
    if (!tab || !ws || ws.readyState !== WebSocket.OPEN) {
      addMessage('<div class="badge">This terminal is still opening. The command stays in the composer.</div>', tabID);
      return;
    }
    if (!tab.opened) {
      if (tab.pendingInput) {
        addMessage('<div class="badge">One command is already queued. It will run when this terminal is ready.</div>', tabID);
        return;
      }
      tab.pendingInput = value + '\n';
      $('input').value = '';
      appendCommand(value, 'Queued · starting', tabID);
      vampScrollChatToLatest();
      return;
    }
    tab.approvals ||= new Set();
    if (tab.approvals.has(value)) {
      if (sendInput(tabID, value + '\n')) { $('input').value = ''; appendCommand(value, 'Running', tabID); }
      return;
    }
    const card = document.createElement('article');
    card.className = 'command-card';
    card.dataset.tabId = tabID;
    card.innerHTML = '<div class="eyebrow">⌁ Permission required</div><div class="approval">Awaiting approval · ' + esc(tab.title) + '</div><div class="command"><span class="prompt">$ </span>' + esc(value) + '<br><span style="color:#888">No output.</span></div><div class="approval-actions"><button type="button" class="approval-choice selected" data-choice="once"><span class="choice-number">1.</span><span><strong>Allow</strong><small>Allow only this time</small></span></button><button type="button" class="approval-choice" data-choice="always"><span class="choice-number">2.</span><span><strong>Always allow</strong><small>Do not ask again for this command</small></span></button><button type="button" class="approval-choice" data-choice="deny"><span class="choice-number">3.</span><span><strong>Deny</strong><small>Reject it for now</small></span></button></div><div class="approval-footer"><p class="hint">Choose an action, then press Confirm.</p><button type="button" class="confirm">Confirm</button></div>';
    let choice = 'once';
    card.querySelectorAll('[data-choice]').forEach((button) => {
      button.onclick = () => { choice = button.dataset.choice || 'once'; card.querySelectorAll('[data-choice]').forEach((candidate) => candidate.classList.toggle('selected', candidate === button)); };
    });
    card.querySelector('.confirm').onclick = () => {
      card.remove();
      const current = tabs.get(tabID);
      if (choice === 'deny') {
        $('input').value = '';
        const denied = addMessage('<div class="meta">You · ' + esc(current?.title || 'Terminal') + ' · Denied</div><div class="body"><span style="color:#aaa">$ </span>' + esc(value) + '</div>', tabID);
        denied.classList.add('user-message');
        return;
      }
      if (choice === 'always' && current) { current.approvals ||= new Set(); current.approvals.add(value); }
      if (sendInput(tabID, value + '\n')) { $('input').value = ''; appendCommand(value, choice === 'always' ? 'Always allowed · running' : 'Running', tabID); }
      else { if (choice === 'always' && current) current.approvals.delete(value); $('input').value = value; addMessage('<div class="badge">The host connection closed before the command was sent. Try again.</div>', tabID); }
    };
    const stick = isNearBottom();
    chat.appendChild(card);
    filterTabContent();
    $('input').value = '';
    if (stick) scrollLatest(true);
  };

  selectTab = (id) => {
    const tab = tabs.get(id);
    if (!tab) return;
    active = id;
    tab.unread = false;
    tab.followOutput = true;
    if (tab.opened) ensureStream(id);
    document.querySelectorAll('.stream').forEach((element) => element.classList.toggle('active', element.dataset.id === id));
    filterTabContent();
    renderTabs();
    requestAnimationFrame(() => { if (tab.outputCard?.isConnected) scrollLatest(true); else content.scrollTop = 0; });
  };

  closeTab = (id) => {
    const tab = tabs.get(id);
    if (!tab) return;
    if (tab.opened && !window.confirm('Close ' + tab.title + '? This ends the shell unless it is inside tmux or screen.')) return;
    if (tab.opened && ws && ws.readyState === WebSocket.OPEN) send({ type: 'close', terminalID: id });
    chat.querySelectorAll('[data-tab-id="' + id + '"]').forEach((element) => element.remove());
    document.querySelector('.stream[data-id="' + id + '"]')?.remove();
    tabs.delete(id);
    order = order.filter((value) => value !== id);
    if (active === id) active = order[0] || null;
    if (!active) createTab();
    if (active) selectTab(active);
    renderTabs();
  };

  const originalDashboardToggle = vampToggleDashboard;
  vampToggleDashboard = (force) => {
    originalDashboardToggle(force);
    const showing = !$('dashboard').classList.contains('hidden');
    context.classList.toggle('hidden', showing);
    shell.classList.toggle('dashboard-mode', showing);
    if (!showing) { filterTabContent(); resetPagePosition(); requestAnimationFrame(() => { if (active) selectTab(active); }); }
  };
  $('context-panel').onclick = () => vampToggleDashboard(true);
  $('context-more').onclick = () => { $('more-modal').classList.remove('hidden'); $('more-command').focus(); };
  $('context-branch').onclick = () => addExplore(active, 'Session routing · ' + (tabs.get(active)?.title || 'Terminal'));
  $('context-repo').onclick = () => addExplore(active, 'Connected to Vamp Host');

  resetPagePosition();
  filterTabContent();
})();
</script></body></html>
"""#
}
#endif
