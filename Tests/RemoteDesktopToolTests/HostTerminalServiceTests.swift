#if os(macOS)
import XCTest
@testable import HostApp
import SharedProtocol
import TransportWebRTC

final class HostTerminalServiceTests: XCTestCase {
    func testBrowserPairingCodeAcceptsFormattedAndLocalizedDigits() {
        XCTAssertEqual(HostBrowserPairingCode.normalize(" 12-34·56 "), "123456")
        XCTAssertEqual(HostBrowserPairingCode.normalize("١٢٣٤٥٦"), "123456")
        XCTAssertEqual(HostBrowserPairingCode.normalize("\u{200E}123456\u{2069}"), "123456")
        XCTAssertNil(HostBrowserPairingCode.normalize("12345"))
        XCTAssertNil(HostBrowserPairingCode.normalize("12a456"))
    }

    func testBrowserPairingCodeExpiryUsesTheExactLifetimeBoundary() {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(HostBrowserPairingCode.isExpired(
            issuedAt: issuedAt,
            at: Date(timeIntervalSince1970: 1_599),
            lifetime: 600
        ))
        XCTAssertTrue(HostBrowserPairingCode.isExpired(
            issuedAt: issuedAt,
            at: Date(timeIntervalSince1970: 1_600),
            lifetime: 600
        ))
    }

    func testBrowserPairingLinkReplacesPairCodeWithoutDroppingOtherQueryItems() {
        let link = HostBrowserPairingLink.make(
            baseURL: "https://mac.example.test/workspace?source=qr&pair=000000",
            code: "12 34-56"
        )

        XCTAssertEqual(link, "https://mac.example.test/workspace?source=qr&pair=123456")
    }

    func testBrowserPairingLinkRejectsInvalidCodeAndHostURL() {
        XCTAssertNil(HostBrowserPairingLink.make(baseURL: "127.0.0.1:9475", code: "123456"))
        XCTAssertNil(HostBrowserPairingLink.make(baseURL: "http://127.0.0.1:9475", code: "12345"))
    }

    func testBrowserPairingCompletesHTTPTokenExchangeAndWebSocketHandshake() async throws {
        let service = HostBrowserControlService()
        service.terminalModeProvider = { true }
        let port: UInt16 = 19075
        service.start(port: port)
        defer { service.stop() }

        let deadline = Date().addingTimeInterval(3)
        var status = service.currentStatus()
        while !status.running && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
            status = service.currentStatus()
        }
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.port, port)
        XCTAssertFalse(status.pairingCode.isEmpty)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/pair?pair=\(status.pairingCode)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Exercise the QR fallback: the URL carries the valid code while a
        // browser/proxy may omit or corrupt the small JSON body.
        request.httpBody = Data("{\"code\":\"00000\"}".utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        struct PairResponse: Decodable { let token: String }
        let firstToken = try JSONDecoder().decode(PairResponse.self, from: body).token

        // Keep the first browser session alive while pairing again. This is
        // the race that previously made a valid QR/manual code appear broken:
        // the second HTTP exchange succeeded, but its WebSocket was rejected
        // because the old socket still occupied the single browser slot.
        let firstSocket = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/socket?token=\(firstToken)")!
        )
        firstSocket.resume()
        _ = try await firstSocket.receive()

        var manualRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/pair")!)
        manualRequest.httpMethod = "POST"
        manualRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        manualRequest.httpBody = Data("{\"code\":\"\(status.pairingCode)\"}".utf8)
        let (manualBody, manualResponse) = try await URLSession.shared.data(for: manualRequest)
        XCTAssertEqual((manualResponse as? HTTPURLResponse)?.statusCode, 200)
        let token = try JSONDecoder().decode(PairResponse.self, from: manualBody).token

        let socket = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(port)/socket?token=\(token)")!
        )
        socket.resume()
        let hello = try await socket.receive()
        guard case let .string(helloJSON) = hello,
              let helloData = helloJSON.data(using: .utf8) else {
            XCTFail("Expected a JSON hello message")
            return
        }
        struct HelloMessage: Decodable {
            let maxTerminals: Int
            let capabilities: [String]
        }
        let helloMessage = try JSONDecoder().decode(HelloMessage.self, from: helloData)
        XCTAssertEqual(helloMessage.maxTerminals, HostTerminalService.maxActiveTerminals)
        XCTAssertTrue(helloMessage.capabilities.contains("multiple-terminals"))
        firstSocket.cancel(with: .goingAway, reason: nil)
        socket.cancel(with: .goingAway, reason: nil)
    }

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

    func testSemanticTaskPlanEventsRouteOnlyToTheMatchingTerminalSession() throws {
        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let terminalID = UUID()
        service.handleOpen(TerminalOpenMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            cols: 80,
            rows: 24
        ))

        _ = try waitFor(recorder) { readyIDs(in: $0).contains(terminalID) }

        let first = SessionTask(order: 1, title: "Audit the terminal")
        let second = SessionTask(order: 2, title: "Run regression tests")
        let plan = SessionTaskPlan(
            sessionID: sessionID,
            terminalID: terminalID,
            title: "Work plan",
            tasks: [first, second],
            source: .native
        )
        service.publishTaskPlanEvent(SessionTaskEventMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            event: .planCreated(plan)
        ))
        // A stale session must not be able to mutate this terminal's plan.
        service.publishTaskPlanEvent(SessionTaskEventMessage(
            sessionID: UUID(),
            terminalID: terminalID,
            event: .taskStarted(first.id)
        ))
        service.publishTaskPlanEvent(SessionTaskEventMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            event: .planUpdated(SessionTaskPlan(
                sessionID: UUID(),
                terminalID: terminalID,
                title: "Wrong session",
                tasks: [first, second],
                source: .native
            ))
        ))

        let events = try waitFor(recorder) { envelopes in
            envelopes.contains { envelope in
                guard envelope.kind == .taskPlanEvent,
                      let message = try? envelope.decodeTaskPlanEvent() else { return false }
                if case .planCreated(let received) = message.event {
                    return message.sessionID == sessionID
                        && message.terminalID == terminalID
                        && received.tasks.map(\.id) == [first.id, second.id]
                }
                return false
            }
        }
        let taskPlanEvents = events.filter { $0.kind == .taskPlanEvent }
        XCTAssertEqual(taskPlanEvents.count, 1)
    }

    func testSemanticTaskPlanFallbackRequiresStrongPlanSyntax() throws {
        let service = HostTerminalService()
        let recorder = EnvelopeRecorder()
        service.sendEnvelope = { recorder.append($0) }
        defer { service.sessionDidEnd() }

        let sessionID = UUID()
        let terminalID = UUID()
        service.handleOpen(TerminalOpenMessage(sessionID: sessionID, terminalID: terminalID, cols: 80, rows: 24))
        _ = try waitFor(recorder) { readyIDs(in: $0).contains(terminalID) }

        service.consumeSemanticAgentOutput(
            "1. One paragraph\n2. Another paragraph",
            sessionID: sessionID,
            terminalID: terminalID
        )
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertFalse(recorder.snapshot().contains { $0.kind == .taskPlanEvent })

        service.consumeSemanticAgentOutput(
            "Implementation plan:\n1. Audit the terminal\n2. Run regression tests",
            sessionID: sessionID,
            terminalID: terminalID
        )
        _ = try waitFor(recorder) { envelopes in
            envelopes.contains { envelope in
                guard envelope.kind == .taskPlanEvent,
                      let message = try? envelope.decodeTaskPlanEvent() else { return false }
                if case .planCreated(let plan) = message.event {
                    return plan.source == .inferred && plan.tasks.count == 2
                }
                return false
            }
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
