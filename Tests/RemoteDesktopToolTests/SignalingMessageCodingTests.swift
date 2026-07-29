import XCTest
@testable import SharedModels
@testable import SharedProtocol

final class SignalingMessageCodingTests: XCTestCase {
    func testOfferEnvelopeEncodesAndDecodes() throws {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let senderID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let envelopeID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let sentAt = Date(timeIntervalSince1970: 100)

        let offer = SessionOfferMessage(
            sessionID: sessionID,
            sdp: "v=0",
            requestedDisplayID: "main",
            qualityPreset: .balanced
        )
        let envelope = SignalingEnvelope(
            id: envelopeID,
            protocolVersion: 1,
            sentAt: sentAt,
            sessionID: sessionID,
            sender: SignalingPeer(id: senderID, role: .client, displayName: "iPhone"),
            event: .offer(offer)
        )
        let message = VersionedSignalingMessage(envelope: envelope)
        let coder = JSONSignalingMessageCoder()

        let data = try coder.encode(message)
        let decoded = try coder.decode(data)

        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.envelope.kind, .offer)
    }

    func testSessionReadyEnvelopeEncodesNegotiatedCapabilities() throws {
        let sessionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let senderID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let capabilities = NegotiatedCapabilities(
            videoCodec: .hevc,
            supportsMultiDisplay: true,
            supportsAudio: false,
            supportsMacClient: true
        )
        let envelope = SignalingEnvelope(
            protocolVersion: 1,
            sessionID: sessionID,
            sender: SignalingPeer(id: senderID, role: .host),
            event: .sessionReady(
                SessionReadyMessage(
                    sessionID: sessionID,
                    selectedDisplayID: "main",
                    negotiatedCapabilities: capabilities
                )
            )
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(SignalingEnvelope.self, from: data)

        XCTAssertEqual(decoded.kind, .sessionReady)
        XCTAssertEqual(decoded, envelope)
    }
}
