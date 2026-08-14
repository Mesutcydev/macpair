import Foundation
import SharedModels

/// Product surface exposed by a host build.
///
/// The full Vamp Host keeps the original remote-desktop capabilities. Vamp
/// Terminal Host uses the same signed signaling and authenticated data-channel
/// stack, but advertises and accepts terminal clients only. Keeping this as a
/// host-side policy makes the two macOS apps share the security fixes without
/// making the light app grow a screen-control surface.
enum HostProductMode: String, CaseIterable, Sendable {
    case full
    case terminalOnly

    var isTerminalOnly: Bool {
        self == .terminalOnly
    }

    var productTitle: String {
        isTerminalOnly ? "Vamp Terminal Host" : "Vamp Host"
    }

    var productSubtitle: String {
        isTerminalOnly
            ? "A focused Mac host for Vamp Terminal."
            : "Remote desktop and terminal access for your Mac."
    }

    /// H.264 remains in the terminal-only advertisement because the current
    /// WebRTC session contract still negotiates a media-capable peer connection
    /// even when no screen track is started. The light host never advertises
    /// screen, audio, input, or multi-display capabilities.
    var advertisedCapabilities: HostCapabilityFlags {
        switch self {
        case .full:
            return [
                .supportsHEVC,
                .supportsH264,
                .supportsMultiDisplay,
                .supportsAudioLater,
                .supportsMacClient,
                .supportsTerminal,
                .supportsMultipleTerminals,
                .supportsTerminalChat,
                .supportsTaskPlans,
                .supportsWorkspaces
            ]
        case .terminalOnly:
            return [
                .supportsH264, .supportsTerminal, .supportsMultipleTerminals,
                .supportsTerminalChat, .supportsTaskPlans, .supportsWorkspaces
            ]
        }
    }

    var supportedCodecs: [String] {
        isTerminalOnly ? ["h264"] : ["hevc", "h264"]
    }
}
