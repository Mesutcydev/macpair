import XCTest
@testable import ClientiOS
import SharedProtocol

@MainActor
final class TerminalWorkspaceTests: XCTestCase {
    func testChatSubmissionIsCanonicalAndRawOutputNeverBecomesChatText() {
        let chat = TerminalChatStore(tabTitle: "Build")

        XCTAssertEqual(chat.blocks.first?.text, "Build is opening a shell…")
        chat.recordChatSubmission("echo café", provider: nil)
        chat.appendOutput(Data("running build…\n✓ clean\n".utf8))
        chat.appendOutput(Data("\u{1B}[32m✓ verified\u{1B}[0m\r".utf8))

        XCTAssertTrue(chat.blocks.contains {
            $0.role == .command && $0.title == "You · Shell" && $0.text == "$ echo café"
        })
        XCTAssertFalse(chat.blocks.contains { $0.text.contains("running build") || $0.text.contains("verified") })
        XCTAssertFalse(chat.blocks.contains { $0.text.contains("38;5") || $0.text.contains("\u{1B}") })
    }

    func testChatSubmissionPreservesSubmittedWhitespaceAndAgentIdentity() {
        let chat = TerminalChatStore(tabTitle: "Grok")
        let submitted = "  keep this spacing  "

        chat.recordChatSubmission(submitted, provider: .grok)

        XCTAssertTrue(chat.blocks.contains {
            $0.role == .command && $0.title == "You · Grok" && $0.text == submitted
        })
    }

    func testChatReadyAndCloseCardsAreIdempotentAndRetryIsVisible() {
        let chat = TerminalChatStore(tabTitle: "Terminal 1")

        chat.markReady()
        chat.markReady()
        XCTAssertEqual(chat.blocks.filter { $0.text == "Terminal 1 is connected." }.count, 0)
        XCTAssertEqual(chat.activityEvents.filter { $0.text == "PTY ready" }.count, 1)

        chat.markClosed(reason: "terminal-start-timeout")
        chat.markClosed(reason: "terminal-start-timeout")
        XCTAssertEqual(chat.blocks.filter { $0.role == .error }.count, 1)

        chat.prepareForRetry()
        XCTAssertTrue(chat.blocks.contains { $0.text == "Terminal 1 is trying again…" && $0.isStreaming })
        chat.markReady()
        XCTAssertEqual(chat.activityEvents.filter { $0.text == "PTY ready" }.count, 2)
    }

    func testRawInputAndOutputDoNotBecomeChatText() {
        let chat = TerminalChatStore(tabTitle: "Terminal 1")
        chat.markReady()
        chat.recordInput(Data("echo ready\n".utf8))
        chat.appendOutput(Data("%\n~❯\n❯ echo ready\nready\n%\n~❯ ".utf8))

        XCTAssertFalse(chat.blocks.contains { $0.role == .command })
        XCTAssertFalse(chat.blocks.contains { $0.role == .output })
        XCTAssertTrue(chat.activityEvents.contains { $0.text.contains("bytes") })
    }

    func testChatDoesNotAttemptToRenderTUIRepaintOutput() {
        let chat = TerminalChatStore(tabTitle: "OpenCode")
        chat.markReady()
        chat.recordInput(Data("opencode\n".utf8))

        let repaint = Array(repeating: "\u{1B}(B\u{1B}[2K\u{1B}(B" + String(repeating: " ", count: 180) + "OpenCode", count: 120)
            .joined(separator: "\n")
        chat.appendOutput(Data(repaint.utf8))

        XCTAssertFalse(chat.blocks.contains { $0.role == .output })
        XCTAssertFalse(chat.blocks.contains { $0.text.contains("OpenCode") })
        XCTAssertTrue(chat.activityEvents.contains { $0.text.contains("bytes") })
    }

    func testTabsKeepStableIdentityAndRenameCloseImmediately() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Workspace Test")
        let workspace = TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        workspace.activate(sessionID: UUID())

        XCTAssertEqual(workspace.tabs.count, 1)
        let firstID = workspace.tabs[0].id
        XCTAssertTrue(workspace.createTab())
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.tabs[0].id, firstID)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[1].id)

        workspace.rename(tabID: firstID, title: "Build")
        XCTAssertEqual(workspace.tabs.first?.title, "Build")

        workspace.close(tabID: firstID)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.tabs.first?.id, firstID)
    }

    func testBackgroundOutputMarksOnlyTheInactiveTabUnread() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Unread Test")
        let workspace = TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        workspace.activate(sessionID: UUID())
        XCTAssertTrue(workspace.createTab())

        let first = workspace.tabs[0]
        let second = workspace.tabs[1]
        workspace.select(tabID: second.id)
        XCTAssertEqual(workspace.selectedTabID, second.id)

        guard let terminalID = first.session.terminalID,
              let sessionID = workspace.activeSessionID else {
            return XCTFail("Test tabs should have active terminal IDs")
        }
        environment.sessionCoordinator.onTerminalOutput?(TerminalOutputMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            data: Data("while away".utf8),
            sequence: 1
        ))

        XCTAssertTrue(workspace.tabs[0].hasUnreadOutput)
        XCTAssertFalse(workspace.tabs[1].hasUnreadOutput)
        workspace.select(tabID: first.id)
        XCTAssertFalse(workspace.tabs[0].hasUnreadOutput)
    }

    func testWorkspaceStopsAtEightStableTabs() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Capacity Test")
        let workspace = TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        workspace.activate(sessionID: UUID())

        for _ in 1..<TerminalWorkspaceViewModel.maxTabs {
            XCTAssertTrue(workspace.createTab())
        }

        XCTAssertEqual(workspace.tabs.count, TerminalWorkspaceViewModel.maxTabs)
        XCTAssertEqual(workspace.tabCountLabel, "8/8")
        XCTAssertFalse(workspace.createTab())
    }

    func testDefaultTabNamesStayUniqueAfterClosingAndCreatingTabs() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Tab Naming Test")
        let workspace = TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        workspace.activate(sessionID: UUID())
        XCTAssertTrue(workspace.createTab())

        let firstID = workspace.tabs[0].id
        let originalNames = Set(workspace.tabs.map(\.title))
        XCTAssertEqual(originalNames, ["Terminal 1", "Terminal 2"])

        workspace.close(tabID: firstID)
        XCTAssertTrue(workspace.createTab())

        let names = workspace.tabs.map(\.title)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(Set(names), ["Terminal 1", "Terminal 2"])
    }
}
