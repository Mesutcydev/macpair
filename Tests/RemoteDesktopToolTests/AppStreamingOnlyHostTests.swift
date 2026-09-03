import SharedModels
import SharedProtocol
import XCTest
@testable import HostApp

/// Vamp Control has to tell a "share one app window" host apart from a "share
/// the whole desktop" host purely from the negotiated capabilities, because the
/// two need completely different session UI. Pin that against the capabilities
/// the host products actually advertise.
final class AppStreamingOnlyHostTests: XCTestCase {
    private func negotiate(_ mode: HostProductMode) -> NegotiatedCapabilities? {
        CapabilityNegotiator.negotiate(
            host: mode.advertisedCapabilities,
            client: .currentClient(isMacClient: true)
        )
    }

    func testVampSyncNegotiatesAsAppStreamingOnly() throws {
        let negotiated = try XCTUnwrap(negotiate(.mini))
        XCTAssertTrue(negotiated.supportsAppStreaming)
        XCTAssertTrue(negotiated.isAppStreamingOnly)
    }

    func testVampHostIsNotAppStreamingOnly() throws {
        let negotiated = try XCTUnwrap(negotiate(.full))
        // The full host also offers App Streaming, but it has a display stream —
        // it must keep the normal remote-desktop surface.
        XCTAssertTrue(negotiated.supportsMultiDisplay)
        XCTAssertFalse(negotiated.isAppStreamingOnly)
    }

    func testTerminalHostIsNotAppStreamingOnly() throws {
        let negotiated = try XCTUnwrap(negotiate(.terminalOnly))
        XCTAssertFalse(negotiated.isAppStreamingOnly)
    }

    func testMacClientKeepsItsMacCapabilityAgainstTheFullHost() throws {
        let negotiated = try XCTUnwrap(negotiate(.full))
        XCTAssertTrue(negotiated.supportsMacClient)
    }
}
