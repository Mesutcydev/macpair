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
    /// A pairing-first menu-bar host with the full authenticated streaming stack,
    /// its own product identity, and a compact settings surface.
    case mini

    var isTerminalOnly: Bool {
        self == .terminalOnly
    }

    var productTitle: String {
        switch self {
        case .full:
            return "Vamp Host"
        case .terminalOnly:
            return "Vamp Terminal Host"
        case .mini:
            return "Vamp Mini Host"
        }
    }

    var productSubtitle: String {
        switch self {
        case .full:
            return "Remote desktop and terminal access for your Mac."
        case .terminalOnly:
            return "A focused Mac host for Vamp Terminal."
        case .mini:
            return "A compact menu-bar host for Vamp Stream."
        }
    }

    /// H.264 remains in the terminal-only advertisement because the current
    /// WebRTC session contract still negotiates a media-capable peer connection
    /// even when no screen track is started. The light host never advertises
    /// screen, audio, input, or multi-display capabilities.
    var advertisedCapabilities: HostCapabilityFlags {
        switch self {
        case .full, .mini:
            var flags: HostCapabilityFlags = [
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
            // App Streaming (window capture) needs ScreenCaptureKit APIs added in macOS 14.
            // Older hosts simply never advertise it, so clients keep plain Remote Control.
            if #available(macOS 14, *) { flags.insert(.supportsAppStreaming) }
            return flags
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
