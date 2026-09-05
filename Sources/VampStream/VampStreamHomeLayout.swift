import Foundation

/// Which Mac host Stream should offer on the connect home.
enum VampStreamHostSource: String, CaseIterable, Identifiable, Equatable {
    case sync
    case assistant
    case both

    var id: String { rawValue }

    var showsSync: Bool { self != .assistant }
    var showsAssistant: Bool { self != .sync }

    var title: String {
        switch self {
        case .sync: return VampStreamHomeCopy.syncTitle
        case .assistant: return VampStreamHomeCopy.assistantTitle
        case .both: return VampStreamHomeCopy.hostSourceBothTitle
        }
    }

    var detail: String {
        switch self {
        case .sync: return VampStreamHomeCopy.hostSourceSyncDetail
        case .assistant: return VampStreamHomeCopy.hostSourceAssistantDetail
        case .both: return VampStreamHomeCopy.hostSourceBothDetail
        }
    }

    var icon: String {
        switch self {
        case .sync: return "macbook.and.iphone"
        case .assistant: return "sparkles.tv"
        case .both: return "rectangle.on.rectangle"
        }
    }
}

enum VampStreamHostSourceStore {
    static let key = "vampstream.hostSource"

    static func load(defaults: UserDefaults = .standard) -> VampStreamHostSource? {
        defaults.string(forKey: key).flatMap(VampStreamHostSource.init(rawValue:))
    }

    static func save(_ source: VampStreamHostSource, defaults: UserDefaults = .standard) {
        defaults.set(source.rawValue, forKey: key)
    }
}

/// Canonical order and copy for Vamp Stream's connect home.
/// The home is built from the host the user picked at onboarding.
enum VampStreamHomeLayout {
    enum Section: String, CaseIterable, Identifiable, Equatable {
        case syncHostCard
        case syncMacs
        case syncEmptyHint
        case syncPromo
        case assistantError
        case assistantHostCard
        case assistantMacs

        var id: String { rawValue }
    }

    static func sections(
        source: VampStreamHostSource,
        hasSyncHosts: Bool,
        hasAssistants: Bool,
        hasAssistantError: Bool
    ) -> [Section] {
        var result: [Section] = []
        if source.showsSync {
            result.append(.syncHostCard)
            result.append(hasSyncHosts ? .syncMacs : .syncEmptyHint)
            result.append(.syncPromo)
        }
        if source.showsAssistant {
            if hasAssistantError {
                result.append(.assistantError)
            }
            result.append(.assistantHostCard)
            if hasAssistants {
                result.append(.assistantMacs)
            }
        }
        return result
    }
}

enum VampStreamHomeCopy {
    static let headerTitle = "Stream an app from your Mac"
    static let headerTitleLead = "Stream an app"
    static let headerTitleTrail = "from your Mac"
    static let headerDetail = "Choose a trusted Mac, then open and control one app at a time."
    static let headerDetailSync = "Connect with Vamp Sync, then open and control one app at a time."
    static let headerDetailAssistant = "Pair Vamp Assistant, then open and control one app at a time."
    static let changeHost = "Change host"

    static let hostOnboardingTitle = "How do you connect?"
    static let hostOnboardingDetail = "Pick the Mac host you use. You can change this later."
    static let hostOnboardingContinue = "Continue"
    static let hostSourceSyncDetail = "App windows from Vamp Sync on your Mac."
    static let hostSourceAssistantDetail = "App streams from a Vamp Assistant workspace."
    static let hostSourceBothTitle = "Both"
    static let hostSourceBothDetail = "Show Vamp Sync and Vamp Assistant on the home screen."

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
    static let syncPromoEyebrow = "MAC HOST"
    static let syncPromoTitle = "Keep the host in sync."
    static let syncPromoDetail = "Download Vamp Sync for your Mac, then pair Stream with its QR code."
    static let syncPromoCTA = "Download Vamp Sync"
    static let syncPromoHint = "Downloads the latest Vamp Sync build for Mac"

    static let assistantTitle = "Vamp Assistant"
    static let assistantDetail = "Pair a workspace when you want app streams from Vamp Assistant."
    static let pairAssistant = "Pair Vamp Assistant"
    static let pairAnotherAssistant = "Pair another Assistant"
    static let pairAssistantHint = "Enter the private address and one-time pairing code shown by Vamp Assistant"
    static let assistantMacsHeading = "ASSISTANT APP STREAMS"

    static func headerDetail(for source: VampStreamHostSource) -> String {
        switch source {
        case .sync: return headerDetailSync
        case .assistant: return headerDetailAssistant
        case .both: return headerDetail
        }
    }

    static func pairAssistantTitle(hasSavedAssistants: Bool) -> String {
        hasSavedAssistants ? pairAnotherAssistant : pairAssistant
    }
}
