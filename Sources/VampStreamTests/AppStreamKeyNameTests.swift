import XCTest
@testable import Vamp_Stream

/// The keyboard decks emit Mac virtual keycodes; Vamp Assistant's HTTP input protocol takes
/// key *names*. Every shortcut on the decks used to fall through to "keyNN" and be dropped.
final class AppStreamKeyNameTests: XCTestCase {

    func testShortcutKeycodesResolveToCharacterNames() {
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 8), "c")   // ⌘C / ⌃C
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 9), "v")   // ⌘V
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 0), "a")   // ⌘A
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 6), "z")   // ⌘Z
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 37), "l")  // ⌃L
        XCTAssertEqual(AppStreamKeyboardOverlayView.character(forKeyCode: 20), "3")  // ⌘⇧3
    }

    func testNamedKeysAreNotCharacters() {
        // Return/Tab/Escape/arrows are named separately and must not collide with the table.
        for keyCode: UInt16 in [36, 53, 123, 124, 125, 126, 115, 119, 116, 121] {
            XCTAssertNil(AppStreamKeyboardOverlayView.character(forKeyCode: keyCode),
                         "keycode \(keyCode) must stay a named key")
        }
    }

    func testAssistantSpecialKeysMatchMacClientWireNames() {
        XCTAssertEqual(AssistantInputKeyName.name(for: 36), "return")
        XCTAssertEqual(AssistantInputKeyName.name(for: 76), "return")
        XCTAssertEqual(AssistantInputKeyName.name(for: 48), "tab")
        XCTAssertEqual(AssistantInputKeyName.name(for: 51), "backspace")
        XCTAssertEqual(AssistantInputKeyName.name(for: 53), "escape")
        XCTAssertEqual(AssistantInputKeyName.name(for: 117), "forward_delete")
        XCTAssertEqual(AssistantInputKeyName.name(for: 123), "left")
        XCTAssertEqual(AssistantInputKeyName.name(for: 124), "right")
        XCTAssertEqual(AssistantInputKeyName.name(for: 125), "down")
        XCTAssertEqual(AssistantInputKeyName.name(for: 126), "up")
        XCTAssertEqual(AssistantInputKeyName.name(for: 115), "home")
        XCTAssertEqual(AssistantInputKeyName.name(for: 119), "end")
        XCTAssertEqual(AssistantInputKeyName.name(for: 116), "page_up")
        XCTAssertEqual(AssistantInputKeyName.name(for: 121), "page_down")
    }

    func testTerminalDeckExtrasUseLowerSnakeCase() {
        // Not in MacAssistantKeyMapping; the Mac client types a space character instead.
        XCTAssertEqual(AssistantInputKeyName.name(for: 49), "space")
        XCTAssertEqual(AssistantInputKeyName.name(for: 122), "f1")
        XCTAssertEqual(AssistantInputKeyName.name(for: 120), "f2")
        XCTAssertEqual(AssistantInputKeyName.name(for: 99), "f3")
        XCTAssertEqual(AssistantInputKeyName.name(for: 118), "f4")
    }
}
