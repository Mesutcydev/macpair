import Foundation
import Diagnostics
import Permissions
import SharedModels
#if os(macOS)
import ApplicationServices
#endif

@MainActor
final class HostPermissionsViewModel: ObservableObject {
    @Published private(set) var statuses: [FriendlyPermissionStatus] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?

    private let permissionService: any PermissionServiceProtocol
    private let eventLogStore: any EventLogStoreProtocol
    private var previousStates: [PermissionKind: PermissionAuthorizationState] = [:]
    private var refreshPending = false

    private static let explainerShownKey = "host.didShowPermissionExplainer"
    /// Code identity the OS permission prompt was last fired for. Stored instead
    /// of a one-shot flag because an ad-hoc signed rebuild invalidates the
    /// previous TCC grants, and the operator needs a fresh prompt for the new
    /// binary rather than silence.
    private static let promptedIdentityKey = "host.lastPermissionPromptCodeIdentity"
    /// Code identity that last had every required permission granted.
    private static let grantedIdentityKey = "host.lastGrantedPermissionCodeIdentity"
    /// Superseded one-shot flag, kept only to migrate existing installs.
    private static let legacyPromptedKey = "host.didRequestScreenRecording"

    /// Whether an earlier build of the host already drove the OS prompt, sampled
    /// before this launch overwrites the stored identity.
    private let promptedForEarlierBuild: Bool = {
        let defaults = UserDefaults.standard
        guard let prompted = defaults.string(forKey: "host.lastPermissionPromptCodeIdentity") else {
            return defaults.bool(forKey: "host.didRequestScreenRecording")
        }
        return prompted != AppCodeIdentity.current()
    }()

    init(
        permissionService: any PermissionServiceProtocol,
        eventLogStore: any EventLogStoreProtocol
    ) {
        self.permissionService = permissionService
        self.eventLogStore = eventLogStore
    }

    var blockers: [FriendlyPermissionStatus] {
        // Only hard denials block setup. `.unknown` means the privacy daemon
        // has not answered yet — treat that as still checking, not as a missing
        // grant, or the dashboard nags forever while TCC is merely slow.
        statuses.filter { $0.isRequired && $0.authorizationState == .denied }
    }

    var allRequiredGranted: Bool {
        !statuses.isEmpty && blockers.isEmpty
    }

    var dashboardSummary: String {
        if statuses.isEmpty {
            return "Checking"
        }
        if allRequiredGranted {
            return "Ready"
        }
        return "\(blockers.count) blocker\(blockers.count == 1 ? "" : "s")"
    }

    var onboardingTitle: String {
        allRequiredGranted ? "Host Permissions Ready" : "Finish Host Setup"
    }

    var onboardingMessage: String {
        let hasRequiredAccessibility = statuses.contains { $0.kind == .accessibility && $0.isRequired }
        let hasOptionalAccessibility = statuses.contains { $0.kind == .accessibility && !$0.isRequired }
        if allRequiredGranted {
            if hasRequiredAccessibility {
                return "Screen streaming and input control permissions are ready."
            }
            return hasOptionalAccessibility
                ? "Screen Recording permission is ready. Accessibility is optional and enables Remote Unlock from the login window."
                : "Screen Recording permission is ready. This build streams in View Only mode."
        }
        if hasRequiredAccessibility {
            return "Screen Recording lets the host stream your display. Accessibility lets trusted clients send pointer and keyboard input."
        }
        return hasOptionalAccessibility
            ? "Screen Recording is required for streaming. Accessibility is optional and enables Remote Unlock from the login window."
            : "Screen Recording is required for streaming. This build runs in View Only mode — remote keyboard and pointer control are available in the direct-download host."
    }

<<<<<<< HEAD
    /// Re-read TCC state.
    /// - Parameter requestOSPromptIfNeeded: Ignored for OS sheet presentation.
    ///   Kept so call sites stay source-compatible. Automatic refresh must never
    ///   present CG/AX dialogs — those APIs are only reached from explicit user
    ///   actions (`openSettings` / `requestPrompt`), and at most once per kind
    ///   per process inside `MacHostPermissionService`.
    func refresh(requestOSPromptIfNeeded: Bool = true) async {
        _ = requestOSPromptIfNeeded
        isRefreshing = true
        lastErrorMessage = nil
        let newStatuses = await permissionService.friendlyStatuses()
        statuses = newStatuses
        recordGrantedIdentityIfReady()
        await logPermissionChanges(newStatuses)
        isRefreshing = false
    }

    /// Called by the explainer sheet on dismiss.  Marks the explainer as
    /// shown so the operator can open System Settings from the dashboard.
=======
    func refresh() async {
        if isRefreshing {
            refreshPending = true
            return
        }

        isRefreshing = true
        lastErrorMessage = nil

        repeat {
            refreshPending = false
            let newStatuses = await permissionService.friendlyStatuses()
            statuses = newStatuses
            await logPermissionChanges(newStatuses)
        } while refreshPending

        isRefreshing = false
    }

    /// Called by the explainer sheet on dismiss. The actual native request is
    /// made explicitly by the caller so a state refresh never races the TCC
    /// prompt it is trying to observe.
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
    func markExplainerShown() {
        UserDefaults.standard.set(true, forKey: Self.explainerShownKey)
    }

    /// True when the explainer has never been shown for this user account.
    var shouldShowExplainer: Bool {
        !UserDefaults.standard.bool(forKey: Self.explainerShownKey)
    }

    /// True when a previous build of the host was already approved but this one
    /// has blockers, which is what macOS does after the app binary changes.
    /// The stale System Settings entry has to be removed and re-added.
    var permissionsResetByUpdate: Bool {
        guard !blockers.isEmpty else { return false }
        guard let granted = UserDefaults.standard.string(forKey: Self.grantedIdentityKey) else {
            // Installs that predate identity tracking have no granted identity
            // to compare, so fall back to whether an earlier build prompted.
            return promptedForEarlierBuild
        }
        return granted != AppCodeIdentity.current()
    }

    private func recordGrantedIdentityIfReady() {
        guard allRequiredGranted else { return }
        UserDefaults.standard.set(AppCodeIdentity.current(), forKey: Self.grantedIdentityKey)
    }

    var permissionsResetByUpdateMessage: String {
        "macOS ties these approvals to the exact app binary, so updating the host cleared them. "
            + "In System Settings, select MacPair Host, remove it with the − button, then approve it again. "
            + "Quit MacPair Host completely and reopen it so Screen Recording takes effect."
    }

    func retry(_ kind: PermissionKind) async {
        isRefreshing = true
        lastErrorMessage = nil
        let refreshed = await permissionService.refreshState(for: kind)
        var newStatuses = await permissionService.friendlyStatuses()
        if !newStatuses.contains(where: { $0.kind == kind }) {
            newStatuses.append(
                FriendlyPermissionStatus(
                    kind: refreshed.kind,
                    title: title(for: refreshed.kind),
                    summary: summary(for: refreshed.authorizationState),
                    helperText: helperText(for: refreshed.kind),
                    authorizationState: refreshed.authorizationState,
                    isRequired: true,
                    settingsButtonTitle: "Open Settings"
                )
            )
        }
        statuses = newStatuses
        await logPermissionChanges(newStatuses)
        isRefreshing = false
    }

    func requestPrompt(for kind: PermissionKind) async {
        do {
            _ = try await permissionService.requestPermission(for: kind)
            await refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
            await eventLogStore.append(
                EventLogItem(
                    severity: .error,
                    category: "Permissions",
                    message: "Permission request failed for \(title(for: kind)): \(error.localizedDescription)"
                )
            )
        }
    }

    func openSettings(for kind: PermissionKind) async {
        do {
            // Register a TCC entry at most once per process (gated inside the
            // permission service), then deep-link to Settings. Never call this
            // from a poll — only from an explicit button.
            switch kind {
            case .screenRecording, .accessibility:
                let current = await permissionService.refreshState(for: kind)
                if current.authorizationState != .granted {
                    _ = try await permissionService.requestPermission(for: kind)
                    UserDefaults.standard.set(AppCodeIdentity.current(), forKey: Self.promptedIdentityKey)
                }
            case .localNetwork, .microphone:
                break
            }
            try await permissionService.openSettings(for: kind)
            await eventLogStore.append(
                EventLogItem(
                    severity: .info,
                    category: "Permissions",
                    message: "Opened settings for \(title(for: kind))"
                )
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            await eventLogStore.append(
                EventLogItem(
                    severity: .error,
                    category: "Permissions",
                    message: "Could not open settings for \(title(for: kind)): \(error.localizedDescription)"
                )
            )
        }
    }

    private func logPermissionChanges(_ statuses: [FriendlyPermissionStatus]) async {
        for status in statuses where status.isRequired {
            let previous = previousStates[status.kind]
            previousStates[status.kind] = status.authorizationState

            if status.authorizationState == .granted, previous != nil, previous != .granted {
                await eventLogStore.append(
                    EventLogItem(
                        severity: .info,
                        category: "Permissions",
                        message: "\(status.title) permission recovered"
                    )
                )
            } else if status.authorizationState != .granted, previous != status.authorizationState {
                await eventLogStore.append(
                    EventLogItem(
                        severity: .warning,
                        category: "Permissions",
                        message: "\(status.title) permission is blocking host readiness"
                    )
                )
            }
        }
    }

    private func title(for kind: PermissionKind) -> String {
        switch kind {
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

    private func summary(for state: PermissionAuthorizationState) -> String {
        switch state {
        case .unknown:
            return "Needs checking"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Needs approval"
        case .granted:
            return "Ready"
        case .restricted:
            return "Restricted"
        }
    }

    private func helperText(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Needed so ScreenCaptureKit can capture your Mac display for the remote stream. After approving in System Settings, quit and relaunch the host."
        case .accessibility:
            return "Needed so trusted clients can control the pointer, keyboard, and shortcuts."
        case .localNetwork:
            return "Needed for LAN discovery and local signaling."
        case .microphone:
            return "Reserved for future audio support."
        }
    }
}
