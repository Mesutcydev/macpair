import Foundation
import SharedModels

#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

public final class MacHostPermissionService: PermissionServiceProtocol {
    private let policy: MacHostRuntimePolicy

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
            await MainActor.run { NSApplication.shared.activate(ignoringOtherApps: true) }
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            guard policy.canRequestAccessibilityPermission else {
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
        // Combine CGPreflight and ScreenCaptureKit instead of first-wins.
        //
        // Why not call CGPreflightScreenCaptureAccess() before withCheckedContinuation:
        // on macOS 26 beta the privacy daemon can stall, making the synchronous C call
        // block indefinitely — the timeout would never be reached. Running it on a
        // DispatchQueue thread keeps it off the Swift cooperative pool.
        //
        // Why not resume on the first SCK error/empty-display result: after the
        // operator grants Screen Recording in System Settings, SCK often fails
        // or briefly reports no displays until relaunch while CGPreflight
        // already returns true. A first-wins deny hid that grant.
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            var preflight: ScreenRecordingPermissionResolver.PreflightSignal?
            var shareableContent: ScreenRecordingPermissionResolver.ShareableContentSignal?
            var timedOut = false

            func considerResolve() {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                guard let state = ScreenRecordingPermissionResolver.resolve(
                    preflight: preflight,
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

            // Path A: synchronous C API on a background OS thread (not cooperative pool)
            DispatchQueue.global(qos: .userInitiated).async {
                let granted = CGPreflightScreenCaptureAccess()
                lock.lock()
                preflight = granted ? .granted : .denied
                lock.unlock()
                considerResolve()
            }

            // Path B: ScreenCaptureKit probe (authoritative when C API lies)
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

            // Path C: 5-second ceiling so UI never stalls.
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
            return "Needed so ScreenCaptureKit can capture your Mac display for the remote stream. If an older MacHost build is already approved, enable this updated build in System Settings, then quit and relaunch ScreenHarbor Host."
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
