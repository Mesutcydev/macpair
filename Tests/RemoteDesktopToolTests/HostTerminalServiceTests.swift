#if os(macOS)
import XCTest
@testable import HostApp
import SharedProtocol
import TransportWebRTC

final class HostTerminalServiceTests: XCTestCase {
    func testIndependentTerminalsCanResizeInterleaveOutputAndCloseOne() throws {
        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        service.handleOpen(TerminalOpenMessage(sessionID: sessionID, terminalID: firstID, cols: 80, rows: 24))
        service.handleOpen(TerminalOpenMessage(sessionID: sessionID, terminalID: secondID, cols: 100, rows: 30))

        let ready = try waitFor(recorder) { envelopes in
            readyIDs(in: envelopes).isSuperset(of: [firstID, secondID])
        }
        let readyMessages = try ready.compactMap { envelope -> TerminalReadyMessage? in
            guard envelope.kind == .terminalReady else { return nil }
            return try envelope.decodeTerminalReady()
        }
        XCTAssertEqual(Set(readyMessages.map(\.terminalID)), [firstID, secondID])
        XCTAssertEqual(readyMessages.first(where: { $0.terminalID == firstID })?.cols, 80)
        XCTAssertEqual(readyMessages.first(where: { $0.terminalID == secondID })?.rows, 30)

        // Verify that resize is applied to one PTY only: `stty size` reports rows first.
        service.handleResize(TerminalResizeMessage(
            sessionID: sessionID,
            terminalID: firstID,
            cols: 120,
            rows: 42
        ))
        service.handleInput(TerminalInputMessage(
            sessionID: sessionID,
            terminalID: firstID,
            data: Data("stty size\n".utf8)
        ))
        service.handleInput(TerminalInputMessage(
            sessionID: sessionID,
            terminalID: secondID,
            data: Data("printf 'vamp-second-alive\\n'\n".utf8)
        ))

        let output = try waitFor(recorder) { envelopes in
            outputText(for: firstID, in: envelopes).contains("42 120")
                && outputText(for: secondID, in: envelopes).contains("vamp-second-alive")
        }
        let outputTerminalIDs = Set(output.compactMap { envelope -> UUID? in
            guard envelope.kind == .terminalOutput,
                  let message = try? envelope.decodeTerminalOutput() else { return nil }
            return message.terminalID
        })
        XCTAssertTrue(outputTerminalIDs.contains(firstID))
        XCTAssertTrue(outputTerminalIDs.contains(secondID))

        // Closing the first terminal must not tear down the second one.
        service.handleClose(TerminalCloseMessage(
            sessionID: sessionID,
            terminalID: firstID,
            reason: "user-closed"
        ))
        service.handleInput(TerminalInputMessage(
            sessionID: sessionID,
            terminalID: secondID,
            data: Data("printf 'vamp-second-still-open\\n'\n".utf8)
        ))
        _ = try waitFor(recorder) { envelopes in
            outputText(for: secondID, in: envelopes).contains("vamp-second-still-open")
        }
    }

    func testEightTerminalLimitAndSessionCleanup() throws {
        XCTAssertEqual(HostTerminalService.maxActiveTerminals, 8)

        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let terminalIDs = (0..<HostTerminalService.maxActiveTerminals).map { _ in UUID() }
        for terminalID in terminalIDs {
            service.handleOpen(TerminalOpenMessage(
                sessionID: sessionID,
                terminalID: terminalID,
                cols: 80,
                rows: 24
            ))
        }

        _ = try waitFor(recorder) { envelopes in
            readyIDs(in: envelopes) == Set(terminalIDs)
        }

        let rejectedID = UUID()
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionID,
            terminalID: rejectedID,
            cols: 80,
            rows: 24
        ))
        _ = try waitFor(recorder) { envelopes in
            envelopes.contains { envelope in
                guard envelope.kind == .terminalClose,
                      let message = try? envelope.decodeTerminalClose() else { return false }
                return message.terminalID == rejectedID && message.reason == "terminal-capacity"
            }
        }

        // Session teardown removes every active PTY, allowing a fresh terminal
        // to open without relying on shell exit timing.
        service.sessionDidEnd()
        let replacementID = UUID()
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionID,
            terminalID: replacementID,
            cols: 80,
            rows: 24
        ))
        _ = try waitFor(recorder) { envelopes in
            readyIDs(in: envelopes).contains(replacementID)
        }
    }

    func testTerminalDisablementClosesEveryActiveTerminalWithReason() throws {
        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let terminalIDs = [UUID(), UUID()]
        for terminalID in terminalIDs {
            service.handleOpen(TerminalOpenMessage(
                sessionID: sessionID,
                terminalID: terminalID,
                cols: 80,
                rows: 24
            ))
        }

        _ = try waitFor(recorder) { envelopes in
            readyIDs(in: envelopes) == Set(terminalIDs)
        }

        service.sessionDidEnd(notifyClient: true, reason: "terminal-disabled")
        _ = try waitFor(recorder) { envelopes in
            let disabledIDs = Set(envelopes.compactMap { envelope -> UUID? in
                guard envelope.kind == .terminalClose,
                      let message = try? envelope.decodeTerminalClose(),
                      message.reason == "terminal-disabled" else { return nil }
                return message.terminalID
            })
            return disabledIDs == Set(terminalIDs)
        }
    }

    private func waitFor(
        _ recorder: EnvelopeRecorder,
        timeout: TimeInterval = 8,
        condition: ([DataChannelEnvelope]) -> Bool
    ) throws -> [DataChannelEnvelope] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = recorder.snapshot()
            if condition(snapshot) { return snapshot }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Condition was not satisfied within \(timeout) seconds")
        throw NSError(domain: "HostTerminalServiceTests", code: 1)
    }

    private func readyIDs(in envelopes: [DataChannelEnvelope]) -> Set<UUID> {
        Set(envelopes.compactMap { envelope in
            guard envelope.kind == .terminalReady,
                  let message = try? envelope.decodeTerminalReady() else { return nil }
            return message.terminalID
        })
    }

    private func outputText(for terminalID: UUID, in envelopes: [DataChannelEnvelope]) -> String {
        envelopes.compactMap { envelope in
            guard envelope.kind == .terminalOutput,
                  let message = try? envelope.decodeTerminalOutput(),
                  message.terminalID == terminalID else { return nil }
            return String(decoding: message.data, as: UTF8.self)
        }.joined()
    }

    private final class EnvelopeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var envelopes: [DataChannelEnvelope] = []

        func append(_ envelope: DataChannelEnvelope) {
            lock.lock()
            envelopes.append(envelope)
            lock.unlock()
        }

        func snapshot() -> [DataChannelEnvelope] {
            lock.lock()
            defer { lock.unlock() }
            return envelopes
        }
    }
}
#endif
