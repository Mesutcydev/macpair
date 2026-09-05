import Foundation

/// Canonical order and copy for Vamp Stream's connect home.
/// Sync is the host for app windows; Assistant is a follow-on pairing path.
enum VampStreamHomeLayout {
    enum Section: String, CaseIterable, Identifiable, Equatable {
        case syncHostCard
        case syncMacs
        case syncEmptyHint
        case assistantError
        case assistantHostCard
        case assistantMacs

        var id: String { rawValue }
    }

    static func sections(
        hasSyncHosts: Bool,
        hasAssistants: Bool,
        hasAssistantError: Bool
    ) -> [Section] {
        var result: [Section] = [.syncHostCard]
        result.append(hasSyncHosts ? .syncMacs : .syncEmptyHint)
        if hasAssistantError {
            result.append(.assistantError)
        }
        result.append(.assistantHostCard)
        if hasAssistants {
            result.append(.assistantMacs)
        }
        return result
    }
}

enum VampStreamHomeCopy {
    static let headerTitle = "Stream an app from your Mac"
    static let headerDetail = "Choose a trusted Mac, then open and control one app at a time."

    static let syncTitle = "Vamp Sync"
    static let syncDetail = "Scan the pairing QR on your Mac, or enter the private address shown by Vamp Sync."
    static let scanSync = "Scan Vamp Sync"
    static let scanSyncHint = "Scan a Vamp Sync pairing code"
    static let orConnectByAddress = "Or connect by address"
    static let addressPlaceholder = "Vamp Sync private address"
    static let connectByAddress = "Connect by address"
    static let addressError = "Enter the private address shown by Vamp Sync, including its port."
    static let syncMacsHeading = "VAMP SYNC MACS"
    static let lookingForSync = "Looking for Vamp Sync…"
    static let noSyncFound = "No Vamp Sync found"
    static let syncNetworkHint = "Open Vamp Sync on your Mac and keep both devices on the same LAN or private Tailscale network."
    static let retryDiscovery = "Retry discovery"
    static let unavailableSync = "A saved host is unavailable. Check that it is running and reachable on a trusted network."

    static let assistantTitle = "Vamp Assistant"
    static let assistantDetail = "Pair a workspace when you want app streams from Vamp Assistant."
    static let pairAssistant = "Pair Vamp Assistant"
    static let pairAnotherAssistant = "Pair another Assistant"
    static let pairAssistantHint = "Enter the private address and one-time pairing code shown by Vamp Assistant"
    static let assistantMacsHeading = "ASSISTANT APP STREAMS"

    static func pairAssistantTitle(hasSavedAssistants: Bool) -> String {
        hasSavedAssistants ? pairAnotherAssistant : pairAssistant
    }
}
