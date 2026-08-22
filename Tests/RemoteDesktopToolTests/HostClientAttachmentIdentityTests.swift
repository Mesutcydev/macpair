import XCTest
@testable import HostApp
@testable import SharedProtocol

final class HostClientAttachmentIdentityTests: XCTestCase {
    private let fingerprint = String(repeating: "ab", count: 32)

    func testSamePeerIDCanReplaceItsTransport() {
        let peerID = UUID()
        let candidate = SignalingPeer(
            id: peerID,
            role: .client,
            publicKeyFingerprint: String(repeating: "cd", count: 32)
        )

        XCTAssertTrue(HostClientAttachmentIdentity.matches(
            activeClientID: peerID,
            activeClientFingerprint: fingerprint,
            candidate: candidate
        ))
    }

    func testSameValidFingerprintCanReplaceLegacyRandomPeerID() {
        let candidate = SignalingPeer(
            id: UUID(),
            role: .client,
            publicKeyFingerprint: fingerprint.uppercased()
        )

        XCTAssertTrue(HostClientAttachmentIdentity.matches(
            activeClientID: UUID(),
            activeClientFingerprint: "  \(fingerprint)\n",
            candidate: candidate
        ))
    }

    func testDifferentFingerprintCannotEvictActiveClient() {
        let candidate = SignalingPeer(
            id: UUID(),
            role: .client,
            publicKeyFingerprint: String(repeating: "cd", count: 32)
        )

        XCTAssertFalse(HostClientAttachmentIdentity.matches(
            activeClientID: UUID(),
            activeClientFingerprint: fingerprint,
            candidate: candidate
        ))
    }

    func testMalformedFingerprintCannotUseReplacementPath() {
        let candidate = SignalingPeer(
            id: UUID(),
            role: .client,
            publicKeyFingerprint: "not-a-fingerprint"
        )

        XCTAssertFalse(HostClientAttachmentIdentity.matches(
            activeClientID: UUID(),
            activeClientFingerprint: "not-a-fingerprint",
            candidate: candidate
        ))
    }
}
