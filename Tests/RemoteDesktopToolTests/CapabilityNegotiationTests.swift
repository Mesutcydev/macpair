import XCTest
@testable import SharedModels
@testable import SharedProtocol

final class CapabilityNegotiationTests: XCTestCase {
    func testNegotiationPrefersHEVCWhenBothPeersSupportIt() {
        let host: HostCapabilityFlags = [.supportsHEVC, .supportsH264, .supportsMultiDisplay]
        let client: HostCapabilityFlags = [.supportsHEVC, .supportsH264, .supportsMultiDisplay]

        let result = CapabilityNegotiator.negotiate(host: host, client: client)

        XCTAssertEqual(result?.videoCodec, .hevc)
        XCTAssertEqual(result?.supportsMultiDisplay, true)
    }

    func testNegotiationFallsBackToH264() {
        let host: HostCapabilityFlags = [.supportsHEVC, .supportsH264]
        let client: HostCapabilityFlags = [.supportsH264]

        let result = CapabilityNegotiator.negotiate(host: host, client: client)

        XCTAssertEqual(result?.videoCodec, .h264)
    }

    func testNegotiationFailsWithoutCommonCodec() {
        let host: HostCapabilityFlags = [.supportsHEVC]
        let client: HostCapabilityFlags = [.supportsH264]

        XCTAssertNil(CapabilityNegotiator.negotiate(host: host, client: client))
    }
}
