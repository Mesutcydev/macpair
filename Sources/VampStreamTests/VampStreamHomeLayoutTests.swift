import XCTest
@testable import Vamp_Stream

final class VampStreamHomeLayoutTests: XCTestCase {
    func testBothLeadsWithSyncThenAssistant() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .both,
                hasSyncHosts: true,
                hasAssistants: true,
                hasAssistantError: false
            ),
            [
                .syncHostCard,
                .syncMacs,
                .syncPromo,
                .assistantHostCard,
                .assistantMacs
            ]
        )
    }

    func testSyncOnlyHidesAssistant() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .sync,
                hasSyncHosts: true,
                hasAssistants: true,
                hasAssistantError: true
            ),
            [
                .syncHostCard,
                .syncMacs,
                .syncPromo
            ]
        )
    }

    func testAssistantOnlyHidesSync() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .assistant,
                hasSyncHosts: true,
                hasAssistants: true,
                hasAssistantError: false
            ),
            [
                .assistantHostCard,
                .assistantMacs
            ]
        )
    }

    func testEmptySyncKeepsHintWhenSyncIsChosen() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .both,
                hasSyncHosts: false,
                hasAssistants: false,
                hasAssistantError: false
            ),
            [
                .syncHostCard,
                .syncEmptyHint,
                .syncPromo,
                .assistantHostCard
            ]
        )
    }

    func testAssistantErrorSitsWithAssistantFollowOn() {
        XCTAssertEqual(
            VampStreamHomeLayout.sections(
                source: .both,
                hasSyncHosts: true,
                hasAssistants: false,
                hasAssistantError: true
            ),
            [
                .syncHostCard,
                .syncMacs,
                .syncPromo,
                .assistantError,
                .assistantHostCard
            ]
        )
    }

    func testHostSourceVisibility() {
        XCTAssertTrue(VampStreamHostSource.sync.showsSync)
        XCTAssertFalse(VampStreamHostSource.sync.showsAssistant)
        XCTAssertFalse(VampStreamHostSource.assistant.showsSync)
        XCTAssertTrue(VampStreamHostSource.assistant.showsAssistant)
        XCTAssertTrue(VampStreamHostSource.both.showsSync)
        XCTAssertTrue(VampStreamHostSource.both.showsAssistant)
    }

    func testHostSourceStoreRoundTrips() {
        let suite = "VampStreamHostSourceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(VampStreamHostSourceStore.load(defaults: defaults))
        VampStreamHostSourceStore.save(.assistant, defaults: defaults)
        XCTAssertEqual(VampStreamHostSourceStore.load(defaults: defaults), .assistant)
        VampStreamHostSourceStore.save(.sync, defaults: defaults)
        XCTAssertEqual(VampStreamHostSourceStore.load(defaults: defaults), .sync)
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

    func testSyncPromoOpensTheLatestBuild() {
        XCTAssertEqual(VampStreamHomeLinks.syncDownloadPage.absoluteString, "https://thevamp.app/sync/#download")
        XCTAssertEqual(VampStreamHomeCopy.syncPromoCTA, "Download Vamp Sync")
        XCTAssertFalse(VampStreamHomeLayout.sections(
            source: .assistant,
            hasSyncHosts: false,
            hasAssistants: false,
            hasAssistantError: false
        ).contains(.syncPromo))
        XCTAssertTrue(VampStreamHomeLayout.sections(
            source: .sync,
            hasSyncHosts: false,
            hasAssistants: false,
            hasAssistantError: false
        ).contains(.syncPromo))
    }

    func testReleaseManifestPrefersTheCurrentSyncDMG() throws {
        let json = """
        {
          "assets": {
            "vamp-mini-host-dmg": {
              "name": "VampSync-macOS-2.3.0-build-62-adhoc.dmg",
              "url": "https://github.com/Mesutcydev/vamp-suite/releases/download/vamp-suite-2.3.0-build-62/VampSync-macOS-2.3.0-build-62-adhoc.dmg"
            }
          }
        }
        """.data(using: .utf8)!
        XCTAssertEqual(
            VampStreamReleaseDownloads.syncURL(fromReleaseManifest: json)?.absoluteString,
            "https://github.com/Mesutcydev/vamp-suite/releases/download/vamp-suite-2.3.0-build-62/VampSync-macOS-2.3.0-build-62-adhoc.dmg"
        )
    }

    func testGitHubReleasesPickTheNewestSyncBuild() throws {
        let json = """
        [
          {
            "draft": false,
            "prerelease": false,
            "assets": [
              {
                "name": "VampSync-macOS-2.3.0-build-61-adhoc.dmg",
                "browser_download_url": "https://github.com/Mesutcydev/vamp-suite/releases/download/vamp-suite-2.3.0-build-61/VampSync-macOS-2.3.0-build-61-adhoc.dmg"
              }
            ]
          },
          {
            "draft": false,
            "prerelease": false,
            "assets": [
              {
                "name": "VampSync-macOS-2.3.0-build-62-adhoc.dmg",
                "browser_download_url": "https://github.com/Mesutcydev/vamp-suite/releases/download/vamp-suite-2.3.0-build-62/VampSync-macOS-2.3.0-build-62-adhoc.dmg"
              }
            ]
          }
        ]
        """.data(using: .utf8)!
        XCTAssertEqual(
            VampStreamReleaseDownloads.syncURL(fromGitHubReleases: json)?.lastPathComponent,
            "VampSync-macOS-2.3.0-build-62-adhoc.dmg"
        )
    }

    func testPinnedOrForeignSyncURLsAreRejected() {
        XCTAssertNil(VampStreamReleaseDownloads.trustedSyncDownload(from: "http://github.com/Mesutcydev/vamp-suite/releases/download/x/VampSync-macOS-1.0.0-build-1-adhoc.dmg"))
        XCTAssertNil(VampStreamReleaseDownloads.trustedSyncDownload(from: "https://evil.example/VampSync-macOS-2.3.0-build-62-adhoc.dmg"))
        XCTAssertNil(VampStreamReleaseDownloads.trustedSyncDownload(from: "https://github.com/Mesutcydev/vamp-suite/releases/download/x/notes.txt"))
    }
}
