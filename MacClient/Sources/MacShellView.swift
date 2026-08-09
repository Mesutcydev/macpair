import SwiftUI
import SharedModels

/// Root view of the Mac client window. Shows the hosts list while idle and
/// swaps to the streaming session view once a connection is underway.
///
/// The `ClientReconnectCoordinator` is owned here (not in the session view) so
/// it survives a transient `.error` phase: the session view stays mounted for
/// the whole reconnect window, and only unmounts once the session is genuinely
/// over (`.idle`). Otherwise unmounting the session view on `.error` would tear
/// down the very coordinator responsible for recovering the connection.
struct MacShellView: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var coordinator: ClientSessionCoordinator
    @StateObject private var reconnectCoordinator: ClientReconnectCoordinator

    /// Latches once a session reaches `.receiving`, so a subsequent transient
    /// `.error`/`.connecting`/`.negotiating` keeps showing the session view
    /// (with the reconnect overlay) instead of flickering back to the hosts list.
    /// Cleared when the session ends (`.idle`).
    @State private var hasStreamedThisSession = false

    @AppStorage("client.onboarding.completed") private var onboardingCompleted = false
    @State private var showOnboarding = false

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.coordinator = environment.sessionCoordinator
        _reconnectCoordinator = StateObject(wrappedValue: ClientReconnectCoordinator(
            webRTCSessionManager: environment.webRTCSessionManager,
            signalingService: environment.signalingService,
            displayLayoutViewModel: environment.displayLayoutViewModel
        ))
    }

    /// Whether to show the live session view rather than the hosts list.
    private var showsSession: Bool {
        switch coordinator.phase {
        case .receiving, .waitingForMedia:
            return true
        case .connecting, .signalingConnected, .negotiating, .error:
            // Mid-reconnect after a session that already streamed: stay put.
            return hasStreamedThisSession
        case .idle:
            // Reconnect rebuilds the transport by calling disconnect(), which
            // briefly publishes `.idle`. Keep this view mounted so its reconnect
            // observers and callbacks survive that implementation detail.
            return hasStreamedThisSession && reconnectIsActive
        }
    }

    private var reconnectIsActive: Bool {
        reconnectCoordinator.isReconnecting || coordinator.isReconnectInProgress
    }

    var body: some View {
        Group {
            if showsSession {
                MacRemoteSessionView(
                    environment: environment,
                    reconnectCoordinator: reconnectCoordinator
                )
            } else {
                MacHostsScreen(environment: environment)
            }
        }
        .tint(MacBrand.accent)
        .navigationTitle(windowTitle)
        .onChange(of: coordinator.phase) { phase in
            switch phase {
            case .receiving:
                hasStreamedThisSession = true
            case .idle:
                if !reconnectIsActive {
                    hasStreamedThisSession = false
                }
            default:
                break
            }
        }
        .onChange(of: reconnectCoordinator.isReconnecting) { isReconnecting in
            if !isReconnecting,
               !coordinator.isReconnectInProgress,
               coordinator.phase == .idle {
                hasStreamedThisSession = false
            }
        }
        .onChange(of: coordinator.isReconnectInProgress) { isReconnecting in
            if !isReconnecting,
               !reconnectCoordinator.isReconnecting,
               coordinator.phase == .idle || coordinator.phase == .error {
                hasStreamedThisSession = false
            }
        }
        .sheet(isPresented: $showOnboarding) {
            MacOnboardingView {
                onboardingCompleted = true
                showOnboarding = false
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            if !onboardingCompleted { showOnboarding = true }
        }
    }

    private var windowTitle: String {
        switch coordinator.phase {
        case .receiving:
            if let name = coordinator.connectedHostName {
                return "\(name) — Vamp Remote"
            }
            return "Vamp Remote"
        case .connecting, .signalingConnected, .negotiating, .waitingForMedia:
            return "Connecting… — Vamp Remote"
        case .idle, .error:
            return "Vamp Remote"
        }
    }
}
