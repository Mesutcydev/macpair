import Foundation
import Network
import SwiftUI
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif
import OSLog
import CaptureEngine
import Diagnostics
import Discovery
import EncodeEngine
import InputControl
import Permissions
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
import HostWidgetShared
#if os(macOS)
import ServiceManagement
import IOKit.pwr_mgt
import ApplicationServices
#endif

@MainActor
final class HostAppEnvironment: ObservableObject {
    /// Set when the real environment is constructed, so the app delegate can
    /// reach it to start the widget bridge independent of any window/scene.
    static weak var shared: HostAppEnvironment?
    private var widgetBridge: HostWidgetBridge?

    private enum Keys {
        static let sessionMode = "com.remotedesktop.host.sessionMode"
        static let lowPowerModeEnabled = "com.remotedesktop.host.lowPowerModeEnabled"
        static let terminalModeEnabled = "com.remotedesktop.host.terminalModeEnabled"
        static let keepAwakeEnabled = "com.remotedesktop.host.keepAwakeEnabled"
    }

    struct TrustPrompt: Identifiable, Equatable {
        let id: UUID
        let displayName: String
        let fingerprint: String
    }

    let hostIdentity: HostIdentity
    let productMode: HostProductMode
    let captureEngine: any CaptureEngineProtocol
    let encoderPipeline: any EncoderPipelineProtocol
    let displayLayoutProvider: any DisplayLayoutProviding
    let inputInjectionService: any InputInjectionServiceProtocol
    let permissionService: any PermissionServiceProtocol
    let runtimePolicy: MacHostRuntimePolicy
    let peerTrustGate: PeerTrustGate
    let trustedPeerStore: any TrustedPeerStoreProtocol
    let eventLogStore: any EventLogStoreProtocol
    let signalingService: any SessionCoordinatorSignaling
    let webRTCSessionManager: any WebRTCSessionManaging
    let discoveryAdvertiser: any HostDiscoveryAdvertiserProtocol
    let permissionsViewModel: HostPermissionsViewModel
    let discoveryAdvertiserViewModel: DiscoveryAdvertiserViewModel
    let streamingCoordinator: HostStreamingCoordinator
    let inputCommandRouter: HostInputCommandRouter
    let sessionCoordinator: HostSessionCoordinator
    let recordingService: SessionRecordingService
    let sessionModeController: HostSessionModeController
    #if os(macOS)
    let lockStateMonitor: LockStateMonitor
    #endif
    let thermalMonitor: ThermalMonitorService
    let lowPowerModeService: LowPowerModeService
    let performanceStateController: HostPerformanceStateController
    var fileTransferSettings: HostFileTransferSettingsStore
    var fileTransferStore: HostFileTransferStore
    var fileTransferManager: HostFileTransferManager
    var outgoingFileTransferController: HostOutgoingFileTransferController
    #if os(macOS)
    let audioPipeline: HostAudioCapturePipeline
    let terminalService: HostTerminalService
    let browserControlService: HostBrowserControlService
    #endif

    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.remotedesktop.host.pathmonitor")

    @Published private(set) var pendingTrustPrompt: TrustPrompt?
    /// Deadline for the currently-pending trust prompt.  The dashboard banner
    /// uses this to render a live countdown so the host operator knows how
    /// long they have to act before the request auto-rejects.
    @Published private(set) var pendingTrustPromptDeadline: Date?
    @Published var startAtLoginEnabled: Bool = false
    @Published var startAtLoginErrorMessage: String?
    @Published var manualLowPowerModeEnabled: Bool
    /// Terminal Mode is opt-in: even an authenticated client can't spawn a
    /// shell unless the user explicitly turns it on in host settings.
    @Published var terminalModeEnabled: Bool
    /// Loopback browser-control status. Safari access is deliberately separate
    /// from the WebRTC media session and is exposed through Tailscale Serve.
    #if os(macOS)
    @Published private(set) var browserControlStatus = HostBrowserControlStatus(
        running: false,
        port: nil,
        pairingCode: "",
        pairingCodeExpiresAt: .distantPast,
        lastError: nil
    )
    #endif
    /// When on, hold a power assertion so this Mac never idle-sleeps while the host runs — keeping it
    /// reachable for remote connections. This is the practical answer for an Apple-Silicon Mac on
    /// Wi-Fi with no Sleep Proxy, which the OS cannot wake from sleep at all (so we keep it awake
    /// instead of relying on Wake-on-LAN). Opt-in; best on a desktop or a Mac left on power.
    @Published var keepAwakeEnabled: Bool

    private var trustPromptContinuation: CheckedContinuation<Bool, Never>?
    private var cancellables: Set<AnyCancellable> = []
    #if os(macOS)
    private let launchAtLoginManager = HostLaunchAtLoginManager()
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var streamingAssertionID: IOPMAssertionID = 0
    /// Held while `keepAwakeEnabled` is on — independent of the streaming assertion so the two
    /// never clobber each other's ID.
    private var keepAwakeAssertionID: IOPMAssertionID = 0
    private var wasRunningBeforeSleep = false
    /// Held for the host's whole lifetime to keep macOS App Nap from suspending the process
    /// while it sits idle in the background. App Nap is separate from sleep: a napped host
    /// stops servicing its incoming-connection listener, so a client could discover the host
    /// ("online") yet fail to connect until some unrelated activity woke the process — the
    /// "unreachable over Tailscale after a while, fixed by any inbound connection" bug.
    /// `.userInitiatedAllowingIdleSystemSleep` blocks App Nap but still lets the Mac sleep
    /// normally (forcing the Mac awake is the separate Keep-Mac-Awake assertion).
    private var appNapActivity: NSObjectProtocol?
    #endif
    /// Retains the bridge between capture engine and encoder so the weak
    /// reference inside ScreenCaptureEngine doesn't nil out.
    private var encoderCaptureFrameBridge: AnyObject?

    init(
        hostIdentity: HostIdentity,
        captureEngine: any CaptureEngineProtocol,
        encoderPipeline: any EncoderPipelineProtocol,
        displayLayoutProvider: any DisplayLayoutProviding,
        inputInjectionService: any InputInjectionServiceProtocol,
        permissionService: any PermissionServiceProtocol,
        runtimePolicy: MacHostRuntimePolicy,
        peerTrustGate: PeerTrustGate,
        trustedPeerStore: any TrustedPeerStoreProtocol,
        eventLogStore: any EventLogStoreProtocol,
        signalingService: any SessionCoordinatorSignaling,
        webRTCSessionManager: any WebRTCSessionManaging,
        discoveryAdvertiser: any HostDiscoveryAdvertiserProtocol,
        productMode: HostProductMode = .full,
        recordingService: SessionRecordingService = SessionRecordingService()
    ) {
        let preferredMode = UserDefaults.standard.string(forKey: Keys.sessionMode)
            .flatMap(SessionControlMode.init(rawValue:))
            ?? .fullControl
        let storedMode = runtimePolicy.enforcedSessionMode ?? preferredMode
        let storedLowPower = UserDefaults.standard.bool(forKey: Keys.lowPowerModeEnabled)
        // Terminal Mode defaults to OFF — opt-in only.
        let storedTerminalMode = productMode.isTerminalOnly
            ? true
            : UserDefaults.standard.bool(forKey: Keys.terminalModeEnabled)
        // Keep-awake defaults to OFF — opt-in only.
        let storedKeepAwake = UserDefaults.standard.bool(forKey: Keys.keepAwakeEnabled)
        let canonicalHostIdentity: HostIdentity

        if let bonjourSignaling = signalingService as? BonjourSignalingService,
           let signalingFingerprint = bonjourSignaling.identityService?.fingerprint,
           !signalingFingerprint.isEmpty {
            if hostIdentity.publicKeyFingerprint != signalingFingerprint {
                Logger(subsystem: "com.remotedesktop.host", category: "Identity")
                    .error("Host identity fingerprint mismatch detected; canonicalizing advertised fingerprint from signaling identity")
            }

            var updatedHostIdentity = hostIdentity
            updatedHostIdentity.publicKeyFingerprint = signalingFingerprint
            canonicalHostIdentity = updatedHostIdentity
        } else {
            canonicalHostIdentity = hostIdentity
        }

        self.hostIdentity = canonicalHostIdentity
        self.productMode = productMode
        self.captureEngine = captureEngine
        self.encoderPipeline = encoderPipeline
        self.displayLayoutProvider = displayLayoutProvider
        self.inputInjectionService = inputInjectionService
        self.permissionService = permissionService
        self.runtimePolicy = runtimePolicy
        self.peerTrustGate = peerTrustGate
        self.trustedPeerStore = trustedPeerStore
        self.eventLogStore = eventLogStore
        self.signalingService = signalingService
        self.webRTCSessionManager = webRTCSessionManager
        self.discoveryAdvertiser = discoveryAdvertiser
        self.sessionModeController = HostSessionModeController(mode: storedMode)
        #if os(macOS)
        self.lockStateMonitor = LockStateMonitor()
        #endif
        self.thermalMonitor = ThermalMonitorService()
        self.lowPowerModeService = LowPowerModeService()
        self.recordingService = recordingService
        self.performanceStateController = HostPerformanceStateController(
            thermalState: .nominal,
            lowPowerModeEnabled: storedLowPower
        )
        self.fileTransferSettings = HostFileTransferSettingsStore(
            supportsDefaultDownloadsLocation: !runtimePolicy.isSandboxedDistribution
        )
        self.fileTransferStore = HostFileTransferStore()
        self.fileTransferManager = HostFileTransferManager(
            settings: self.fileTransferSettings,
            store: self.fileTransferStore
        )
        self.outgoingFileTransferController = HostOutgoingFileTransferController(
            webRTCSessionManager: webRTCSessionManager,
            hostIdentity: canonicalHostIdentity
        )
        #if os(macOS)
        let pipeline = HostAudioCapturePipeline()
        self.audioPipeline = pipeline
        self.terminalService = HostTerminalService()
        self.browserControlService = HostBrowserControlService()
        #endif
        self.manualLowPowerModeEnabled = storedLowPower
        self.terminalModeEnabled = storedTerminalMode
        self.keepAwakeEnabled = storedKeepAwake
        self.permissionsViewModel = HostPermissionsViewModel(
            permissionService: permissionService,
            eventLogStore: eventLogStore
        )
        self.streamingCoordinator = HostStreamingCoordinator(
            encoderPipeline: encoderPipeline,
            webRTCSessionManager: webRTCSessionManager,
            eventLogStore: eventLogStore,
            recordingService: self.recordingService
        )
        self.inputCommandRouter = HostInputCommandRouter(
            inputService: inputInjectionService,
            webRTCSessionManager: webRTCSessionManager,
            eventLogStore: eventLogStore,
            modeProvider: self.sessionModeController
        )
        self.discoveryAdvertiserViewModel = DiscoveryAdvertiserViewModel(
            hostIdentity: canonicalHostIdentity,
            advertiser: discoveryAdvertiser,
            productMode: productMode
        )
        self.sessionCoordinator = HostSessionCoordinator(
            hostIdentity: canonicalHostIdentity,
            captureEngine: captureEngine,
            encoderPipeline: encoderPipeline,
            displayLayoutProvider: displayLayoutProvider,
            permissionService: permissionService,
            webRTCSessionManager: webRTCSessionManager,
            peerTrustGate: peerTrustGate,
            streamingCoordinator: self.streamingCoordinator,
            inputCommandRouter: self.inputCommandRouter,
            eventLogStore: eventLogStore,
            signalingService: signalingService,
            sessionModeController: self.sessionModeController,
            performanceStateController: self.performanceStateController,
            fileTransferManager: self.fileTransferManager,
            productMode: productMode,
            ensureDiscoveryAdvertising: { [weak discoveryAdvertiserViewModel = self.discoveryAdvertiserViewModel] in
                await discoveryAdvertiserViewModel?.ensureAdvertising()
            }
        )

        self.inputCommandRouter.onFileTransferMessage = { [fileTransferManager = self.fileTransferManager, outgoingFileTransferController = self.outgoingFileTransferController, webRTCSessionManager = self.webRTCSessionManager] message in
            await fileTransferManager.handle(message) { envelope in
                try? webRTCSessionManager.sendDataMessage(envelope)
            }
            await outgoingFileTransferController.handleRemoteMessage(message)
        }
        #if os(macOS)
        self.sessionCoordinator.audioPipeline = pipeline
        #endif

        self.inputCommandRouter.onDisplaySwitchRequest = { [sessionCoordinator = self.sessionCoordinator] message in
            await sessionCoordinator.handleDisplaySwitchRequest(message)
        }
        // Remote login-screen unlock uses the same Accessibility-backed input path as
        // normal control, so it stays unavailable in sandboxed builds.
        if runtimePolicy.supportsRemoteUnlock {
            self.inputCommandRouter.remoteUnlockEnabled = {
                UserDefaults.standard.object(forKey: "host.remoteUnlock.enabled") as? Bool ?? true
            }
            self.inputCommandRouter.onUnlockPassword = { [inputInjectionService = self.inputInjectionService, eventLogStore] password in
                // Type the password then press Return via HID event tap. Pace the
                // characters specifically for loginwindow: posting the full burst and
                // Return back-to-back can make its secure field coalesce/drop characters
                // or process Return before the password events have settled.
                // kCGHIDEventTap posts at the hardware-input level so the loginwindow
                // process receives keystrokes even though it runs as a different user.
                do {
                    for character in password {
                        try await inputInjectionService.inject(.text(TextInputCommand(text: String(character))))
                        try await Task.sleep(for: .milliseconds(18))
                    }
                    try await Task.sleep(for: .milliseconds(80))
                    try await inputInjectionService.inject(.key(KeyCommand(keyCode: 36, action: .down)))
                    try await Task.sleep(for: .milliseconds(20))
                    try await inputInjectionService.inject(.key(KeyCommand(keyCode: 36, action: .up)))
                    Logger(subsystem: "com.remotedesktop.host", category: "RemoteUnlock")
                        .info("Remote unlock keystrokes delivered to loginwindow")
                } catch {
                    // Don't silently swallow: a failed remote unlock keystroke injection
                    // (event tap blocked, login window not focused, etc.) must be visible
                    // in logs and the event log so the operator can diagnose it.
                    Logger(subsystem: "com.remotedesktop.host", category: "RemoteUnlock")
                        .error("Remote unlock keystroke injection failed: \(error.localizedDescription, privacy: .public)")
                    await eventLogStore.append(EventLogItem(
                        severity: .error,
                        category: "Trust",
                        message: "Remote unlock failed: could not inject login keystrokes (\(error.localizedDescription))"
                    ))
                }
            }
        }
        self.inputCommandRouter.onClipboardSync = { text in
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        }
        self.inputCommandRouter.onClipboardRequest = { [weak self] in
            #if os(macOS)
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let sessionID = self.sessionCoordinator.activeSessionID else { return }
                let message = ClipboardSyncMessage(sessionID: sessionID, text: text, source: "host")
                guard let envelope = try? DataChannelEnvelope.clipboardSync(message) else { return }
                try? self.webRTCSessionManager.sendDataMessage(envelope)
            }
            #endif
        }

        // Terminal Mode spawns an interactive login shell and remains behind the
        // operator-controlled Terminal Mode setting.
        #if os(macOS)
        // Terminal Mode: the service writes output envelopes through the
        // WebRTC data channel; the router routes incoming open/input/resize/
        // close envelopes back into the service.
        self.terminalService.sendEnvelope = { [weak webRTCSessionManager = self.webRTCSessionManager] envelope in
            try? webRTCSessionManager?.sendDataMessage(envelope)
        }
        self.inputCommandRouter.onTerminalOpen = { [weak self, weak terminalService = self.terminalService, weak webRTCSessionManager = self.webRTCSessionManager] message in
            // Hard gate: even an authenticated client can't spawn a shell
            // until the user explicitly toggles Terminal Mode on in host
            // settings. We respond with a TerminalClose so the client UI can
            // show a clear "feature disabled" state instead of hanging on
            // "opening shell…".
            let enabled = Task { @MainActor in self?.terminalModeEnabled ?? false }
            Task {
                let isEnabled = await enabled.value
                if !isEnabled {
                    let close = TerminalCloseMessage(
                        sessionID: message.sessionID,
                        terminalID: message.terminalID,
                        reason: "terminal-disabled"
                    )
                    if let envelope = try? DataChannelEnvelope.terminalClose(close) {
                        try? webRTCSessionManager?.sendDataMessage(envelope)
                    }
                    return
                }
                terminalService?.handleOpen(message)
            }
        }
        self.inputCommandRouter.onTerminalInput = { [weak terminalService = self.terminalService] message in
            terminalService?.handleInput(message)
        }
        self.inputCommandRouter.onTerminalResize = { [weak terminalService = self.terminalService] message in
            terminalService?.handleResize(message)
        }
        self.inputCommandRouter.onTerminalClose = { [weak terminalService = self.terminalService] message in
            terminalService?.handleClose(message)
        }
        self.inputCommandRouter.onSessionEnded = { [weak terminalService = self.terminalService] in
            terminalService?.sessionDidEnd()
        }

        #if os(macOS)
        self.browserControlService.terminalModeProvider = { [weak self] in
            self?.terminalModeEnabled ?? false
        }
        self.browserControlService.readClipboard = {
            NSPasteboard.general.string(forType: .string)
        }
        self.browserControlService.writeClipboard = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        self.browserControlService.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.browserControlStatus = status
            }
        }
        self.browserControlStatus = self.browserControlService.currentStatus()
        #endif
        #endif

        if let bonjourSignaling = self.signalingService as? BonjourSignalingService,
           bonjourSignaling.identityService == nil {
            bonjourSignaling.identityService = CryptoIdentityService(tag: "com.remotedesktop.host.p256")
        }

        fileTransferSettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        installTrustApprovalHandler()
        bindPerformanceMonitoring()
        refreshStartAtLoginState()
        #if os(macOS)
        sessionCoordinator.lockStateProvider = { [weak lockStateMonitor = self.lockStateMonitor] in
            lockStateMonitor?.currentLockState ?? .unlockedActiveSession
        }
        sessionCoordinator.lockStatePublisher = lockStateMonitor.$lockState.eraseToAnyPublisher()
        startSleepWakeObservation()
        bindStreamingAssertions()
        // Restore the keep-awake assertion on launch if the user left it enabled, so a Mac that
        // can't be woken remotely (Apple Silicon on Wi-Fi, no Sleep Proxy) stays reachable.
        if keepAwakeEnabled { acquireKeepAwakeAssertion() }
        lockStateMonitor.startMonitoring()
        preventAppNap()
        #endif
        startNetworkMonitoring()
    }

    #if os(macOS)
    /// Keep macOS App Nap from suspending the host while it idles in the background, so its
    /// incoming-connection listener keeps responding (the "reachable then unreachable over
    /// Tailscale until something pokes the Mac" bug). Held for the process lifetime.
    private func preventAppNap() {
        guard appNapActivity == nil else { return }
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
<<<<<<< HEAD
            reason: "MacPair Host stays reachable for incoming remote connections"
=======
            reason: "Vamp Host stays reachable for incoming remote connections"
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
        )
    }
    #endif

    var displayLayoutChanges: AsyncStream<DisplayLayout>? {
        (displayLayoutProvider as? any DisplayLayoutObserving)?.layoutChanges()
    }

    static func placeholder(mode: HostProductMode = .full) -> HostAppEnvironment {
        let cryptoIdentity = CryptoIdentityService(tag: "com.remotedesktop.host.p256")
        let fingerprint = cryptoIdentity.fingerprint
        let host = HostIdentity(
            id: HostIdentity.stableID(publicKeyFingerprint: fingerprint) ?? UUID(),
            displayName: currentHostDisplayName(),
            modelName: "Mac",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: "0.1",
            publicKeyFingerprint: fingerprint
        )
        let services = PlaceholderHostServices()
        let eventLogStore = InMemoryEventLogStore()
        let recordingService = SessionRecordingService()
        let runtimePolicy = currentRuntimePolicy(for: mode)
        #if os(macOS)
        let permissionService: any PermissionServiceProtocol = MacHostPermissionService(policy: runtimePolicy)
        let displayLayoutProvider: any DisplayLayoutProviding = CoreGraphicsDisplayLayoutProvider()
        let captureEngine: any CaptureEngineProtocol
        let encoderPipeline: any EncoderPipelineProtocol
        let encoderBridge: EncoderCaptureFrameBridge?
        if mode.isTerminalOnly {
            // Keep the light product free of ScreenCaptureKit and VideoToolbox
            // initialization. The coordinator never starts these services in
            // terminal-only mode, but using placeholders here also keeps launch
            // and permission checks terminal-only.
            captureEngine = services
            encoderPipeline = services
            encoderBridge = nil
        } else {
            let screenCaptureEngine = ScreenCaptureEngine()
            let encoder = VideoToolboxEncoder()
            let bridge = EncoderCaptureFrameBridge(encoder: encoder)
            bridge.sampleBufferMirroringHandler = { sampleBuffer, _ in
                recordingService.append(sampleBuffer: sampleBuffer)
            }
            screenCaptureEngine.setFrameReceiver(bridge)
            captureEngine = screenCaptureEngine
            encoderPipeline = encoder
            encoderBridge = bridge
        }
        #else
        let permissionService: any PermissionServiceProtocol = services
        let displayLayoutProvider: any DisplayLayoutProviding = services
        let captureEngine: any CaptureEngineProtocol = services
        let encoderPipeline: any EncoderPipelineProtocol = services
        #endif
        #if os(macOS)
        let inputService: any InputInjectionServiceProtocol
        if !mode.isTerminalOnly && runtimePolicy.supportsRemoteInput {
            let inputBridge = CGEventInputBridge()
            let dlp = displayLayoutProvider
            inputService = HostInputInjectionService(
                bridge: inputBridge,
                accessibilityChecker: { AXIsProcessTrusted() },
                layoutProvider: { try await dlp.currentDisplayLayout() }
            )
        } else {
            inputService = DisabledInputInjectionService()
        }
        #else
        let inputService: any InputInjectionServiceProtocol = services
        #endif
        let signalingService = BonjourSignalingService()
        signalingService.identityService = cryptoIdentity
        let peerConnectionProvider = LANPeerConnectionProvider()
        peerConnectionProvider.useFixedDataPort = true
        let webRTCSessionManager = WebRTCSessionManager(peerConnectionProvider: peerConnectionProvider)
        let trustedPeerStore = PersistentTrustedPeerStore()
        let peerTrustGate = PeerTrustGate(store: trustedPeerStore)
        let environment = HostAppEnvironment(
            hostIdentity: host,
            captureEngine: captureEngine,
            encoderPipeline: encoderPipeline,
            displayLayoutProvider: displayLayoutProvider,
            inputInjectionService: inputService,
            permissionService: permissionService,
            runtimePolicy: runtimePolicy,
            peerTrustGate: peerTrustGate,
            trustedPeerStore: trustedPeerStore,
            eventLogStore: eventLogStore,
            signalingService: signalingService,
            webRTCSessionManager: webRTCSessionManager,
            discoveryAdvertiser: BonjourHostDiscoveryAdvertiser(),
            productMode: mode,
            recordingService: recordingService
        )
        #if os(macOS)
        environment.encoderCaptureFrameBridge = encoderBridge
        #endif
        HostAppEnvironment.shared = environment
        return environment
    }

    private static func currentRuntimePolicy(for mode: HostProductMode) -> MacHostRuntimePolicy {
        mode.isTerminalOnly ? .terminalOnly : .current
    }

    private static func currentHostDisplayName() -> String {
        #if os(macOS)
        if let localizedName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localizedName.isEmpty {
            return localizedName
        }
        #endif

        let hostName = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".local", with: "")
        if !hostName.isEmpty {
            return hostName
        }

        return "Mac Host"
    }

    #if os(macOS)
    /// Start the desktop-widget bridge (status publishing + action handling).
    /// Called from the app delegate so it runs regardless of window/scene state.
    func activateWidgetBridge() {
        guard widgetBridge == nil else { return }
        let bridge = HostWidgetBridge(environment: self)
        widgetBridge = bridge
        bridge.start()
        refreshWidgetInstallSuppression()
    }

    /// Re-query whether the desktop widget is installed and hide the dashboard
    /// when it is. Safe to call repeatedly (app launch, become-active, poll).
    func refreshWidgetInstallSuppression() {
        widgetBridge?.checkWidgetInstalled { installed in
            if installed {
                HostWindowCloseBehaviorController.shared.suppressWindowForWidget()
            }
        }
    }

    /// Apply a widget control action against the live runtime. Called directly from
    /// the URL handler when the app is already running, so a button press doesn't have
    /// to round-trip through the shared file + 1 s poll (which depends on the bridge
    /// having started and the app-group container resolving). Falls back to staging the
    /// action on disk when the bridge isn't up yet, so a cold launch still applies it.
    func applyWidgetAction(_ action: HostWidgetAction) {
        if let widgetBridge {
            widgetBridge.handle(action: action)
        } else {
            HostWidgetStore.setPendingAction(action)
        }
    }

    /// Write an "offline" snapshot so the widget reflects that the host app is no
    /// longer running (instead of showing a stale "ready").
    func publishWidgetOffline() {
        let snapshot = HostWidgetSnapshot(
            phase: .idle,
            statusTitle: "host app closed",
<<<<<<< HEAD
            hostName: "macpair host",
=======
            hostName: "vamp host",
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
            primaryAddress: nil,
            addressLabel: nil,
            connectedClient: nil,
            updatedAt: Date()
        )
        HostWidgetStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: HostWidgetConstants.widgetKind)
    }
    #endif

    func startRuntimeIfNeeded() async {
        // Probe only — the dashboard owns the one-shot OS prompt so startup
        // and the blocker poll cannot each open CG/AX sheets.
        await permissionsViewModel.refresh(requestOSPromptIfNeeded: false)
        await discoveryAdvertiserViewModel.startIfNeeded()
        #if os(macOS)
        // Safari access is loopback-only; the operator explicitly exposes it
        // through Tailscale Serve when they want browser control away from the
        // Mac. Starting the local service with the host keeps the QR/code flow
        // predictable without opening a LAN listener.
        browserControlService.start()
        #endif
        await sessionCoordinator.startSession()
    }

    func stopRuntime() async {
        #if os(macOS)
        browserControlService.stop()
        #endif
        await sessionCoordinator.stopSession()
        await discoveryAdvertiserViewModel.stop()
    }

    #if os(macOS)
    func rotateBrowserPairingCode() {
        browserControlService.rotatePairingCode()
    }
    #endif

    func resolveTrustPrompt(approved: Bool) {
        trustPromptContinuation?.resume(returning: approved)
        trustPromptContinuation = nil
        pendingTrustPrompt = nil
        pendingTrustPromptDeadline = nil
    }

    func resolveFileTransferPrompt(approved: Bool) {
        fileTransferStore.resolvePrompt(approved: approved)
    }

    func sendFileToConnectedClient() async {
        guard let sessionID = sessionCoordinator.activeSessionID,
              sessionCoordinator.phase == .streaming else {
            outgoingFileTransferController.dismissTransfer()
            return
        }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        panel.message = "Choose a file to send to the connected client Mac. The client Mac user must approve and choose where to save it."
        if panel.runModal() == .OK, let url = panel.url {
            outgoingFileTransferController.sendFile(url: url, sessionID: sessionID)
        }
        #endif
    }

    func refreshStartAtLoginState() {
        #if os(macOS)
        startAtLoginEnabled = launchAtLoginManager.isEnabled
        if launchAtLoginManager.requiresApproval {
            startAtLoginErrorMessage = "Start at Login needs approval in System Settings > General > Login Items."
        } else {
            startAtLoginErrorMessage = nil
        }
        #endif
    }

    func setStartAtLogin(_ enabled: Bool) {
        #if os(macOS)
        if enabled == startAtLoginEnabled {
            return
        }
        do {
            try launchAtLoginManager.setEnabled(enabled)
            startAtLoginEnabled = launchAtLoginManager.isEnabled
            if enabled && launchAtLoginManager.requiresApproval {
                startAtLoginErrorMessage = "Start at Login is pending approval in System Settings > General > Login Items."
            } else {
                startAtLoginErrorMessage = nil
            }
        } catch {
            startAtLoginEnabled = launchAtLoginManager.isEnabled
            startAtLoginErrorMessage = "Failed to update Start at Login: \(error.localizedDescription)"
        }
        #endif
    }

    func setSessionMode(_ mode: SessionControlMode) {
        let resolvedMode = runtimePolicy.enforcedSessionMode ?? mode
        sessionModeController.setMode(resolvedMode)
        UserDefaults.standard.set(resolvedMode.rawValue, forKey: Keys.sessionMode)
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "SessionMode",
                message: "Host session mode changed to \(resolvedMode.rawValue)"
            ))
            await sessionCoordinator.publishHostStatusUpdate()
        }
    }

    func setKeepAwakeEnabled(_ isEnabled: Bool) {
        keepAwakeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Keys.keepAwakeEnabled)
        #if os(macOS)
        if isEnabled { acquireKeepAwakeAssertion() } else { releaseKeepAwakeAssertion() }
        #endif
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Power",
                message: "Keep Mac awake & reachable \(isEnabled ? "enabled" : "disabled")"
            ))
        }
    }

    func setManualLowPowerModeEnabled(_ isEnabled: Bool) {
        manualLowPowerModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Keys.lowPowerModeEnabled)
        performanceStateController.setLowPowerModeEnabled(isEnabled || lowPowerModeService.systemLowPowerModeEnabled)
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Power",
                message: "Host low-power mode \(isEnabled ? "enabled" : "disabled")"
            ))
            await sessionCoordinator.applyPerformanceProfileIfNeeded()
        }
    }

    func setTerminalModeEnabled(_ isEnabled: Bool) {
        if productMode.isTerminalOnly {
            terminalModeEnabled = true
            return
        }
        terminalModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Keys.terminalModeEnabled)
        #if os(macOS)
        // Turning the feature off mid-session must kill any live shell.
        if !isEnabled {
            terminalService.sessionDidEnd(notifyClient: true, reason: "terminal-disabled")
        }
        #endif
        Task {
            await eventLogStore.append(EventLogItem(
                severity: .info,
                category: "Terminal",
                message: "Terminal Mode \(isEnabled ? "enabled" : "disabled")"
            ))
        }
    }

    private func installTrustApprovalHandler() {
        Task { [weak self] in
            guard let self else { return }
            await peerTrustGate.setApprovalHandler { [weak self] peerID, displayName, fingerprint in
                guard let self else { return false }
                return await self.presentTrustPrompt(
                    peerID: peerID,
                    displayName: displayName,
                    fingerprint: fingerprint
                )
            }
        }
    }

    private func presentTrustPrompt(peerID: UUID, displayName: String, fingerprint: String) async -> Bool {
        guard trustPromptContinuation == nil else { return false }
        pendingTrustPrompt = TrustPrompt(id: peerID, displayName: displayName, fingerprint: fingerprint)
        pendingTrustPromptDeadline = Date().addingTimeInterval(RemoteDesktopConstants.trustPromptTimeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                trustPromptContinuation = continuation
            }
        } onCancel: {
            // When the trust timeout fires, dismiss the prompt and unblock the continuation
            Task { @MainActor [weak self] in
                self?.resolveTrustPrompt(approved: false)
            }
        }
    }

    private func bindPerformanceMonitoring() {
        thermalMonitor.$thermalState
            .sink { [weak self] thermalState in
                guard let self else { return }
                self.performanceStateController.setThermalState(thermalState)
                Task {
                    await self.eventLogStore.append(EventLogItem(
                        severity: thermalState == .serious || thermalState == .critical ? .warning : .info,
                        category: "Thermal",
                        message: "Thermal state changed to \(thermalState.rawValue)"
                    ))
                    await self.sessionCoordinator.applyPerformanceProfileIfNeeded()
                    await self.sessionCoordinator.publishHostStatusUpdate()
                }
            }
            .store(in: &cancellables)

        lowPowerModeService.$systemLowPowerModeEnabled
            .sink { [weak self] isSystemEnabled in
                guard let self else { return }
                self.performanceStateController.setLowPowerModeEnabled(self.manualLowPowerModeEnabled || isSystemEnabled)
                Task {
                    await self.eventLogStore.append(EventLogItem(
                        severity: .info,
                        category: "Power",
                        message: "System low-power mode \(isSystemEnabled ? "enabled" : "disabled")"
                    ))
                    await self.sessionCoordinator.applyPerformanceProfileIfNeeded()
                    await self.sessionCoordinator.publishHostStatusUpdate()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Sleep / Wake

    #if os(macOS)
    private func startSleepWakeObservation() {
        let nc = NSWorkspace.shared.notificationCenter

        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wasRunningBeforeSleep = (self.sessionCoordinator.phase != .idle)
                if self.wasRunningBeforeSleep {
                    await self.stopRuntime()
                }
                self.releaseStreamingAssertion()
            }
        }

        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.wasRunningBeforeSleep else { return }
                self.wasRunningBeforeSleep = false
                // Brief delay so networking stack is fully up after wake
                try? await Task.sleep(for: .seconds(1.5))
                await self.startRuntimeIfNeeded()
            }
        }
    }

    private func bindStreamingAssertions() {
        sessionCoordinator.$phase
            .sink { [weak self] phase in
                guard let self else { return }
                if phase == .streaming {
                    self.acquireStreamingAssertion()
                } else {
                    self.releaseStreamingAssertion()
                }
            }
            .store(in: &cancellables)
    }

    private func acquireStreamingAssertion() {
        guard streamingAssertionID == 0 else { return }
        // Prevent *display* idle sleep while streaming (this also keeps the system awake). A sleeping
        // display stops producing capture frames, freezing the remote view — so the display must stay
        // on for the duration of the stream, not just the system.
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
<<<<<<< HEAD
            "MacPair Host is actively streaming to a remote client" as CFString,
=======
            "Vamp Host is actively streaming to a remote client" as CFString,
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
            &streamingAssertionID
        )
    }

    private func releaseStreamingAssertion() {
        guard streamingAssertionID != 0 else { return }
        IOPMAssertionRelease(streamingAssertionID)
        streamingAssertionID = 0
    }

    private func acquireKeepAwakeAssertion() {
        guard keepAwakeAssertionID == 0 else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
<<<<<<< HEAD
            "MacPair Host is keeping this Mac awake so it stays reachable for remote connections" as CFString,
=======
            "Vamp Host is keeping this Mac awake so it stays reachable for remote connections" as CFString,
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
            &keepAwakeAssertionID
        )
    }

    private func releaseKeepAwakeAssertion() {
        guard keepAwakeAssertionID != 0 else { return }
        IOPMAssertionRelease(keepAwakeAssertionID)
        keepAwakeAssertionID = 0
    }
    #endif

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Wi-Fi-only (no wired Ethernet) means an Apple-Silicon Mac can't be magic-packet woken —
            // feed this to the advertiser so the client can warn instead of offering a doomed wake.
            let isWiFiOnly = path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                await self.discoveryAdvertiserViewModel.updateActiveInterface(isWiFiOnly: isWiFiOnly)
                let info = await Task.detached(priority: .utility) {
                    getTailscaleConnectionInfo()
                }.value
                await self.discoveryAdvertiserViewModel.updateTailscaleIdentity(hostname: info?.dnsName, ip: info?.ipAddress)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    deinit {
        pathMonitor.cancel()
        // Always release power assertions on teardown — otherwise a streaming session or the
        // keep-awake toggle that was active at quit can hold the Mac awake indefinitely after exit.
        if streamingAssertionID != 0 {
            IOPMAssertionRelease(streamingAssertionID)
        }
        if keepAwakeAssertionID != 0 {
            IOPMAssertionRelease(keepAwakeAssertionID)
        }
    }
}

final class PlaceholderHostServices:
    CaptureEngineProtocol,
    EncoderPipelineProtocol,
    DisplayLayoutProviding,
    InputInjectionServiceProtocol,
    PermissionServiceProtocol,
    TrustedPeerStoreProtocol,
    EventLogStoreProtocol,
    SignalingServiceProtocol,
    WebRTCSessionManaging
{
    var isCapturing: Bool { false }
    var captureState: CaptureState { .stopped }
    var diagnostics: CaptureDiagnostics { CaptureDiagnostics() }
    var isEncoding: Bool { false }
    var encoderState: EncoderState { .idle }
    var encoderDiagnostics: EncoderDiagnostics { EncoderDiagnostics() }
    var connectionState: ConnectionState { .idle }
    var peerConnectionState: PeerConnectionState { .closed }
    var dataChannelState: DataChannelState { .closed }
    var mediaChannelReadiness: MediaChannelReadiness { MediaChannelReadiness() }

    func startCapture(displayID: String, qualityPreset: StreamQualityPreset, allowsHighResolution: Bool) async throws {}
    func stopCapture() async {}
    func setFrameReceiver(_ receiver: (any CaptureFrameReceiver)?) {}
    func setAudioReceiver(_ receiver: (any CaptureAudioReceiver)?) {}
    func stateChanges() -> AsyncStream<CaptureState> {
        AsyncStream { $0.yield(.stopped); $0.finish() }
    }
    func configure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws {}
    func reconfigure(for display: DisplayDescriptor, qualityPreset: StreamQualityPreset, codec: EncodedFrameCodec) async throws {}
    func startEncoding() async throws {}
    func flush() async throws {}
    func stopEncoding() async {}
    func setEncodedFrameReceiver(_ receiver: (any EncodedFrameReceiver)?) {}
    func stateChanges() -> AsyncStream<EncoderState> {
        AsyncStream { $0.yield(.idle); $0.finish() }
    }
    func forceKeyframe() {}
    func currentDisplayLayout() async throws -> DisplayLayout { .placeholder }
    func inject(_ command: InputCommand) async throws {}
    func perform(_ shortcut: ShortcutCommand) async throws {}
    func currentStates() async -> [PermissionState] { PermissionKind.allCases.map { PermissionState(kind: $0, authorizationState: .unknown) } }
    func refreshState(for kind: PermissionKind) async -> PermissionState { PermissionState(kind: kind, authorizationState: .unknown) }
    func requestPermission(for kind: PermissionKind) async throws -> PermissionState { PermissionState(kind: kind, authorizationState: .unknown) }
    func trustedPeers() async throws -> [TrustedPeer] { [] }
    func trustPeer(_ peer: TrustedPeer) async throws {}
    func revokePeer(id: UUID) async throws {}
    func append(_ item: EventLogItem) async {}
    func recentItems(limit: Int) async -> [EventLogItem] { [] }
    func removeAll() async {}
    func startAdvertising(host: HostIdentity) async throws {}
    func stopAdvertising() async {}
    func sendHello(_ message: HelloMessage, to host: HostIdentity) async throws {}
    func sendOffer(_ message: SessionOfferMessage, to host: HostIdentity) async throws {}
    func sendAnswer(_ message: SessionAnswerMessage, to client: ClientIdentity) async throws {}
    func sendCandidate(_ message: ICECandidateMessage) async throws {}
    func prepareSession(id: UUID, role: WebRTCSessionRole) async throws {}
    func createOffer(sessionID: UUID, qualityPreset: StreamQualityPreset, displayID: String?) async throws -> SessionOfferMessage {
        SessionOfferMessage(sessionID: sessionID, sdp: "", qualityPreset: qualityPreset)
    }
    func applyRemoteOffer(_ message: SessionOfferMessage) async throws -> SessionAnswerMessage {
        SessionAnswerMessage(sessionID: message.sessionID, sdp: "")
    }
    func applyRemoteAnswer(_ message: SessionAnswerMessage) async throws {}
    func addRemoteCandidate(_ message: ICECandidateMessage) async throws {}
    func sendInputCommand(_ message: InputCommandMessage) async throws {}
    func sendDataMessage(_ message: DataChannelEnvelope) throws {}
    func configureControlChannelAuth(sessionTokenHex: String?) {}
    func receiveDataMessages() -> AsyncStream<DataChannelEnvelope> {
        AsyncStream { $0.finish() }
    }
    func localICECandidates() -> AsyncStream<ICECandidateMessage> {
        AsyncStream { $0.finish() }
    }
    func attachVideoSource(_ source: (any VideoFrameSource)?) {}
    func sendVideoFrame(_ frame: VideoFrameData) throws {}
    func receivedVideoFrames() -> AsyncStream<VideoFrameData> {
        AsyncStream { $0.finish() }
    }
    var streamDiagnostics: StreamDiagnostics { StreamDiagnostics() }
    var videoFrameSubscriberCount: Int { 0 }
    func connectionStateUpdates() -> AsyncStream<ConnectionState> {
        AsyncStream { $0.yield(.idle); $0.finish() }
    }
    func dataChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { $0.yield(.closed); $0.finish() }
    }
    func videoChannelStateUpdates() -> AsyncStream<DataChannelState> {
        AsyncStream { $0.finish() }
    }
    func closeSession() async {}
}

final class DisabledInputInjectionService: InputInjectionServiceProtocol {
    func inject(_ command: InputCommand) async throws {}
    func perform(_ shortcut: ShortcutCommand) async throws {}
}

private extension DisplayLayout {
    static var placeholder: DisplayLayout {
        let display = DisplayDescriptor(
            id: "main",
            name: "Main Display",
            frame: DesktopRect(origin: DesktopPoint(x: 0, y: 0), size: DesktopSize(width: 1440, height: 900)),
            pixelSize: DesktopSize(width: 2880, height: 1800),
            scaleFactor: 2,
            refreshRate: 60,
            isPrimary: true
        )
        return DisplayLayout(displays: [display], primaryDisplayID: display.id, virtualBounds: display.frame)
    }
}

#if os(macOS)
@MainActor
final class HostLaunchAtLoginManager {
    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    var requiresApproval: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }
        return false
    }

    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw LaunchAtLoginError.unsupportedOS
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case unsupportedOS

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Start at Login requires macOS 13 or newer."
        }
    }
}
#endif
