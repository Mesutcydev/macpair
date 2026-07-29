import Foundation
import SharedModels

public enum VideoCodec: String, Codable, Hashable, Sendable {
    case h264
    case hevc
}

public struct NegotiatedCapabilities: Codable, Hashable, Sendable {
    public var videoCodec: VideoCodec
    public var supportsMultiDisplay: Bool
    public var supportsAudio: Bool
    public var supportsMacClient: Bool
    public var supportsHDR10: Bool

    public init(
        videoCodec: VideoCodec,
        supportsMultiDisplay: Bool,
        supportsAudio: Bool,
        supportsMacClient: Bool,
        supportsHDR10: Bool = false
    ) {
        self.videoCodec = videoCodec
        self.supportsMultiDisplay = supportsMultiDisplay
        self.supportsAudio = supportsAudio
        self.supportsMacClient = supportsMacClient
        self.supportsHDR10 = supportsHDR10
    }

    private enum CodingKeys: String, CodingKey {
        case videoCodec
        case supportsMultiDisplay
        case supportsAudio
        case supportsMacClient
        case supportsHDR10
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoCodec = try container.decode(VideoCodec.self, forKey: .videoCodec)
        supportsMultiDisplay = try container.decode(Bool.self, forKey: .supportsMultiDisplay)
        supportsAudio = try container.decode(Bool.self, forKey: .supportsAudio)
        supportsMacClient = try container.decode(Bool.self, forKey: .supportsMacClient)
        supportsHDR10 = try container.decodeIfPresent(Bool.self, forKey: .supportsHDR10) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(videoCodec, forKey: .videoCodec)
        try container.encode(supportsMultiDisplay, forKey: .supportsMultiDisplay)
        try container.encode(supportsAudio, forKey: .supportsAudio)
        try container.encode(supportsMacClient, forKey: .supportsMacClient)
        try container.encode(supportsHDR10, forKey: .supportsHDR10)
    }
}

public enum CapabilityNegotiator {
    public static func negotiate(
        host: HostCapabilityFlags,
        client: HostCapabilityFlags
    ) -> NegotiatedCapabilities? {
        let codec: VideoCodec
        if host.contains(.supportsHEVC), client.contains(.supportsHEVC) {
            codec = .hevc
        } else if host.contains(.supportsH264), client.contains(.supportsH264) {
            codec = .h264
        } else {
            return nil
        }

        return NegotiatedCapabilities(
            videoCodec: codec,
            supportsMultiDisplay: host.contains(.supportsMultiDisplay) && client.contains(.supportsMultiDisplay),
            supportsAudio: host.contains(.supportsAudioLater) && client.contains(.supportsAudioLater),
            supportsMacClient: host.contains(.supportsMacClient) && client.contains(.supportsMacClient),
            supportsHDR10: codec == .hevc
                && host.contains(.supportsHDR10)
                && client.contains(.supportsHDR10)
        )
    }
}
