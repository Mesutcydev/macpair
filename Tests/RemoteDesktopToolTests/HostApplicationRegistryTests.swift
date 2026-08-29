#if os(macOS)
import XCTest
@testable import HostApp
import SharedModels
import SharedProtocol
import TransportWebRTC

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

    /// A Mac with a full /Applications encodes to several hundred KB with icons attached,
    /// which the control channel silently drops. The snapshot must still arrive.
    func testApplicationListEnvelopeStaysUnderTheControlChannelBudget() throws {
        let icon = String(repeating: "A", count: 3_000) // ~ one 32x32 PNG, base64
        let applications = (0..<200).map { index in
            RemoteApplication(
                bundleIdentifier: "com.example.app\(index)",
                name: "Application \(index)",
                isRunning: index < 10,
                isActive: false,
                iconPNGBase64: icon,
                windowIDs: []
            )
        }
        let envelope = try XCTUnwrap(HostSessionCoordinator.applicationListEnvelope(
            applications: applications,
            sessionID: UUID(),
            senderDeviceID: UUID()
        ))
        let wire = try envelope.wireEncode()
        XCTAssertLessThanOrEqual(wire.count, HostSessionCoordinator.applicationListByteBudget)
        // Shedding icons must never shed applications.
        let decoded = try DataChannelEnvelope.wireDecode(wire).decodeApplicationListSnapshot()
        XCTAssertEqual(decoded.applications.count, 200)
        XCTAssertTrue(decoded.applications.contains { $0.iconPNGBase64 != nil })
    }

    func testApplicationListEnvelopeKeepsEveryIconWhenItAlreadyFits() throws {
        let applications = [
            RemoteApplication(bundleIdentifier: "com.example.a", name: "A", isRunning: true,
                              isActive: true, iconPNGBase64: String(repeating: "A", count: 3_000)),
            RemoteApplication(bundleIdentifier: "com.example.b", name: "B", isRunning: false,
                              isActive: false, iconPNGBase64: String(repeating: "B", count: 3_000)),
        ]
        let envelope = try XCTUnwrap(HostSessionCoordinator.applicationListEnvelope(
            applications: applications,
            sessionID: UUID(),
            senderDeviceID: UUID()
        ))
        let decoded = try envelope.decodeApplicationListSnapshot()
        XCTAssertTrue(decoded.applications.allSatisfy { $0.iconPNGBase64 != nil })
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

    func testAssistantCompatibleWindowFitStaysOnDisplay() {
        let frame = HostApplicationRegistry.targetWindowFrame(
            current: CGRect(x: 1_500, y: 800, width: 1_200, height: 800),
            display: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            requestedAspect: 390.0 / 844.0
        )

        XCTAssertEqual(frame.width / frame.height, 390.0 / 844.0, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(frame.minX, 24)
        XCTAssertGreaterThanOrEqual(frame.minY, 52)
        XCTAssertLessThanOrEqual(frame.maxX, 1_896)
        XCTAssertLessThanOrEqual(frame.maxY, 1_056)
    }

    func testAssistantCompatibleWindowFitShrinksHeightForWideViewport() {
        let frame = HostApplicationRegistry.targetWindowFrame(
            current: CGRect(x: 100, y: 100, width: 400, height: 800),
            display: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            requestedAspect: 1
        )
        XCTAssertEqual(frame.size, CGSize(width: 400, height: 400))
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
        XCTAssertTrue(HostProductMode.mini.isAppStreamingOnly)
        XCTAssertEqual(HostProductMode.mini.supportedCodecs, ["h264"])
        XCTAssertFalse(HostProductMode.mini.advertisedCapabilities.isTerminalOnlyHost)
        XCTAssertFalse(HostProductMode.mini.advertisedCapabilities.contains(.supportsMultiDisplay))
        XCTAssertFalse(HostProductMode.mini.advertisedCapabilities.contains(.supportsTerminal))
        if #available(macOS 14, *) {
            XCTAssertTrue(HostProductMode.mini.advertisedCapabilities.contains(.supportsAppStreaming))
        }
    }
}
#endif
