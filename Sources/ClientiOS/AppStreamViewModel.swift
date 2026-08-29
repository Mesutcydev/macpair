import Combine
import Foundation
import os
import SharedProtocol
import TransportWebRTC

private let appStreamLog = Logger(subsystem: "com.mesutcy.remotedesktop.stream", category: "AppStream")

enum AppStreamApplicationProfile {
    static let terminalDeckHeight: CGFloat = 142

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "com.github.wez.wezterm-gui",
        "dev.warp.warp",
        "dev.warp.warp-stable",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    static func isTerminal(bundleIdentifier: String?, name: String) -> Bool {
        if let bundleIdentifier,
           terminalBundleIDs.contains(bundleIdentifier.lowercased()) {
            return true
        }
        let normalized = name.lowercased()
        return ["terminal", "iterm", "ghostty", "wezterm", "warp", "alacritty", "kitty", "hyper"]
            .contains { normalized.contains($0) }
    }

    static func visibleStreamSize(
        container: CGSize,
        keyboardHeight: CGFloat,
        isTerminal: Bool
    ) -> CGSize {
        guard isTerminal, keyboardHeight > 0 else { return container }
        return CGSize(
            width: container.width,
            height: max(220, container.height - keyboardHeight - terminalDeckHeight))
    }
}

/// Client-side driver for App Streaming. Self-contained: it consumes the broadcast
/// `receiveDataMessages()` stream directly (like `ClientFileTransferManager`), so it needs no
/// changes to `ClientSessionCoordinator`'s dispatch. It sends `applicationList` /
/// `streamTargetSwitch` requests (auto-authenticated by `sendDataMessage`) and turns the host's
/// results — including the unsolicited target-lost result — into an explicit UI state machine.
@MainActor
final class AppStreamViewModel: ObservableObject {

    /// Explicit session state (no conflicting booleans). `.streaming` means the host confirmed
    /// the target; the view treats it as *interactive* once `sessionCoordinator.phase == .receiving`
    /// (a real first frame), which avoids a "connected but frozen" surface.
    enum Status: Equatable {
        case idle
        case loadingApps
        case browsing
        case launching(name: String)
        case streaming(target: StreamTarget, name: String)
        case failed(reason: String)
        case targetLost(reason: String)
    }

    /// The currently-streamed window's geometry (point size + Retina scale), used to map touch
    /// input into the window. Nil unless a window is streaming.
    struct StreamedWindow: Equatable {
        let windowID: String
        let pointWidth: Double
        let pointHeight: Double
        let scale: Double
    }

    @Published private(set) var applications: [RemoteApplication] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var streamedWindow: StreamedWindow?
    @Published private(set) var streamedApplication: RemoteApplication?

    private let environment: ClientAppEnvironment
    private var receiveTask: Task<Void, Never>?
    private var listRetryTask: Task<Void, Never>?
    private var launchTimeoutTask: Task<Void, Never>?
    private var pendingTargetName: String?
    private var clientViewportAspect: Double?
    private var lastRequestedViewportAspect: Double?
    private var viewportResizeTask: Task<Void, Never>?
    private var isViewportResizePending = false

    init(environment: ClientAppEnvironment) {
        self.environment = environment
    }

    /// True when the connected host negotiated App Streaming (macOS 14+ host).
    var isSupported: Bool {
        environment.sessionCoordinator.negotiatedCapabilities?.supportsAppStreaming ?? false
    }

    /// Begin consuming host messages. Safe to call repeatedly.
    ///
    /// The stream is created (which registers our broadcast continuation) *synchronously* here,
    /// before `requestApplicationList()` runs — otherwise the request could be sent before the
    /// receive loop is registered and the host's snapshot would be missed (the "stuck on
    /// Loading applications" race).
    func start() {
        guard receiveTask == nil else { return }
        let stream = environment.webRTCSessionManager.receiveDataMessages()
        receiveTask = Task { [weak self] in
            for await envelope in stream {
                if Task.isCancelled { break }
                self?.handle(envelope)
            }
            if let self, !Task.isCancelled {
                self.receiveTask = nil
            }
        }
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        listRetryTask?.cancel()
        listRetryTask = nil
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        applications = []
        streamedWindow = nil
        streamedApplication = nil
        pendingTargetName = nil
        lastRequestedViewportAspect = nil
        viewportResizeTask?.cancel()
        viewportResizeTask = nil
        isViewportResizePending = false
        status = .idle
    }

    // MARK: - Intents

    func updateClientViewport(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = Double(size.width / size.height)
        guard aspect.isFinite, (0.25...4).contains(aspect) else { return }
        clientViewportAspect = aspect
        guard streamedApplication != nil,
              case .streaming = status,
              abs(aspect - (lastRequestedViewportAspect ?? aspect)) > 0.025 else { return }
        viewportResizeTask?.cancel()
        viewportResizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard let self, !Task.isCancelled, let application = self.streamedApplication else { return }
            self.sendTargetRequest(application, showsLaunchingState: false)
        }
    }

    func requestApplicationList() {
        guard environment.sessionCoordinator.hostLockState == .unlockedActiveSession else {
            listRetryTask?.cancel()
            listRetryTask = nil
            status = .browsing
            return
        }
        guard environment.sessionCoordinator.activeSessionID != nil else {
            status = .failed(reason: "Not connected to a Mac.")
            return
        }
        status = .loadingApps
        sendListRequest(attempt: 1)
    }

    /// The control-channel auth handshake can lag the session becoming "ready", so the very first
    /// request may be dropped as unauthenticated. Retry a few times until the snapshot arrives.
    private func sendListRequest(attempt: Int) {
        guard let sessionID = environment.sessionCoordinator.activeSessionID else {
            status = .failed(reason: "Not connected to a Mac.")
            return
        }
        let request = ApplicationListRequestMessage(
            sessionID: sessionID,
            senderDeviceID: environment.clientIdentity.id
        )
        do {
            try environment.webRTCSessionManager.sendDataMessage(
                try DataChannelEnvelope.applicationListRequest(request))
            appStreamLog.info("requestApplicationList sent attempt=\(attempt, privacy: .public) session=\(sessionID.uuidString, privacy: .public)")
        } catch {
            appStreamLog.error("requestApplicationList send failed: \(String(describing: error), privacy: .public)")
        }

        listRetryTask?.cancel()
        listRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            // Still waiting? Retry (up to a bound) or surface a failure.
            guard self.applications.isEmpty, case .loadingApps = self.status else { return }
            if attempt < 6 {
                self.sendListRequest(attempt: attempt + 1)
            } else {
                self.status = .failed(reason: "The Mac didn't send its apps. Tap Retry.")
            }
        }
    }

    func select(_ application: RemoteApplication) {
        guard environment.sessionCoordinator.hostLockState == .unlockedActiveSession else {
            status = .failed(reason: "Unlock the Mac to open applications.")
            return
        }
        guard environment.sessionCoordinator.activeSessionID != nil else {
            status = .failed(reason: "Not connected to a Mac.")
            return
        }
        streamedApplication = application
        sendTargetRequest(application, showsLaunchingState: true)
    }

    private func sendTargetRequest(
        _ application: RemoteApplication,
        showsLaunchingState: Bool
    ) {
        guard let sessionID = environment.sessionCoordinator.activeSessionID else {
            status = .failed(reason: "Not connected to a Mac.")
            return
        }
        pendingTargetName = application.name
        isViewportResizePending = !showsLaunchingState
        if showsLaunchingState { status = .launching(name: application.name) }
        launchTimeoutTask?.cancel()
        launchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard showsLaunchingState, case .launching = self.status else { return }
            self.pendingTargetName = nil
            self.status = .failed(reason: "The Mac did not open \(application.name) in time. Tap Retry.")
        }
        let request = StreamTargetSwitchRequestMessage(
            sessionID: sessionID,
            target: .application(application.bundleIdentifier),
            senderDeviceID: environment.clientIdentity.id,
            clientViewportAspect: clientViewportAspect
        )
        lastRequestedViewportAspect = clientViewportAspect
        do {
            try environment.webRTCSessionManager.sendDataMessage(
                try DataChannelEnvelope.streamTargetSwitch(request))
        } catch {
            isViewportResizePending = false
            if showsLaunchingState {
                status = .failed(reason: "Could not start \(application.name).")
            } else {
                appStreamLog.error("viewport resize send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func backToApps() {
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        pendingTargetName = nil
        streamedWindow = nil
        streamedApplication = nil
        viewportResizeTask?.cancel()
        viewportResizeTask = nil
        isViewportResizePending = false
        status = .browsing
        requestApplicationList()
    }

    /// A locked Mac intentionally rejects app inventory and launch commands. Pause bounded
    /// retries while locked, then let the view resume them immediately after the host reports
    /// an unlocked session. An already-running stream keeps its target state for fast recovery.
    func pauseForHostLock() {
        listRetryTask?.cancel()
        listRetryTask = nil
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        if case .streaming = status { return }
        pendingTargetName = nil
        status = .browsing
    }

    func resumeAfterHostUnlock() {
        if case .streaming = status { return }
        requestApplicationList()
    }

    // MARK: - Inbound

    func handle(_ envelope: DataChannelEnvelope) {
        appStreamLog.info("rx kind=\(envelope.kind.rawValue, privacy: .public) payload=\(envelope.payload.count, privacy: .public)B")
        switch envelope.kind {
        case .applicationList:
            guard let snapshot = try? envelope.decodeApplicationListSnapshot() else {
                appStreamLog.error("applicationList decode FAILED payload=\(envelope.payload.count, privacy: .public)B")
                return
            }
            guard snapshot.sessionID == environment.sessionCoordinator.activeSessionID,
                  snapshot.senderDeviceID == environment.clientIdentity.id else { return }
            appStreamLog.info("applicationList snapshot apps=\(snapshot.applications.count, privacy: .public)")
            listRetryTask?.cancel()
            applications = snapshot.applications
            if case .loadingApps = status { status = .browsing }
        case .streamTargetSwitch:
            guard let result = try? envelope.decodeStreamTargetSwitchResult() else { return }
            guard result.sessionID == environment.sessionCoordinator.activeSessionID,
                  result.senderDeviceID == environment.clientIdentity.id else { return }
            apply(result)
        default:
            break
        }
    }

    func apply(_ result: StreamTargetSwitchResultMessage) {
        launchTimeoutTask?.cancel()
        launchTimeoutTask = nil
        let wasViewportResize = isViewportResizePending
        if isViewportResizePending {
            switch result.status {
            case .accepted:
                return
            case .rejected, .failed:
                isViewportResizePending = false
                pendingTargetName = nil
                appStreamLog.error("viewport resize refused: \(result.reason ?? "unknown", privacy: .public)")
                return
            case .completed:
                isViewportResizePending = false
            }
        }
        if result.status == .completed, let width = result.width, let height = result.height {
            guard width > 0, height > 0,
                  let scale = result.scaleFactor,
                  scale.isFinite, scale > 0 else {
                if !wasViewportResize {
                    streamedWindow = nil
                    status = .failed(reason: "The Mac returned an invalid window size.")
                }
                return
            }
            streamedWindow = StreamedWindow(
                windowID: result.resolvedTarget.identifier,
                pointWidth: Double(width),
                pointHeight: Double(height),
                scale: scale
            )
        } else if result.status == .failed || result.status == .rejected {
            streamedWindow = nil
        }
        status = Self.reduce(status: status, result: result, pendingName: pendingTargetName ?? "Application")
    }

    /// Pure state transition (no environment) — unit-tested.
    static func reduce(status: Status, result: StreamTargetSwitchResultMessage, pendingName: String) -> Status {
        switch result.status {
        case .accepted:
            return .launching(name: pendingName)
        case .completed:
            return .streaming(target: result.resolvedTarget, name: pendingName)
        case .rejected, .failed:
            let reason = result.reason ?? "The application is unavailable."
            // A failure arriving while we are already streaming is the host's unsolicited
            // target-lost signal (window closed / app quit) — distinguish it from a launch failure.
            if case .streaming = status {
                return .targetLost(reason: reason)
            }
            return .failed(reason: reason)
        }
    }
}
