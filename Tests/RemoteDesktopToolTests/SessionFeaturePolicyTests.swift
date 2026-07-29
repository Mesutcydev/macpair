import CoreVideo
import XCTest
@testable import ClientiOS
@testable import Diagnostics
@testable import Discovery
@testable import EncodeEngine
@testable import HostApp
@testable import SharedModels
@testable import SharedProtocol
@testable import TransportWebRTC

private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ value: Value) {
        lock.withLock {
            self.value = value
        }
    }
}

final class SessionFeaturePolicyTests: XCTestCase {
    func testUltraSupportAllowsHighResolutionModernPhone() {
        XCTAssertTrue(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone17,2",
                nativeBounds: CGSize(width: 1290, height: 2796),
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024
            )
        )
    }

    func testUltraSupportBlocksKnownNonProPhoneWithoutHeadroom() {
        XCTAssertFalse(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone16,3",
                nativeBounds: CGSize(width: 1179, height: 2556),
                physicalMemoryBytes: 6 * 1024 * 1024 * 1024
            )
        )
    }

    func testUltraSupportFallsBackToHeuristicForUnknownFuturePhone() {
        XCTAssertTrue(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone99,9",
                nativeBounds: CGSize(width: 1320, height: 2868),
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
                hardwareHEVCDecodeSupported: true
            )
        )
    }

    func testUltraSupportRequiresHardwareHEVCForUnknownFuturePhone() {
        XCTAssertFalse(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone99,9",
                nativeBounds: CGSize(width: 1320, height: 2868),
                physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
                hardwareHEVCDecodeSupported: false
            )
        )
    }

    func testUltraSupportBlocksLowerHeadroomPhone() {
        XCTAssertFalse(
            ClientAppEnvironment.supportsUltraQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone14,5",
                nativeBounds: CGSize(width: 1170, height: 2532),
                physicalMemoryBytes: 4 * 1024 * 1024 * 1024
            )
        )
    }

    func testQualityClassifierReconnectWins() {
        let service = NetworkQualityIndicatorService()
        let metrics = SessionMetricsSnapshot(connectionState: .connected)

        XCTAssertEqual(service.classify(metrics: metrics, isReconnecting: true), .reconnecting)
    }

    func testQualityClassifierDetectsPoorConditions() {
        let service = NetworkQualityIndicatorService()
        let metrics = SessionMetricsSnapshot(
            framesPerSecond: 9,
            bitrateKbps: 900,
            latencyMs: 260,
            packetLossPercent: 6.5,
            connectionState: .connected
        )

        XCTAssertEqual(service.classify(metrics: metrics, isReconnecting: false), .poor)
    }

    func testStatsFormatterUsesCompactUnits() {
        let formatter = SessionStatsFormatter()

        XCTAssertEqual(formatter.fpsText(for: 29.2), "29 fps")
        XCTAssertEqual(formatter.bitrateText(for: 4_800), "4.8 Mbps")
        XCTAssertEqual(formatter.latencyText(for: 42), "42 ms")
        XCTAssertEqual(formatter.packetLossText(for: 1.25), "1.2%")
    }

    func testLowPowerProfileReducesFrameRateAndBitrate() {
        let policy = SessionPerformancePolicyService()
        let profile = policy.profile(
            preferredPreset: .ultra,
            lowPowerModeEnabled: true,
            thermalState: .nominal
        )

        XCTAssertEqual(profile.effectivePreset, .balanced)
        XCTAssertEqual(profile.targetFrameRate, 24)
        XCTAssertLessThan(profile.maxBitrateKbps, 8_000)
        XCTAssertEqual(profile.throttleReason, .lowPower)
    }

    func testDefaultPreferredPresetUsesUltraOnlyForAllowlistedPhones() {
        XCTAssertEqual(
            ClientAppEnvironment.defaultPreferredQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone17,2"
            ),
            .quality
        )
        XCTAssertEqual(
            ClientAppEnvironment.defaultPreferredQualityPreset(
                isPhone: true,
                deviceModelIdentifier: "iPhone16,3"
            ),
            .balanced
        )
        XCTAssertEqual(
            ClientAppEnvironment.defaultPreferredQualityPreset(
                isPhone: false,
                deviceModelIdentifier: nil
            ),
            .balanced
        )
    }

    func testStreamScalingResolutionCaps() {
        // Under H.264 (allowsHighResolution = false), caps at 1920 (1080p equivalent)
        let scaledH264 = StreamScaling.scaledDimensions(
            preset: .balanced,
            nativeWidth: 3840,
            nativeHeight: 2160,
            allowsHighResolution: false
        )
        XCTAssertEqual(scaledH264.width, 1920)
        XCTAssertEqual(scaledH264.height, 1080)

        // Under HEVC (allowsHighResolution = true), caps at 3840 (4K equivalent)
        let scaledHEVC = StreamScaling.scaledDimensions(
            preset: .balanced,
            nativeWidth: 5120,
            nativeHeight: 2880,
            allowsHighResolution: true
        )
        XCTAssertEqual(scaledHEVC.width, 3840)
        XCTAssertEqual(scaledHEVC.height, 2160)

        // Under HEVC (allowsHighResolution = true) but display is smaller than 4K, returns native size
        let scaledHEVCSmall = StreamScaling.scaledDimensions(
            preset: .balanced,
            nativeWidth: 2560,
            nativeHeight: 1440,
            allowsHighResolution: true
        )
        XCTAssertEqual(scaledHEVCSmall.width, 2560)
        XCTAssertEqual(scaledHEVCSmall.height, 1440)

        // Under Ultra preset, does not cap at all (returns native dimensions)
        let scaledUltra = StreamScaling.scaledDimensions(
            preset: .ultra,
            nativeWidth: 5120,
            nativeHeight: 2880,
            allowsHighResolution: false
        )
        XCTAssertEqual(scaledUltra.width, 5120)
        XCTAssertEqual(scaledUltra.height, 2880)
    }

    func testCriticalThermalStateForcesPerformancePreset() {
        let policy = SessionPerformancePolicyService()
        let profile = policy.profile(
            preferredPreset: .quality,
            lowPowerModeEnabled: false,
            thermalState: .critical
        )

        XCTAssertEqual(profile.effectivePreset, .performance)
        XCTAssertEqual(profile.targetFrameRate, 12)
        XCTAssertEqual(profile.throttleReason, .thermalCritical)
    }

    @MainActor
    func testSessionModeControllerTransitions() {
        let controller = HostSessionModeController()

        XCTAssertEqual(controller.mode, .fullControl)
        controller.setMode(.viewOnly)
        XCTAssertEqual(controller.mode, .viewOnly)
        XCTAssertEqual(controller.currentMode, .viewOnly)
    }

    func testEventLogExportRedactsSensitiveMetadata() throws {
        let exporter = EventLogExportService()
        let item = EventLogItem(
            severity: .info,
            category: "Auth",
            message: "token=abc123 bearer xyz",
            metadata: [
                "fingerprint": "123456789",
                "note": "password=hunter2"
            ]
        )

        let url = try exporter.export(
            items: [item],
            destinationDirectory: FileManager.default.temporaryDirectory,
            filePrefix: "redaction-test"
        )
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("[REDACTED]"))
        XCTAssertFalse(text.contains("abc123"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("123456789"))
    }

    func testScreenshotServiceIsExplicitWhenUnsupported() throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        let service = SessionScreenshotService()

        #if canImport(UIKit)
        XCTAssertNoThrow(try service.capture(pixelBuffer: XCTUnwrap(pixelBuffer)))
        #else
        XCTAssertThrowsError(try service.capture(pixelBuffer: XCTUnwrap(pixelBuffer)))
        #endif
    }
}

final class SessionModeRouterTests: XCTestCase {
    @MainActor
    func testViewOnlyModeBlocksHostInputInjection() async throws {
        let sessionManager = RouterTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeController = HostSessionModeController(mode: .viewOnly)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeController
        )

        let sessionID = UUID()
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(
            try DataChannelEnvelope.controlAuth(
                ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
            )
        )
        let envelope = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(
                sessionID: sessionID,
                command: .text(TextInputCommand(text: "blocked"))
            )
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(inputService.snapshotCommands().isEmpty)
        XCTAssertEqual(router.commandsRejected, 1)
        router.stopListening()
    }
}

final class LockStateRouterTests: XCTestCase {
    @MainActor
    private func makeRouter(lockState: HostLockState = .unlockedActiveSession) -> (HostInputCommandRouter, RouterTestSessionManager, RecordingInputInjectionService, String) {
        let sessionManager = RouterTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeController = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeController
        )
        router.lockStateProvider = { lockState }
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        return (router, sessionManager, inputService, token)
    }

    @MainActor
    func testInputCommandPassesThroughWhenUnlocked() async throws {
        let (router, sessionManager, inputService, token) = makeRouter(lockState: .unlockedActiveSession)
        let sessionID = UUID()
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))
        let envelope = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "hello")))
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(inputService.snapshotCommands().isEmpty, "Command should be injected when unlocked")
        XCTAssertEqual(router.commandsRejected, 0)
        router.stopListening()
    }

    @MainActor
    func testInputCommandIsRejectedWhenLocked() async throws {
        let currentLockState = LockedTestValue<HostLockState>(.lockedOrLoginWindow)
        let sessionManager = RouterTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeController = HostSessionModeController(mode: .fullControl)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeController
        )
        router.lockStateProvider = { currentLockState.get() }
        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        let sessionID = UUID()
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))
        let envelope = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "password")))
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(inputService.snapshotCommands().isEmpty, "Command must not be injected while Mac is locked")
        XCTAssertEqual(router.commandsRejected, 1)

        // Unlock and verify subsequent commands are accepted
        currentLockState.set(.unlockedActiveSession)
        let envelope2 = try DataChannelEnvelope.inputCommand(
            InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "hello")))
        ).authenticated(using: token, counter: 2)
        try sessionManager.emit(try XCTUnwrap(envelope2))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(inputService.snapshotCommands().isEmpty, "Command should be injected after unlock")

        router.stopListening()
    }

    @MainActor
    func testUnlockPasswordIsAcceptedWhenLocked() async throws {
        let sessionManager = RouterTestSessionManager()
        let inputService = RecordingInputInjectionService()
        let eventLogStore = RecordingEventLogStore()
        let modeController = HostSessionModeController(mode: .viewOnly)
        let router = HostInputCommandRouter(
            inputService: inputService,
            webRTCSessionManager: sessionManager,
            eventLogStore: eventLogStore,
            modeProvider: modeController
        )
        let recorder = PasswordRecorder()
        router.lockStateProvider = { .lockedOrLoginWindow }
        router.onUnlockPassword = { password in
            await recorder.record(password)
        }

        let token = ConnectionSecurity.tokenToHex(ConnectionSecurity.generateSessionToken())
        let sessionID = UUID()
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))
        let envelope = try DataChannelEnvelope.unlockPassword(
            UnlockPasswordMessage(sessionID: sessionID, password: "correct horse")
        ).authenticated(using: token, counter: 1)
        try sessionManager.emit(try XCTUnwrap(envelope))

        try await Task.sleep(nanoseconds: 150_000_000)
        let recordedPasswords = await recorder.snapshot()
        XCTAssertEqual(recordedPasswords, ["correct horse"])
        XCTAssertTrue(inputService.snapshotCommands().isEmpty, "Unlock password should use the dedicated unlock handler")

        router.stopListening()
    }

    @MainActor
    func testRouterDoesNotCrashWhenLockStateChangesRapidly() async throws {
        let (router, sessionManager, _, token) = makeRouter(lockState: .unlockedActiveSession)
        let sessionID = UUID()
        let toggleState = LockedTestValue<HostLockState>(.unlockedActiveSession)
        router.lockStateProvider = { toggleState.get() }
        router.startListening(sessionID: sessionID, expectedSessionTokenHex: token)
        try sessionManager.emit(try DataChannelEnvelope.controlAuth(
            ControlChannelAuthMessage(sessionID: sessionID, sessionToken: token)
        ))

        // Rapid toggle lock/unlock 10 times while emitting commands
        for i in 0..<10 {
            toggleState.set(i.isMultiple(of: 2) ? .lockedOrLoginWindow : .unlockedActiveSession)
            let envelope = try DataChannelEnvelope.inputCommand(
                InputCommandMessage(sessionID: sessionID, command: .text(TextInputCommand(text: "x")))
            ).authenticated(using: token, counter: UInt64(i + 1))
            try sessionManager.emit(try XCTUnwrap(envelope))
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        // No crash; processed + rejected should equal total emitted
        XCTAssertEqual(router.commandsProcessed + router.commandsRejected, 10)
        router.stopListening()
    }
}

private actor PasswordRecorder {
    private var passwords: [String] = []

    func record(_ password: String) {
        passwords.append(password)
    }

    func snapshot() -> [String] {
        passwords
    }
}

private final class RouterTestSessionManager: WebRTCSessionManaging, @unchecked Sendable {
    var connectionState: ConnectionState = .connected
    var peerConnectionState: PeerConnectionState = .connected
    var dataChannelState: DataChannelState = .open
    var mediaChannelReadiness: MediaChannelReadiness = MediaChannelReadiness(dataChannelState: .open, videoTrackAttached: true, audioTrackAttached: false)
    var streamDiagnostics: StreamDiagnostics = StreamDiagnostics()
    var videoFrameSubscriberCount: Int = 0

    private let lock = NSLock()
    private var dataContinuation: AsyncStream<DataChannelEnvelope>.Continuation?
    private var pendingEnvelopes: [DataChannelEnvelope] = []

    func prepareSession(id: UUID, role: WebRTCSessionRole) async throws {}
    func createOffer(sessionID: UUID, qualityPreset: StreamQualityPreset, displayID: String?) async throws -> SessionOfferMessage {
        SessionOfferMessage(sessionID: sessionID, sdp: "", qualityPreset: qualityPreset)
    }
    func applyRemoteOffer(_ message: SessionOfferMessage) async throws -> SessionAnswerMessage {
        SessionAnswerMessage(sessionID: message.sessionID, sdp: "")
    }
    func applyRemoteAnswer(_ message: SessionAnswerMessage) async throws {}
    func addRemoteCandidate(_ message: ICECandidateMessage) async throws {}
    func closeSession() async {}
    func sendInputCommand(_ message: InputCommandMessage) async throws {}
    func sendDataMessage(_ message: DataChannelEnvelope) throws {}
    func configureControlChannelAuth(sessionTokenHex: String?) {}
    func localICECandidates() -> AsyncStream<ICECandidateMessage> {
        AsyncStream { continuation in continuation.finish() }
    }
    func attachVideoSource(_ source: (any VideoFrameSource)?) {}
    func sendVideoFrame(_ frame: VideoFrameData) throws {}
    func receivedVideoFrames() -> AsyncStream<VideoFrameData> {
        AsyncStream { continuation in continuation.finish() }
    }
    func connectionStateUpdates() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.connected)
        }
    }

    func dataChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { continuation in
            continuation.yield(.open)
        }
    }

    func videoChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { continuation in continuation.finish() }
    }

    func receiveDataMessages() -> AsyncStream<DataChannelEnvelope> {
        AsyncStream { continuation in
            let pending: [DataChannelEnvelope]
            lock.lock()
            dataContinuation = continuation
            pending = pendingEnvelopes
            pendingEnvelopes.removeAll()
            lock.unlock()
            pending.forEach { continuation.yield($0) }
        }
    }

    func emit(_ envelope: DataChannelEnvelope) throws {
        lock.lock()
        let continuation = dataContinuation
        if continuation == nil {
            pendingEnvelopes.append(envelope)
        }
        lock.unlock()
        continuation?.yield(envelope)
    }
}
