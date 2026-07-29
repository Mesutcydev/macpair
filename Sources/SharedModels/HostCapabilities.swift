import Foundation
#if canImport(VideoToolbox)
import CoreMedia
import VideoToolbox
#endif

public enum StreamDynamicRange: String, Codable, Hashable, Sendable {
    case sdr
    case hdr10
}

public struct HostCapabilityFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public static let supportsHEVC = HostCapabilityFlags(rawValue: 1 << 0)
    public static let supportsH264 = HostCapabilityFlags(rawValue: 1 << 1)
    public static let supportsMultiDisplay = HostCapabilityFlags(rawValue: 1 << 2)
    public static let supportsAudioLater = HostCapabilityFlags(rawValue: 1 << 3)
    public static let supportsMacClient = HostCapabilityFlags(rawValue: 1 << 4)
    public static let supportsVideoFragmentation = HostCapabilityFlags(rawValue: 1 << 5)
    public static let supportsHDR10 = HostCapabilityFlags(rawValue: 1 << 6)
    /// The receiver understands XOR parity packets and can reconstruct a single lost
    /// video fragment without a retransmission. Sender (host) only emits parity when
    /// the client advertises this, so older clients are unaffected.
    public static let supportsVideoFEC = HostCapabilityFlags(rawValue: 1 << 7)
    /// The client can decode Opus audio. The host only sends Opus (lower-latency than
    /// AAC) when the client advertises this AND the stream rate/channels are Opus-
    /// compatible; otherwise it stays on AAC-LC, so older clients are unaffected.
    public static let supportsOpusAudio = HostCapabilityFlags(rawValue: 1 << 8)

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Capabilities of the current device acting as a streaming client (decoder side).
    ///
    /// HEVC is advertised only when the hardware HEVC decoder is actually available,
    /// so the host never negotiates a codec this device can't decode in hardware.
    /// Falls back to H.264 only on platforms/devices without HEVC hardware decode.
    public static func currentClient(isMacClient: Bool) -> HostCapabilityFlags {
        var flags: HostCapabilityFlags = [
            .supportsH264,
            .supportsMultiDisplay,
            .supportsAudioLater,
            .supportsVideoFragmentation,
            .supportsVideoFEC,
            .supportsOpusAudio
        ]
        #if canImport(VideoToolbox)
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            flags.insert(.supportsHEVC)
            flags.insert(.supportsHDR10)
        }
        #endif
        if isMacClient {
            flags.insert(.supportsMacClient)
        }
        return flags
    }
}

public extension HostCapabilityFlags {
    static let baseline: HostCapabilityFlags = [.supportsH264]

    var stableNames: [String] {
        var names: [String] = []
        if contains(.supportsHEVC) { names.append("supportsHEVC") }
        if contains(.supportsH264) { names.append("supportsH264") }
        if contains(.supportsMultiDisplay) { names.append("supportsMultiDisplay") }
        if contains(.supportsAudioLater) { names.append("supportsAudioLater") }
        if contains(.supportsMacClient) { names.append("supportsMacClient") }
        if contains(.supportsVideoFragmentation) { names.append("supportsVideoFragmentation") }
        if contains(.supportsHDR10) { names.append("supportsHDR10") }
        if contains(.supportsVideoFEC) { names.append("supportsVideoFEC") }
        if contains(.supportsOpusAudio) { names.append("supportsOpusAudio") }
        return names
    }

    init(stableNames: [String]) {
        var flags: HostCapabilityFlags = []
        for name in stableNames {
            switch name {
            case "supportsHEVC":
                flags.insert(.supportsHEVC)
            case "supportsH264":
                flags.insert(.supportsH264)
            case "supportsMultiDisplay":
                flags.insert(.supportsMultiDisplay)
            case "supportsAudioLater":
                flags.insert(.supportsAudioLater)
            case "supportsMacClient":
                flags.insert(.supportsMacClient)
            case "supportsVideoFragmentation":
                flags.insert(.supportsVideoFragmentation)
            case "supportsHDR10":
                flags.insert(.supportsHDR10)
            case "supportsVideoFEC":
                flags.insert(.supportsVideoFEC)
            case "supportsOpusAudio":
                flags.insert(.supportsOpusAudio)
            default:
                continue
            }
        }
        self = flags
    }
}
