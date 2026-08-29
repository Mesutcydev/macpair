import XCTest
@testable import ClientiOS
import SharedModels
import SharedProtocol

@MainActor
final class AppStreamClientTests: XCTestCase {

    func testTerminalApplicationProfileRecognizesKnownAndNamedTerminals() {
        XCTAssertTrue(AppStreamApplicationProfile.isTerminal(
            bundleIdentifier: "com.apple.Terminal", name: "Terminal"))
        XCTAssertTrue(AppStreamApplicationProfile.isTerminal(
            bundleIdentifier: nil, name: "Ghostty Nightly"))
        XCTAssertFalse(AppStreamApplicationProfile.isTerminal(
            bundleIdentifier: "com.apple.Safari", name: "Safari"))
    }

    func testTerminalVisibleStreamSizeExcludesKeyboardAndCommandDeck() {
        let size = AppStreamApplicationProfile.visibleStreamSize(
            container: CGSize(width: 390, height: 844),
            keyboardHeight: 330,
            isTerminal: true)
        XCTAssertEqual(size.width, 390)
        XCTAssertEqual(size.height, 372)
        XCTAssertEqual(
            AppStreamApplicationProfile.visibleStreamSize(
                container: CGSize(width: 390, height: 844),
                keyboardHeight: 330,
                isTerminal: false),
            CGSize(width: 390, height: 844))
    }

    private func result(_ status: DisplaySwitchStatus, target: StreamTarget = .application("com.apple.Terminal"), reason: String? = nil) -> StreamTargetSwitchResultMessage {
        StreamTargetSwitchResultMessage(
            sessionID: UUID(),
            resolvedTarget: target,
            senderDeviceID: UUID(),
            status: status,
            reason: reason,
            startedAt: Date()
        )
    }

    // MARK: - State machine (pure reduce)

    func testAcceptedGoesToLaunching() {
        let next = AppStreamViewModel.reduce(status: .browsing, result: result(.accepted), pendingName: "Terminal")
        XCTAssertEqual(next, .launching(name: "Terminal"))
    }

    func testCompletedGoesToStreaming() {
        let next = AppStreamViewModel.reduce(
            status: .launching(name: "Terminal"),
            result: result(.completed, target: .window("42")),
            pendingName: "Terminal"
        )
        XCTAssertEqual(next, .streaming(target: .window("42"), name: "Terminal"))
    }

    func testFailureWhileLaunchingIsFailed() {
        let next = AppStreamViewModel.reduce(
            status: .launching(name: "Xcode"),
            result: result(.failed, reason: "No streamable window yet."),
            pendingName: "Xcode"
        )
        XCTAssertEqual(next, .failed(reason: "No streamable window yet."))
    }

    func testFailureWhileStreamingIsTargetLost() {
        // The host sends an unsolicited failed result when the window closes / app quits.
        let next = AppStreamViewModel.reduce(
            status: .streaming(target: .window("42"), name: "Terminal"),
            result: result(.failed, target: .window("42"), reason: "The application window is no longer available."),
            pendingName: "Terminal"
        )
        XCTAssertEqual(next, .targetLost(reason: "The application window is no longer available."))
    }

    func testRejectedIsFailed() {
        let next = AppStreamViewModel.reduce(status: .browsing, result: result(.rejected, reason: "Not running."), pendingName: "Safari")
        XCTAssertEqual(next, .failed(reason: "Not running."))
    }

    // MARK: - Capability negotiation

    func testAppStreamingNegotiatesOnlyWhenBothPeersSupportIt() {
        let hostWith: HostCapabilityFlags = [.supportsH264, .supportsAppStreaming]
        let hostWithout: HostCapabilityFlags = [.supportsH264]
        let client: HostCapabilityFlags = [.supportsH264, .supportsAppStreaming]

        XCTAssertTrue(CapabilityNegotiator.negotiate(host: hostWith, client: client)?.supportsAppStreaming == true)
        XCTAssertTrue(CapabilityNegotiator.negotiate(host: hostWithout, client: client)?.supportsAppStreaming == false)
    }

    func testCurrentClientAdvertisesAppStreaming() {
        XCTAssertTrue(HostCapabilityFlags.currentClient(isMacClient: false).contains(.supportsAppStreaming))
    }
}
