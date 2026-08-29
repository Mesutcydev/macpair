#if os(macOS)
import XCTest
@testable import HostApp
import SharedModels
import SharedProtocol

final class HostApplicationRegistryTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DesktopRect {
        DesktopRect(origin: DesktopPoint(x: x, y: y), size: DesktopSize(width: w, height: h))
    }

    private func app(
        _ bundleID: String,
        name: String,
        running: Bool = true,
        active: Bool = false,
        windows: [String] = []
    ) -> RemoteApplication {
        RemoteApplication(
            bundleIdentifier: bundleID,
            name: name,
            isRunning: running,
            isActive: active,
            windowIDs: windows
        )
    }

    func testDedupPrefersActiveInstance() {
        let deduped = HostApplicationRegistry.dedupedByBundleID([
            app("com.apple.Terminal", name: "Terminal", active: false, windows: ["1"]),
            app("com.apple.Terminal", name: "Terminal", active: true, windows: [])
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertTrue(deduped[0].isActive)
    }

    func testDedupPrefersMoreWindowsWhenActivityTies() {
        let deduped = HostApplicationRegistry.dedupedByBundleID([
            app("com.apple.dt.Xcode", name: "Xcode", windows: ["1"]),
            app("com.apple.dt.Xcode", name: "Xcode", windows: ["1", "2", "3"])
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].windowIDs.count, 3)
    }

    func testDedupPrefersRunningOverInstalledDuplicate() {
        let deduped = HostApplicationRegistry.dedupedByBundleID([
            app("com.apple.Safari", name: "Safari", running: false),
            app("com.apple.Safari", name: "Safari", running: true, windows: ["1"])
        ])
        XCTAssertEqual(deduped.count, 1)
        XCTAssertTrue(deduped[0].isRunning)
    }

    func testBrowserOrderActiveThenRunningThenAlphabetical() {
        let ordered = HostApplicationRegistry.sortedForBrowser([
            app("com.z", name: "Zed", running: true),
            app("com.a", name: "Ada", running: false),
            app("com.m", name: "Music", running: true, active: true),
            app("com.b", name: "Books", running: true)
        ])
        XCTAssertEqual(ordered.map(\.name), ["Music", "Books", "Zed", "Ada"])
    }

    // MARK: - Window selection (Step 5 policy)

    func testChooseWindowPrefersLargestArea() {
        let small = WindowInfo(windowID: 1, ownerPID: 10, bounds: rect(0, 0, 100, 100))
        let large = WindowInfo(windowID: 2, ownerPID: 10, bounds: rect(0, 0, 800, 600))
        XCTAssertEqual(HostApplicationRegistry.chooseWindow(from: [small, large])?.windowID, 2)
    }

    func testChooseWindowTieBreaksToLowerWindowID() {
        let a = WindowInfo(windowID: 7, ownerPID: 10, bounds: rect(0, 0, 400, 300))
        let b = WindowInfo(windowID: 3, ownerPID: 10, bounds: rect(0, 0, 400, 300))
        XCTAssertEqual(HostApplicationRegistry.chooseWindow(from: [a, b])?.windowID, 3)
    }

    func testChooseWindowEmptyIsNil() {
        XCTAssertNil(HostApplicationRegistry.chooseWindow(from: []))
    }

    func testAspectMatchedSizeUsesFullPortraitViewportAspect() throws {
        let size = try XCTUnwrap(HostApplicationRegistry.aspectMatchedSize(
            current: CGSize(width: 1200, height: 800),
            requestedAspect: 0.5
        ))
        XCTAssertEqual(size, CGSize(width: 400, height: 800))
    }

    func testAspectMatchedSizeShrinksHeightForWiderViewport() throws {
        let size = try XCTUnwrap(HostApplicationRegistry.aspectMatchedSize(
            current: CGSize(width: 400, height: 800),
            requestedAspect: 1
        ))
        XCTAssertEqual(size, CGSize(width: 400, height: 400))
    }

    // MARK: - Capability advertisement (Step 13)

    func testFullHostAdvertisesAppStreamingOnModernMacOS() {
        if #available(macOS 14, *) {
            XCTAssertTrue(HostProductMode.full.advertisedCapabilities.contains(.supportsAppStreaming))
        }
        XCTAssertFalse(HostProductMode.terminalOnly.advertisedCapabilities.contains(.supportsAppStreaming))
    }

    func testMiniHostSupportsStreamingAndUsesItsOwnProductSurface() {
        XCTAssertEqual(HostProductMode.mini.productTitle, "Vamp Sync")
        XCTAssertFalse(HostProductMode.mini.isTerminalOnly)
        XCTAssertEqual(HostProductMode.mini.supportedCodecs, ["hevc", "h264"])
        XCTAssertFalse(HostProductMode.mini.advertisedCapabilities.isTerminalOnlyHost)
        XCTAssertTrue(HostProductMode.mini.advertisedCapabilities.contains(.supportsMultiDisplay))
        if #available(macOS 14, *) {
            XCTAssertTrue(HostProductMode.mini.advertisedCapabilities.contains(.supportsAppStreaming))
        }
    }
}
#endif
