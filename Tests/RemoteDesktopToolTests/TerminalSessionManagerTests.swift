import XCTest
@testable import ClientiOS
import SharedProtocol
import TransportWebRTC

@MainActor
final class TerminalSessionManagerTests: XCTestCase {
    func testReadyOutputCloseRoutingUsesSessionAndTerminalIDs() throws {
        let sessionID = UUID()
        let manager = ClientTerminalSessionManager()
        var sent: [DataChannelEnvelope] = []
        manager.activate(sessionID: sessionID) { sent.append($0) }
        manager.open(cols: 80, rows: 24)

        guard let terminalID = manager.terminalID else {
            return XCTFail("Opening a terminal should allocate a stable terminal ID")
        }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(try sent[0].decodeTerminalOpen().terminalID, terminalID)
        XCTAssertEqual(manager.state, .opening)

        manager.retryOpen(cols: 100, rows: 30)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(try sent[1].decodeTerminalOpen().terminalID, terminalID)
        XCTAssertEqual(try sent[1].decodeTerminalOpen().cols, 100)

        XCTAssertTrue(manager.receiveReady(TerminalReadyMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            cols: 80,
            rows: 24
        )))
        XCTAssertEqual(manager.state, .open)

        let wrongTerminal = TerminalOutputMessage(
            sessionID: sessionID,
            terminalID: UUID(),
            data: Data("ignored".utf8),
            sequence: 1
        )
        XCTAssertFalse(manager.receiveOutput(wrongTerminal))

        XCTAssertFalse(manager.receiveOutput(TerminalOutputMessage(
            sessionID: UUID(),
            terminalID: terminalID,
            data: Data("stale".utf8),
            sequence: 1
        )))

        let output = TerminalOutputMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            data: Data("background".utf8),
            sequence: 1
        )
        XCTAssertTrue(manager.receiveOutput(output))
        XCTAssertEqual(manager.output.last?.data, output.data)

        XCTAssertTrue(manager.receiveClose(TerminalCloseMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            reason: "user-closed"
        )))
        XCTAssertEqual(manager.state, .closed(exitCode: nil, signal: nil, reason: "user-closed"))
        XCTAssertNil(manager.terminalID)
    }

    func testStartupCommandSurvivesOpeningRetryWithStableTerminalID() throws {
        let sessionID = UUID()
        let manager = ClientTerminalSessionManager()
        var sent: [DataChannelEnvelope] = []
        manager.activate(sessionID: sessionID) { sent.append($0) }

        XCTAssertTrue(manager.open(
            cols: 100,
            rows: 32,
            startupCommand: "tmux new-session -A -s work"
        ))
        XCTAssertTrue(manager.retryOpen(cols: 100, rows: 32))

        let first = try sent[0].decodeTerminalOpen()
        let retry = try sent[1].decodeTerminalOpen()
        XCTAssertEqual(first.startupCommand, "tmux new-session -A -s work")
        XCTAssertEqual(retry.startupCommand, first.startupCommand)
        XCTAssertEqual(retry.terminalID, first.terminalID)
    }
}
