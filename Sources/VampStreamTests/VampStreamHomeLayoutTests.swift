import XCTest
@testable import Vamp_Stream

final class VampStreamHomeLayoutTests: XCTestCase {
    func testHomeLeadsWithSyncThenAssistant() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                hasSyncHosts: true,
                hasAssistants: true,
                hasAssistantError: false
            ),
            [
                .syncHostCard,
                .syncMacs,
                .assistantHostCard,
                .assistantMacs
            ]
        )
    }

    func testEmptySyncKeepsHintBeforeAssistantFollowOn() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                hasSyncHosts: false,
                hasAssistants: false,
                hasAssistantError: false
            ),
            [
                .syncHostCard,
                .syncEmptyHint,
                .assistantHostCard
            ]
        )
    }

    func testAssistantErrorSitsWithAssistantFollowOn() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                hasSyncHosts: true,
                hasAssistants: false,
                hasAssistantError: true
            ),
            [
                .syncHostCard,
                .syncMacs,
                .assistantError,
                .assistantHostCard
            ]
        )
    }

    func testAssistantMacsDoNotPrecedeSync() {
        let sections = VampStreamHomeLayout.sections(
            hasSyncHosts: true,
            hasAssistants: true,
            hasAssistantError: true
        )
        let syncIndex = sections.firstIndex(of: .syncMacs)
        let assistantIndex = sections.firstIndex(of: .assistantMacs)
        XCTAssertEqual(sections.first, .syncHostCard)
        XCTAssertNotNil(syncIndex)
        XCTAssertNotNil(assistantIndex)
        XCTAssertLessThan(syncIndex!, assistantIndex!)
    }

    func testPrimaryScanCopyNamesVampSync() {
        XCTAssertEqual(VampStreamHomeCopy.syncTitle, "Vamp Sync")
        XCTAssertEqual(VampStreamHomeCopy.scanSync, "Scan Vamp Sync")
        XCTAssertEqual(VampStreamHomeCopy.assistantTitle, "Vamp Assistant")
        XCTAssertEqual(
            VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: false),
            "Pair Vamp Assistant"
        )
        XCTAssertEqual(
            VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: true),
            "Pair another Assistant"
        )
    }
}
