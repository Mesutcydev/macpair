import Foundation
import SharedModels

public struct MacHostRuntimePolicy: Sendable, Equatable {
    public let isSandboxedDistribution: Bool
    public let isTerminalOnly: Bool

    public init(isSandboxedDistribution: Bool, isTerminalOnly: Bool = false) {
        self.isSandboxedDistribution = isSandboxedDistribution
        self.isTerminalOnly = isTerminalOnly
    }

    public static var current: MacHostRuntimePolicy {
        MacHostRuntimePolicy(
            isSandboxedDistribution: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        )
    }

    public static var terminalOnly: MacHostRuntimePolicy {
        MacHostRuntimePolicy(
            isSandboxedDistribution: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            isTerminalOnly: true
        )
    }

    public var supportsRemoteInput: Bool {
        !isSandboxedDistribution && !isTerminalOnly
    }

    public var supportsRemoteUnlock: Bool {
        supportsRemoteInput
    }

    public var requiresAccessibilityPermission: Bool {
        supportsRemoteInput
    }

    public var supportsScreenCapture: Bool {
        !isTerminalOnly
    }

    public var canRequestAccessibilityPermission: Bool {
        supportsRemoteInput
    }

    public var enforcedSessionMode: SessionControlMode? {
        supportsRemoteInput ? nil : .viewOnly
    }

    public var distributionTitle: String {
        isSandboxedDistribution ? "Sandboxed Build" : "Direct Distribution Build"
    }
}
