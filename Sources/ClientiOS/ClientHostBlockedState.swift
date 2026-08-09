import Foundation
import SharedModels
import SharedProtocol

struct ClientHostBlockedState: Equatable {
    var title: String
    var message: String
    var blockedPermissions: [PermissionState]

    init(message: PermissionBlockedMessage) {
        self.title = "Host Permissions Needed"
        self.blockedPermissions = message.blockedPermissions
        let names = message.blockedPermissions
            .map { $0.kind.clientTitle }
            .joined(separator: ", ")
        // The host sends an empty list pre-authentication (it won't reveal which permissions it lacks
        // to an unauthenticated client) and on a generic pipeline-start failure — so don't render
        // "approval for  before…" with a blank. Give actionable guidance instead.
        if names.isEmpty {
<<<<<<< HEAD
            self.message = "MacPair Host needs permission on the Mac before it can stream or accept control. On the Mac, open MacPair Host and grant Screen Recording (and Accessibility for control) — macOS can reset these after an app identity changes."
        } else {
            self.message = "MacPair Host needs approval for \(names) before streaming or control can start."
=======
            self.message = "Vamp Host needs permission on the Mac before it can stream or accept control. On the Mac, open Vamp Host and grant Screen Recording (and Accessibility for control) — macOS can reset these after an app identity changes."
        } else {
            self.message = "Vamp Host needs approval for \(names) before streaming or control can start."
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
        }
    }
}

private extension PermissionKind {
    var clientTitle: String {
        switch self {
        case .screenRecording:
            return "Screen Recording"
        case .accessibility:
            return "Accessibility"
        case .localNetwork:
            return "Local Network"
        case .microphone:
            return "Microphone"
        }
    }
}
