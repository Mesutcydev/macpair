import SwiftUI
import SharedUI

/// Vamp Stream — a standalone iPhone client that does ONE thing: stream an individual Mac
/// application to your iPhone. It is NOT Vamp Control: no desktop mirror, no tabs, no terminal.
/// It reuses the shared Vamp client stack (pairing, discovery, WebRTC, decoder, input) but its own
/// flow is focused: connect to a Mac → browse the Mac's apps → stream one app's window.
@main
struct VampStreamApp: App {
    @UIApplicationDelegateAdaptor(VampStreamAppDelegate.self) private var appDelegate
    @StateObject private var environment: ClientAppEnvironment
    @StateObject private var appStream: AppStreamViewModel
    @StateObject private var vampAssistant: BeetCodeRemoteSessionViewModel

    init() {
        let env = ClientAppEnvironment.makeDefault(clientName: "Vamp Stream")
        _environment = StateObject(wrappedValue: env)
        _appStream = StateObject(wrappedValue: AppStreamViewModel(environment: env))
        _vampAssistant = StateObject(wrappedValue: BeetCodeRemoteSessionViewModel())
    }

    var body: some Scene {
        WindowGroup {
            VampStreamRootView(environment: environment, appStream: appStream, vampAssistant: vampAssistant)
                .vampSplash(.vampStream(), minimumDuration: 1.7)
        }
    }
}

/// Focused root state machine. There is no tab bar and no desktop mirror — the app is either
/// picking a Mac, connecting, or showing that Mac's applications.
struct VampStreamRootView: View {
    let environment: ClientAppEnvironment
    @ObservedObject var appStream: AppStreamViewModel
    @ObservedObject var vampAssistant: BeetCodeRemoteSessionViewModel
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    @State private var connectingName: String?
    @State private var showVampAssistantPairing = false

    init(
        environment: ClientAppEnvironment,
        appStream: AppStreamViewModel,
        vampAssistant: BeetCodeRemoteSessionViewModel
    ) {
        self.environment = environment
        self.appStream = appStream
        self.vampAssistant = vampAssistant
        self.sessionCoordinator = environment.sessionCoordinator
    }

    private var isConnected: Bool { sessionCoordinator.activeSessionID != nil }
    private var isConnecting: Bool {
        connectingName != nil && !isConnected && sessionCoordinator.phase != .error
    }
    private var isStreamingApp: Bool {
        if case .streaming = appStream.status { return true }
        return false
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PRAppBackground().ignoresSafeArea())
        .onChangeCompat(of: isConnected) { connected in
            if connected { connectingName = nil }
        }
        .onChangeCompat(of: sessionCoordinator.phase) { phase in
            if phase == .error { connectingName = nil }
        }
        // Match the phone orientation to the resolved Mac window instead of assuming every app
        // is landscape. The renderer and input mapper both preserve that same aspect ratio.
        .onChangeCompat(of: isStreamingApp) { streaming in
            let aspect = streaming
                ? appStream.streamedWindow.map { $0.pointWidth / max($0.pointHeight, 1) }
                : nil
            StreamOrientation.set(aspect: aspect)
        }
        .onChangeCompat(of: appStream.streamedWindow) { window in
            guard isStreamingApp else { return }
            StreamOrientation.set(
                aspect: window.map { $0.pointWidth / max($0.pointHeight, 1) }
            )
        }
        .sheet(isPresented: $showVampAssistantPairing) {
            BeetCodePairingView(model: vampAssistant)
                .presentationDetents([.large])
        }
    }

    @ViewBuilder private var content: some View {
        if let session = vampAssistant.session {
            BeetCodeRemoteView(
                session: session,
                onClose: { vampAssistant.disconnect() },
                onRefresh: { await vampAssistant.refreshStatus() }
            )
        } else if isConnected {
            if let caps = sessionCoordinator.negotiatedCapabilities {
                if caps.supportsAppStreaming {
                    AppStreamBrowserView(environment: environment, vm: appStream) {
                        Task { await sessionCoordinator.disconnect() }
                    }
                } else {
                    VampStreamMessageView(
                        icon: "macwindow.badge.plus",
                        title: "App Streaming Unavailable",
                        message: "This Mac's Vamp Host doesn't support App Streaming yet. It needs to be updated (macOS 14 or newer).",
                        actionTitle: "Disconnect"
                    ) { Task { await sessionCoordinator.disconnect() } }
                }
            } else {
                // Connected, but capabilities aren't negotiated yet — keep waiting, don't
                // misreport as unsupported.
                VampStreamConnectingView(name: sessionCoordinator.connectedHostName ?? connectingName ?? "Mac") {
                    Task { await sessionCoordinator.disconnect() }
                }
            }
        } else if isConnecting {
            VampStreamConnectingView(name: connectingName ?? "Mac") {
                connectingName = nil
                Task { await sessionCoordinator.disconnect() }
            }
        } else {
            VampStreamConnectView(
                environment: environment,
                onConnect: { host in
                    connectingName = host.title
                    environment.sharedHostsViewModel.connect(to: host)
                    Task {
                        if sessionCoordinator.activeSessionID != nil { await sessionCoordinator.disconnect() }
                        await sessionCoordinator.connect(
                            to: host.endpoint,
                            qualityPreset: environment.effectivePreferredQualityPreset
                        )
                    }
                },
                onPairVampAssistant: { showVampAssistantPairing = true },
                savedVampAssistantAddress: vampAssistant.savedAddress,
                vampAssistantError: vampAssistant.lastError,
                onReconnectVampAssistant: {
                    Task { await vampAssistant.reconnectSaved() }
                }
            )
        }
    }
}
