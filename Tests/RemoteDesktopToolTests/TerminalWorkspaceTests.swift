import XCTest
@testable import ClientiOS
import SharedProtocol

@MainActor
final class TerminalWorkspaceTests: XCTestCase {
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
