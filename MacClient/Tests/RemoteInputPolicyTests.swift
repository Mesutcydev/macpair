import AppKit
import SharedModels
import SharedUtilities
import XCTest

final class RemoteInputPolicyTests: XCTestCase {
    func testDisplayModeMenuExposesFitDisplayAsFirstClassOption() {
        let titles = DisplayMappingEngine.DisplayMode.allCases.map(\.title)
        XCTAssertTrue(titles.contains("Fit Display"))
        XCTAssertTrue(titles.contains("Fill Screen"))
        XCTAssertTrue(titles.contains("Actual Size"))
        XCTAssertEqual(DisplayMappingEngine.DisplayMode.fitDisplay.title, "Fit Display")
    }

    func testControlPrimaryClickTranslatesToSecondaryClick() {
        XCTAssertEqual(RemotePrimaryClickTranslation.button(controlPressed: false), MouseButton.left)
        XCTAssertEqual(RemotePrimaryClickTranslation.button(controlPressed: true), MouseButton.right)
    }

    // MARK: - Key equivalents

    func testDisconnectShortcutStaysLocal() {
        // Regression: the old predicate bailed out whenever Shift was held, so
        // ⇧⌘D was forwarded to the host and never left the session.
        XCTAssertTrue(RemoteKeyEquivalentPolicy.staysLocal(characters: "D", modifiers: [.command, .shift]))
        XCTAssertTrue(RemoteKeyEquivalentPolicy.staysLocal(characters: "d", modifiers: [.command, .shift]))
    }

    func testViewMenuDisplayShortcutsStayLocal() {
        for key in ["0", "1", "2"] {
            XCTAssertTrue(
                RemoteKeyEquivalentPolicy.staysLocal(characters: key, modifiers: [.command]),
                "⌘\(key) is bound in the View menu and must not go to the host"
            )
        }
    }

    func testApplicationMenuShortcutsStayLocal() {
        for key in ["q", "m", "h", ",", "r"] {
            XCTAssertTrue(RemoteKeyEquivalentPolicy.staysLocal(characters: key, modifiers: [.command]))
        }
    }

    func testEverythingElseGoesToTheHost() {
        // The point of a remote-desktop client: the remote Mac gets the shortcut.
        for key in ["c", "v", "s", "t", "w", "a", "z"] {
            XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: key, modifiers: [.command]))
        }
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "d", modifiers: [.command]))
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "q", modifiers: [.command, .shift]))
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "r", modifiers: []))
    }

    func testControlOptionCombinationsAreNeverOurs() {
        // Session actions use ⌃⌥ precisely so they do not take ⌘ keys from the host.
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "0", modifiers: [.command, .option]))
        XCTAssertFalse(RemoteKeyEquivalentPolicy.staysLocal(characters: "q", modifiers: [.command, .control]))
    }
}
