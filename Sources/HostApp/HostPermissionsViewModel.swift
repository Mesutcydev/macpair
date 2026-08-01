import CoreGraphics
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
        statuses.filter { $0.isRequired && !$0.isGranted }
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

    func refresh() async {
        isRefreshing = true
        lastErrorMessage = nil
        // The system permission request is gated behind the in-app explainer
        // sheet (HostPermissionExplainerSheet) so the OS dialog never appears
        // without context. It fires once per code identity: a rebuilt ad-hoc
        // binary loses its TCC grants, so the new build has to ask again.
        if UserDefaults.standard.bool(forKey: Self.explainerShownKey), promptIdentityIsStale {
            UserDefaults.standard.set(AppCodeIdentity.current(), forKey: Self.promptedIdentityKey)
            requestPermissionsForCurrentIdentity()
        }
        let newStatuses = await permissionService.friendlyStatuses()
        statuses = newStatuses
        recordGrantedIdentityIfReady()
        await logPermissionChanges(newStatuses)
        isRefreshing = false
    }

    /// Ask macOS to register/prompt for the current binary's TCC identity.
    /// Screen Recording and Accessibility are both pinned to the ad-hoc cdhash,
    /// so an update must re-request both — not only Screen Recording.
    private func requestPermissionsForCurrentIdentity() {
        _ = CGRequestScreenCaptureAccess()
        #if os(macOS)
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        #endif
    }

    /// Called by the explainer sheet on dismiss.  Marks the explainer as
    /// shown so the next refresh() call is free to fire the OS prompt.
    func markExplainerShown() {
        UserDefaults.standard.set(true, forKey: Self.explainerShownKey)
    }

    /// True when the explainer has never been shown for this user account.
    var shouldShowExplainer: Bool {
        !UserDefaults.standard.bool(forKey: Self.explainerShownKey)
    }

    /// True when this build has never fired the OS prompt, including the case
    /// where only an earlier build of the app did.
    private var promptIdentityIsStale: Bool {
        UserDefaults.standard.string(forKey: Self.promptedIdentityKey) != AppCodeIdentity.current()
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
            + "In System Settings, select ScreenHarbor Host, remove it with the − button, then approve it again. "
            + "Quit ScreenHarbor Host completely and reopen it so Screen Recording takes effect."
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
            // Trigger the native permission prompt first so macOS creates the
            // app entry in Privacy & Security before deep-linking to Settings.
            switch kind {
            case .screenRecording, .accessibility:
                _ = try await permissionService.requestPermission(for: kind)
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
            // Settings often stays frontmost after the toggle flips; scenePhase
            // may not change. Probe a few times so the grant is picked up even
            // if the operator never brings the Host window forward.
            schedulePostSettingsRefresh()
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

    private func schedulePostSettingsRefresh() {
        Task { @MainActor in
            // Absolute delays from openSettings: 2s, 5s, 10s.
            let targets: [UInt64] = [2_000_000_000, 5_000_000_000, 10_000_000_000]
            var elapsed: UInt64 = 0
            for target in targets {
                try? await Task.sleep(nanoseconds: target - elapsed)
                elapsed = target
                guard !Task.isCancelled else { return }
                guard !blockers.isEmpty else { return }
                guard !isRefreshing else { continue }
                await refresh()
            }
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
