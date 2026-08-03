import Foundation
import SharedModels

#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

public final class MacHostPermissionService: PermissionServiceProtocol {
    private let policy: MacHostRuntimePolicy
    /// Hard cap: each permission kind may present at most one OS sheet per process.
    private static let osPromptLock = NSLock()
    private static var osPromptedKinds: Set<PermissionKind> = []

    public init(policy: MacHostRuntimePolicy = .current) {
        self.policy = policy
    }

    public func currentStates() async -> [PermissionState] {
        var states = [await screenRecordingState()]
        if policy.requiresAccessibilityPermission {
            states.append(refreshStateSync(for: .accessibility))
        }
        return states
    }

    public func refreshState(for kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .screenRecording:
            return await screenRecordingState()
        case .accessibility, .localNetwork, .microphone:
            return refreshStateSync(for: kind)
        }
    }

    public func requestPermission(for kind: PermissionKind) async throws -> PermissionState {
        switch kind {
        case .screenRecording:
            // Already granted for this process — do not re-open the system sheet.
            if CGPreflightScreenCaptureAccess() {
                return await screenRecordingState()
            }
            guard Self.claimOSPrompt(for: .screenRecording) else {
                return await screenRecordingState()
            }
            await MainActor.run { NSApplication.shared.activate(ignoringOtherApps: true) }
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            guard policy.canRequestAccessibilityPermission else {
                return refreshStateSync(for: kind)
            }
            if AXIsProcessTrusted() {
                return refreshStateSync(for: kind)
            }
            guard Self.claimOSPrompt(for: .accessibility) else {
                return refreshStateSync(for: kind)
            }
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .localNetwork, .microphone:
            break
        }
        return await refreshState(for: kind)
    }

    /// Returns true the first time this process may show an OS prompt for `kind`.
    private static func claimOSPrompt(for kind: PermissionKind) -> Bool {
        osPromptLock.lock()
        defer { osPromptLock.unlock() }
        if osPromptedKinds.contains(kind) { return false }
        osPromptedKinds.insert(kind)
        return true
    }

    public func friendlyStatuses() async -> [FriendlyPermissionStatus] {
        let screenRecording = await screenRecordingState()

        var statuses = [FriendlyPermissionStatus(
            kind: .screenRecording,
            title: title(for: .screenRecording),
            summary: summary(for: .screenRecording, state: screenRecording.authorizationState, isRequired: true),
            helperText: helperText(for: .screenRecording),
            authorizationState: screenRecording.authorizationState,
            isRequired: true,
            settingsButtonTitle: settingsButtonTitle(for: .screenRecording)
        )]

        if policy.canRequestAccessibilityPermission {
            let accessibility = refreshStateSync(for: .accessibility)
            statuses.append(FriendlyPermissionStatus(
                kind: .accessibility,
                title: title(for: .accessibility),
                summary: summary(for: .accessibility, state: accessibility.authorizationState, isRequired: policy.requiresAccessibilityPermission),
                helperText: helperText(for: .accessibility),
                authorizationState: accessibility.authorizationState,
                isRequired: policy.requiresAccessibilityPermission,
                settingsButtonTitle: settingsButtonTitle(for: .accessibility)
            ))
        }

        return statuses
    }

    public func openSettings(for kind: PermissionKind) async throws {
        if kind == .accessibility && !policy.canRequestAccessibilityPermission {
            return
        }
        guard let url = settingsURL(for: kind) else {
            return
        }
        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshStateSync(for kind: PermissionKind) -> PermissionState {
        let authorizationState: PermissionAuthorizationState
        switch kind {
        case .screenRecording:
            authorizationState = CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .accessibility:
            authorizationState = policy.canRequestAccessibilityPermission
                ? (AXIsProcessTrusted() ? .granted : .denied)
                : .restricted
        case .localNetwork, .microphone:
            authorizationState = .unknown
        }
        return PermissionState(kind: kind, authorizationState: authorizationState, lastCheckedAt: Date())
    }

    private func screenRecordingState() async -> PermissionState {
        // CRITICAL: never call SCShareableContent while CGPreflight is false.
        // ScreenCaptureKit presents the system Screen Recording sheet on access
        // when unauthorized. The host polls this path every few seconds while
        // setup is blocked, which produced a prompt storm (10–15+ dialogs).
        //
        // CGPreflight runs on a background OS thread because on macOS 26 beta the
        // privacy daemon can stall the synchronous C call indefinitely.
        let preflightGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CGPreflightScreenCaptureAccess())
            }
        }

        if !preflightGranted {
            return PermissionState(
                kind: .screenRecording,
                authorizationState: .denied,
                lastCheckedAt: Date()
            )
        }

        // Preflight already says granted. Optionally confirm via SCK; if SCK is
        // still settling after a fresh grant, trust preflight (do not deny).
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            var shareableContent: ScreenRecordingPermissionResolver.ShareableContentSignal?
            var timedOut = false

            func considerResolve() {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                guard let state = ScreenRecordingPermissionResolver.resolve(
                    preflight: .granted,
                    shareableContent: shareableContent,
                    timedOut: timedOut
                ) else {
                    return
                }
                resumed = true
                continuation.resume(returning: PermissionState(
                    kind: .screenRecording,
                    authorizationState: state,
                    lastCheckedAt: Date()
                ))
            }

            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    lock.lock()
                    shareableContent = content.displays.isEmpty ? .deniedEmptyDisplays : .granted
                    lock.unlock()
                } catch {
                    lock.lock()
                    shareableContent = .error
                    lock.unlock()
                }
                considerResolve()
            }

            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                lock.lock()
                timedOut = true
                lock.unlock()
                considerResolve()
            }
        }
    }

    private func settingsURL(for kind: PermissionKind) -> URL? {
        // macOS 13+ uses the PrivacySecurity extension URL scheme.
        // The old com.apple.preference.security scheme stopped working on macOS 13+.
        switch kind {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        case .localNetwork:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")
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

    private func helperText(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Needed so ScreenCaptureKit can capture your Mac display for the remote stream. If an older MacHost build is already approved, enable this updated build in System Settings, then quit and relaunch MacPair Host."
        case .accessibility:
            if policy.canRequestAccessibilityPermission {
                if policy.supportsRemoteInput {
                    return "Needed so trusted clients can control the pointer, keyboard, and shortcuts. If only an older MacHost build is listed as approved, re-enable this updated build in System Settings."
                }
                return "Needed so trusted clients can type your Mac login password from the lock screen when Remote Unlock is enabled. If only an older MacHost build is listed as approved, re-enable this updated build in System Settings."
            }
            return "This sandboxed build runs in View Only mode because it cannot inject keyboard or pointer events."
        case .localNetwork:
            return "Needed for LAN discovery and local signaling."
        case .microphone:
            return "Reserved for future audio support."
        }
    }

    private func summary(for kind: PermissionKind, state: PermissionAuthorizationState, isRequired: Bool) -> String {
        if kind == .accessibility && !isRequired {
            return "Not available in this build"
        }
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

    private func settingsButtonTitle(for kind: PermissionKind) -> String {
        switch kind {
        case .screenRecording:
            return "Open Screen Recording"
        case .accessibility:
            if !policy.canRequestAccessibilityPermission {
                return "Sandboxed View Only"
            }
            return "Open Accessibility"
        case .localNetwork:
            return "Open Local Network"
        case .microphone:
            return "Open Microphone"
        }
    }
}
#endif
