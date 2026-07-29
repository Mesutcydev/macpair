@preconcurrency import CoreMedia
import Foundation
import SharedModels

// MARK: - Capture State

public enum CaptureState: String, Sendable, Hashable {
    case stopped
    case starting
    case running
    case failed
    case permissionBlocked
}

// MARK: - Capture Diagnostics

public struct CaptureDiagnostics: Sendable, Hashable {
    public var capturedFrames: UInt64
    public var droppedFrames: UInt64
    public var lastFrameTimestamp: Date?
    public var streamRestarts: Int
    public var currentDisplayID: String?
    public var qualityPreset: StreamQualityPreset?

    public init(
        capturedFrames: UInt64 = 0,
        droppedFrames: UInt64 = 0,
        lastFrameTimestamp: Date? = nil,
        streamRestarts: Int = 0,
        currentDisplayID: String? = nil,
        qualityPreset: StreamQualityPreset? = nil
    ) {
        self.capturedFrames = capturedFrames
        self.droppedFrames = droppedFrames
        self.lastFrameTimestamp = lastFrameTimestamp
        self.streamRestarts = streamRestarts
        self.currentDisplayID = currentDisplayID
        self.qualityPreset = qualityPreset
    }
}

// MARK: - Frame Output

public protocol CaptureFrameReceiver: AnyObject, Sendable {
    func didCaptureFrame(_ sampleBuffer: CMSampleBuffer, displayID: String)
}

// MARK: - Audio Output

public protocol CaptureAudioReceiver: AnyObject, Sendable {
    func didCaptureAudioBuffer(_ sampleBuffer: CMSampleBuffer) async
}

// MARK: - Capture Engine Protocol

public protocol CaptureEngineProtocol {
    var isCapturing: Bool { get }
    var captureState: CaptureState { get }
    var diagnostics: CaptureDiagnostics { get }

    /// - Parameter allowsHighResolution: when `true`, `balanced`/`quality` capture at up
    ///   to 4K instead of 1080p (HEVC path). Must match the encoder's configured codec
    ///   so capture and encode dimensions stay in lockstep.
    func startCapture(displayID: String, qualityPreset: StreamQualityPreset, allowsHighResolution: Bool) async throws
    func startCapture(
        displayID: String,
        qualityPreset: StreamQualityPreset,
        allowsHighResolution: Bool,
        dynamicRange: StreamDynamicRange
    ) async throws
    /// Reconfigures the active SCStream frame interval without restarting capture.
    func updateFrameRateLimit(_ framesPerSecond: Int) async throws
    func stopCapture() async

    func setFrameReceiver(_ receiver: (any CaptureFrameReceiver)?)
    func setAudioReceiver(_ receiver: (any CaptureAudioReceiver)?)
    func stateChanges() -> AsyncStream<CaptureState>
}

public extension CaptureEngineProtocol {
    /// Convenience for callers that don't drive HEVC negotiation (host-local capture,
    /// recovery): keeps the standard 1080p cap for `balanced`/`quality`.
    func startCapture(displayID: String, qualityPreset: StreamQualityPreset) async throws {
        try await startCapture(displayID: displayID, qualityPreset: qualityPreset, allowsHighResolution: false)
    }

    func startCapture(
        displayID: String,
        qualityPreset: StreamQualityPreset,
        allowsHighResolution: Bool,
        dynamicRange: StreamDynamicRange
    ) async throws {
        try await startCapture(
            displayID: displayID,
            qualityPreset: qualityPreset,
            allowsHighResolution: allowsHighResolution
        )
    }

    func updateFrameRateLimit(_ framesPerSecond: Int) async throws {}
}

public protocol DisplayLayoutProviding {
    func currentDisplayLayout() async throws -> DisplayLayout
}

public protocol DisplayLayoutObserving: DisplayLayoutProviding {
    func layoutChanges() -> AsyncStream<DisplayLayout>
}
