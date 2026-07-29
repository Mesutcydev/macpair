import Foundation
import SharedModels

public struct MacHostRuntimePolicy: Sendable, Equatable {
    public let isSandboxedDistribution: Bool

    public init(isSandboxedDistribution: Bool) {
        self.isSandboxedDistribution = isSandboxedDistribution
    }

    public static var current: MacHostRuntimePolicy {
        MacHostRuntimePolicy(
            isSandboxedDistribution: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        )
    }

    public var supportsRemoteInput: Bool {
        !isSandboxedDistribution
    }

    public var supportsRemoteUnlock: Bool {
        supportsRemoteInput
    }

    public var requiresAccessibilityPermission: Bool {
        supportsRemoteInput
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
