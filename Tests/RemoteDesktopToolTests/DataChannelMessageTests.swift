import XCTest
@testable import TransportWebRTC
@testable import SharedModels
@testable import SharedProtocol

final class DataChannelMessageTests: XCTestCase {

    // MARK: - Envelope Wire Encoding Round-Trip

    func testInputCommandRoundTrip() throws {
        let command = InputCommandMessage(
            sessionID: UUID(),
            command: .key(KeyCommand(keyCode: 36, action: .down))
        )
        let envelope = try DataChannelEnvelope.inputCommand(command)
        XCTAssertEqual(envelope.kind, .inputCommand)
        XCTAssertEqual(envelope.sessionID, command.sessionID)

        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        XCTAssertEqual(decoded.kind, .inputCommand)
        XCTAssertEqual(decoded.sessionID, command.sessionID)

        let decodedCommand = try decoded.decodeInputCommand()
        XCTAssertEqual(decodedCommand.sessionID, command.sessionID)
        XCTAssertEqual(decodedCommand.command, command.command)
    }

    func testPingRoundTrip() throws {
        let ping = PingMessage(id: UUID(), sentAt: Date(timeIntervalSince1970: 1000))
        let envelope = try DataChannelEnvelope.ping(ping)
        XCTAssertEqual(envelope.kind, .ping)

        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        let decodedPing = try decoded.decodePing()
        XCTAssertEqual(decodedPing.id, ping.id)
    }

    func testPongRoundTrip() throws {
        let pong = PongMessage(id: UUID(), sentAt: Date(timeIntervalSince1970: 1000), receivedAt: Date(timeIntervalSince1970: 1001))
        let envelope = try DataChannelEnvelope.pong(pong)
        XCTAssertEqual(envelope.kind, .pong)

        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        let decodedPong = try decoded.decodePong()
        XCTAssertEqual(decodedPong.id, pong.id)
    }

    func testMultiTerminalMessagesRoundTrip() throws {
        let sessionID = UUID()
        let terminalID = UUID()
        let ready = TerminalReadyMessage(sessionID: sessionID, terminalID: terminalID, cols: 120, rows: 40)
        let output = TerminalOutputMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            data: Data("hello".utf8),
            sequence: 7
        )
        let resize = TerminalResizeMessage(sessionID: sessionID, terminalID: terminalID, cols: 100, rows: 30)
        let close = TerminalCloseMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            exitCode: 0,
            reason: "shell-exited"
        )

        let readyDecoded = try DataChannelEnvelope.wireDecode(
            try DataChannelEnvelope.terminalReady(ready).wireEncode()
        ).decodeTerminalReady()
        let outputDecoded = try DataChannelEnvelope.wireDecode(
            try DataChannelEnvelope.terminalOutput(output).wireEncode()
        ).decodeTerminalOutput()
        let resizeDecoded = try DataChannelEnvelope.wireDecode(
            try DataChannelEnvelope.terminalResize(resize).wireEncode()
        ).decodeTerminalResize()
        let closeDecoded = try DataChannelEnvelope.wireDecode(
            try DataChannelEnvelope.terminalClose(close).wireEncode()
        ).decodeTerminalClose()

        XCTAssertEqual(readyDecoded, ready)
        XCTAssertEqual(outputDecoded, output)
        XCTAssertEqual(resizeDecoded, resize)
        XCTAssertEqual(closeDecoded, close)
    }

    func testHostStatusRoundTrip() throws {
        let status = HostStatusMessage(
            hostID: UUID(),
            connectionState: .connected,
            activeSessionID: UUID()
        )
        let envelope = try DataChannelEnvelope.hostStatus(status)
        XCTAssertEqual(envelope.kind, .hostStatus)

        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        let decodedStatus = try decoded.decodeHostStatus()
        XCTAssertEqual(decodedStatus.hostID, status.hostID)
        XCTAssertEqual(decodedStatus.connectionState, .connected)
        XCTAssertEqual(decodedStatus.activeSessionID, status.activeSessionID)
    }

    func testDisplayLayoutRoundTrip() throws {
        let display = DisplayDescriptor(
            id: "main",
            name: "Built-in",
            frame: DesktopRect(origin: .zero, size: DesktopSize(width: 1440, height: 900)),
            pixelSize: DesktopSize(width: 2880, height: 1800),
            scaleFactor: 2,
            refreshRate: 60,
            isPrimary: true
        )
        let layout = DisplayLayout.computed(from: [display])
        let message = DisplayLayoutMessage(layout: layout)
        let envelope = try DataChannelEnvelope.displayLayout(message)
        XCTAssertEqual(envelope.kind, .displayLayout)

        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        let decodedLayout = try decoded.decodeDisplayLayout()
        XCTAssertEqual(decodedLayout.layout.displays.count, 1)
        XCTAssertEqual(decodedLayout.layout.displays.first?.id, "main")
    }

    func testDisplayConfigurationChangedRoundTrip() throws {
        let display = DisplayDescriptor(
            id: "main",
            name: "Built-in",
            frame: DesktopRect(origin: .zero, size: DesktopSize(width: 1440, height: 900)),
            pixelSize: DesktopSize(width: 2880, height: 1800),
            scaleFactor: 2,
            isPrimary: true
        )
        let layout = DisplayLayout.computed(from: [display])
        let configuration = DisplayStreamConfiguration(
            display: display,
            streamWidth: 1920,
            streamHeight: 1200
        )
        let message = DisplayConfigurationChangedMessage(
            sessionID: UUID(),
            configuration: configuration,
            layout: layout,
            reason: "initial"
        )
        let envelope = try DataChannelEnvelope.displayConfigurationChanged(message)
        XCTAssertEqual(envelope.kind, .displayConfigurationChanged)
        XCTAssertEqual(envelope.sessionID, message.sessionID)

        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        let decodedMessage = try decoded.decodeDisplayConfigurationChanged()
        XCTAssertEqual(decodedMessage.configuration.displayID, "main")
        XCTAssertEqual(decodedMessage.configuration.streamWidth, 1920)
        XCTAssertEqual(decodedMessage.configuration.streamHeight, 1200)
        XCTAssertEqual(decodedMessage.reason, "initial")
    }

    func testCursorStateRoundTrip() throws {
        let cursor = CursorStateMessage(
            displayID: "main",
            position: DesktopPoint(x: 100.5, y: 200.5),
            isVisible: true
        )
        let envelope = try DataChannelEnvelope.cursorState(cursor)
        XCTAssertEqual(envelope.kind, .cursorState)

        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        let decodedCursor = try decoded.decodeCursorState()
        XCTAssertEqual(decodedCursor.displayID, "main")
        XCTAssertEqual(decodedCursor.position.x, 100.5)
        XCTAssertEqual(decodedCursor.position.y, 200.5)
        XCTAssertTrue(decodedCursor.isVisible)
    }

    func testErrorRoundTrip() throws {
        let error = ErrorMessage(code: "CAPTURE_FAIL", message: "Screen recording denied", isRecoverable: true)
        let envelope = try DataChannelEnvelope.error(error)
        XCTAssertEqual(envelope.kind, .error)

        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        let decodedError = try decoded.decodeError()
        XCTAssertEqual(decodedError.code, "CAPTURE_FAIL")
        XCTAssertEqual(decodedError.message, "Screen recording denied")
        XCTAssertTrue(decodedError.isRecoverable)
    }

    // MARK: - Message Kind

    func testAllMessageKindsHaveRawValues() {
        let allKinds: [DataChannelMessageKind] = [
            .controlAuth, .inputCommand, .ping, .pong, .hostStatus, .displayLayout,
            .displayConfigurationChanged, .displaySwitch, .cursorState, .chatMessage,
            .fileTransfer, .error, .qualityAdjust, .setActiveDisplays, .requestKeyframe,
            .unlockPassword, .audioFrame, .clipboardSync, .clipboardRequest,
            .terminalOpen, .terminalReady, .terminalInput, .terminalOutput,
            .terminalResize, .terminalClose
        ]
        for kind in allKinds {
            XCTAssertFalse(kind.rawValue.isEmpty, "\(kind) should have non-empty raw value")
        }
    }

    func testStateChangingControlKindsRequireAuthentication() {
        let authenticated: Set<DataChannelMessageKind> = [
            .inputCommand, .chatMessage, .qualityAdjust, .fileTransfer,
            .displaySwitch, .setActiveDisplays, .requestKeyframe,
            .unlockPassword, .clipboardSync, .clipboardRequest,
            .terminalOpen, .terminalReady, .terminalInput, .terminalOutput,
            .terminalResize, .terminalClose
        ]
        let allKinds: [DataChannelMessageKind] = [
            .controlAuth, .inputCommand, .ping, .pong, .hostStatus, .displayLayout,
            .displayConfigurationChanged, .displaySwitch, .cursorState, .chatMessage,
            .fileTransfer, .error, .qualityAdjust, .setActiveDisplays, .requestKeyframe,
            .unlockPassword, .audioFrame, .clipboardSync, .clipboardRequest,
            .terminalOpen, .terminalReady, .terminalInput, .terminalOutput,
            .terminalResize, .terminalClose
        ]
        for kind in allKinds {
            XCTAssertEqual(kind.requiresControlChannelAuthentication, authenticated.contains(kind), "Unexpected auth contract for \(kind)")
        }
    }

    func testMessageKindCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for kind in [
            DataChannelMessageKind.controlAuth, .inputCommand, .ping, .pong, .hostStatus,
            .displayLayout, .displayConfigurationChanged, .displaySwitch, .cursorState,
            .chatMessage, .error, .qualityAdjust, .setActiveDisplays, .requestKeyframe,
            .unlockPassword, .audioFrame, .clipboardSync, .clipboardRequest,
            .terminalOpen, .terminalReady, .terminalInput, .terminalOutput,
            .terminalResize, .terminalClose
        ] {
            let data = try encoder.encode(kind)
            let decoded = try decoder.decode(DataChannelMessageKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func testChatMessageRoundTrip() throws {
        let chat = SessionChatMessage(
            sessionID: UUID(),
            senderID: UUID(),
            senderDisplayName: "Mac Client",
            senderRole: .client,
            text: "Can you see this?"
        )
        let envelope = try DataChannelEnvelope.chatMessage(chat)
        XCTAssertEqual(envelope.kind, .chatMessage)
        XCTAssertEqual(envelope.sessionID, chat.sessionID)

        let decoded = try DataChannelEnvelope.wireDecode(try envelope.wireEncode())
        XCTAssertEqual(try decoded.decodeChatMessage(), chat)
    }

    // MARK: - Pointer Move Command Round-Trip

    func testPointerMoveInputRoundTrip() throws {
        let command = InputCommandMessage(
            sessionID: UUID(),
            command: .pointerMove(PointerMoveCommand(
                location: DesktopPoint(x: 500, y: 300),
                displayID: "main"
            ))
        )
        let envelope = try DataChannelEnvelope.inputCommand(command)
        let wireData = try envelope.wireEncode()
        let decoded = try DataChannelEnvelope.wireDecode(wireData)
        let decodedCommand = try decoded.decodeInputCommand()

        if case .pointerMove(let move) = decodedCommand.command {
            XCTAssertEqual(move.location.x, 500)
            XCTAssertEqual(move.location.y, 300)
            XCTAssertEqual(move.displayID, "main")
        } else {
            XCTFail("Expected pointer move command")
        }
    }

    func testTerminalOpenRoundTripPreservesStartupCommand() throws {
        let message = TerminalOpenMessage(
            sessionID: UUID(),
            terminalID: UUID(),
            cols: 120,
            rows: 40,
            startupCommand: "tmux new-session -A -s agent"
        )
        let envelope = try DataChannelEnvelope.terminalOpen(message)
        let decoded = try DataChannelEnvelope.wireDecode(try envelope.wireEncode())

        XCTAssertEqual(try decoded.decodeTerminalOpen(), message)
    }
}
