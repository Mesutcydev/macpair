import XCTest

final class MacAssistantKeyMappingTests: XCTestCase {
    func testArrowKeysUseAssistantWireNames() {
        XCTAssertEqual(MacAssistantKeyMapping.name(for: 123), "left")
        XCTAssertEqual(MacAssistantKeyMapping.name(for: 124), "right")
        XCTAssertEqual(MacAssistantKeyMapping.name(for: 125), "down")
        XCTAssertEqual(MacAssistantKeyMapping.name(for: 126), "up")
    }

    func testNavigationKeysUseAssistantWireNames() {
        XCTAssertEqual(MacAssistantKeyMapping.name(for: 117), "forward_delete")
        XCTAssertEqual(MacAssistantKeyMapping.name(for: 116), "page_up")
        XCTAssertEqual(MacAssistantKeyMapping.name(for: 121), "page_down")
    }

    func testUnknownKeyCodeIsNotForwardedAsNamedKey() {
        XCTAssertNil(MacAssistantKeyMapping.name(for: 0))
    }

    func testSpaceAndFunctionKeysAreNotInTheMacClientMap() {
        // Stream's terminal deck names these in lower snake case. The Mac client types a
        // space character and does not send F1–F4 as named keys.
        XCTAssertNil(MacAssistantKeyMapping.name(for: 49))
        XCTAssertNil(MacAssistantKeyMapping.name(for: 122))
        XCTAssertNil(MacAssistantKeyMapping.name(for: 120))
        XCTAssertNil(MacAssistantKeyMapping.name(for: 99))
        XCTAssertNil(MacAssistantKeyMapping.name(for: 118))
    }
}
