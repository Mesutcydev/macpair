import SwiftUI
import Discovery
import SharedModels

struct VampTerminalHomeView: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var hosts: HostsListViewModel
    @StateObject private var workspace: TerminalWorkspaceViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var manualAddress = ""
    @State private var showingManualAddress = false
    @State private var showingGuide = false
    @AppStorage("vampTerminal.hostPromo.dismissed") private var hostPromoDismissed = false

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        _hosts = ObservedObject(wrappedValue: environment.sharedHostsViewModel)
        _workspace = StateObject(
            wrappedValue: TerminalWorkspaceViewModel(coordinator: environment.sessionCoordinator)
        )
    }

    var body: some View {
        Group {
            if isWorkspaceVisible {
                VampTerminalWorkspaceView(
                    workspace: workspace,
                    coordinator: environment.sessionCoordinator
                )
            } else {
                homeContent
            }
        }
        .task {
            await hosts.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await hosts.handleSceneBecameActive() }
        }
    }

    private var isWorkspaceVisible: Bool {
        switch environment.sessionCoordinator.phase {
        case .waitingForMedia, .receiving:
            guard let capabilities = environment.sessionCoordinator.negotiatedCapabilities else {
                return false
            }
            return capabilities.supportsTerminal && capabilities.supportsMultipleTerminals
        case .idle, .connecting, .signalingConnected, .negotiating, .error:
            return false
        }
    }

    private var terminalUnavailableMessage: (title: String, message: String, icon: String)? {
        guard environment.sessionCoordinator.phase == .waitingForMedia
                || environment.sessionCoordinator.phase == .receiving else {
            return nil
        }
        guard let capabilities = environment.sessionCoordinator.negotiatedCapabilities else {
            return (
                "Terminal capability not reported",
                "This host did not report multi-terminal support. Update Vamp Host on the Mac before using Vamp Terminal.",
                "questionmark.circle"
            )
        }
        if !capabilities.supportsTerminal {
            return (
                "Terminal Mode is not supported",
                "This host can connect, but it does not provide an authenticated terminal channel. Update Vamp Host on the Mac.",
                "terminal"
            )
        }
        if !capabilities.supportsMultipleTerminals {
            return (
                "Multiple terminals are not supported",
                "This host supports only the older single-terminal flow. Update Vamp Host on the Mac to use terminal tabs.",
                "rectangle.split.2x1"
            )
        }
        return nil
    }

    private var homeContent: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        hero

                        guideEntry

                        if !hostPromoDismissed {
                            VampHostPromoCard {
                                hostPromoDismissed = true
                            }
                        }

                        if isConnecting {
                            connectionProgressCard
                        }

                        if let blocked = environment.sessionCoordinator.blockedState {
                            messageCard(
                                title: blocked.title,
                                message: blocked.message,
                                icon: "lock.shield",
                                tint: VampGlassPalette.warning
                            )
                        } else if let error = environment.sessionCoordinator.errorMessage,
                                  environment.sessionCoordinator.phase == .error {
                            messageCard(
                                title: "Connection needs attention",
                                message: error,
                                icon: "exclamationmark.triangle",
                                tint: VampGlassPalette.warning
                            )
                        } else if let unavailable = terminalUnavailableMessage {
                            terminalUnavailableCard(
                                title: unavailable.title,
                                message: unavailable.message,
                                icon: unavailable.icon
                            )
                        }

                        hostSection

                        pairingNote
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(VampTerminalBackdrop())
            .navigationTitle("Vamp Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await hosts.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isConnecting)
                    .accessibilityLabel("Refresh hosts")
                }
            }
            .sheet(isPresented: $showingGuide) {
                VampTerminalGuideView()
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            VampGlassIconTile(systemImage: "terminal.fill", size: 62)

            VStack(alignment: .leading, spacing: 5) {
                Text("Your Mac, in tabs.")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(VampGlassPalette.ink)
                Text("Secure terminal access from anywhere on your tailnet.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("REMOTE SHELL  ·  TAILSCALE READY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(VampGlassPalette.inkTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var guideEntry: some View {
        Button {
            showingGuide = true
        } label: {
            HStack(spacing: 12) {
                VampGlassIconTile(systemImage: "book.closed", size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("How to use Vamp Terminal")
                        .font(.headline)
                        .foregroundStyle(VampGlassPalette.ink)
                    Text("Pair once, switch tabs, resume tmux sessions, and use the mobile controls.")
                        .font(.footnote)
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
            }
            .padding(12)
            .vampGlassSurface(.card, cornerRadius: 16)
            .vampGlassOutline(cornerRadius: 16)
        }
        .buttonStyle(VampGlassPressStyle())
        .accessibilityLabel("How to use Vamp Terminal")
        .accessibilityHint("Opens the visual setup and terminal controls guide")
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            VampTerminalSectionLabel(
                title: "Hosts",
                detail: hosts.displayHosts.isEmpty ? nil : "\(hosts.displayHosts.count)"
            )

            if hosts.displayHosts.isEmpty {
                emptyHostsCard
            } else {
                VStack(spacing: 9) {
                    ForEach(hosts.displayHosts) { row in
                        hostRow(row)
                    }
                }
            }

            manualAddressEntry
        }
    }

    private func hostRow(_ row: DiscoveredHostRow) -> some View {
        let metadata = row.endpoint.metadata
        let isManual = metadata.appVersion == "unknown"
        let supportsMultipleTerminals = metadata.capabilities.contains(.supportsMultipleTerminals)
        let supportsTerminal = metadata.capabilities.contains(.supportsTerminal)
        let isSupported = supportsTerminal && supportsMultipleTerminals
        let isBusy = metadata.availability == .busy

        return ViewThatFits(in: .horizontal) {
            hostRowLayout(
                row: row,
                isManual: isManual,
                isSupported: isSupported,
                supportsTerminal: supportsTerminal,
                supportsMultipleTerminals: supportsMultipleTerminals,
                isBusy: isBusy,
                stacked: false
            )
            hostRowLayout(
                row: row,
                isManual: isManual,
                isSupported: isSupported,
                supportsTerminal: supportsTerminal,
                supportsMultipleTerminals: supportsMultipleTerminals,
                isBusy: isBusy,
                stacked: true
            )
        }
        .padding(14)
        .vampGlassSurface(.card, cornerRadius: 16)
        .vampGlassOutline(cornerRadius: 16)
    }

    @ViewBuilder
    private func hostRowLayout(
        row: DiscoveredHostRow,
        isManual: Bool,
        isSupported: Bool,
        supportsTerminal: Bool,
        supportsMultipleTerminals: Bool,
        isBusy: Bool,
        stacked: Bool
    ) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    hostStatusDot(row: row, isBusy: isBusy)
                    hostRowDetails(
                        row: row,
                        isManual: isManual,
                        isSupported: isSupported,
                        supportsTerminal: supportsTerminal,
                        supportsMultipleTerminals: supportsMultipleTerminals,
                        isBusy: isBusy
                    )
                }
                HStack {
                    Spacer(minLength: 0)
                    hostRowAction(row: row, isManual: isManual, isSupported: isSupported, isBusy: isBusy)
                }
            }
        } else {
            HStack(spacing: 12) {
                hostStatusDot(row: row, isBusy: isBusy)
                hostRowDetails(
                    row: row,
                    isManual: isManual,
                    isSupported: isSupported,
                    supportsTerminal: supportsTerminal,
                    supportsMultipleTerminals: supportsMultipleTerminals,
                    isBusy: isBusy
                )
                Spacer(minLength: 5)
                hostRowAction(row: row, isManual: isManual, isSupported: isSupported, isBusy: isBusy)
            }
        }
    }

    private func hostStatusDot(row: DiscoveredHostRow, isBusy: Bool) -> some View {
        Circle()
            .fill(row.isAvailable && !isBusy ? VampGlassPalette.good : VampGlassPalette.inkSubtle)
            .frame(width: 10, height: 10)
            .overlay {
                if row.isAvailable && !isBusy {
                    Circle().stroke(VampGlassPalette.good.opacity(0.24), lineWidth: 5)
                }
            }
            .accessibilityHidden(true)
    }

    private func hostRowDetails(
        row: DiscoveredHostRow,
        isManual: Bool,
        isSupported: Bool,
        supportsTerminal: Bool,
        supportsMultipleTerminals: Bool,
        isBusy: Bool
    ) -> some View {
        let metadata = row.endpoint.metadata
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(metadata.displayName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if row.isSaved {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                }
            }
            Text("\(row.endpoint.hostname):\(row.endpoint.port)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(VampGlassPalette.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            statusLine(
                row: row,
                isManual: isManual,
                isSupported: isSupported,
                supportsTerminal: supportsTerminal,
                supportsMultipleTerminals: supportsMultipleTerminals,
                isBusy: isBusy
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func hostRowAction(
        row: DiscoveredHostRow,
        isManual: Bool,
        isSupported: Bool,
        isBusy: Bool
    ) -> some View {
        let metadata = row.endpoint.metadata
        if row.isAvailable && (isSupported || isManual) && !isBusy {
            Button {
                connect(to: row)
            } label: {
                Label("Connect", systemImage: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.ink)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .vampGlassSurface(.button, cornerRadius: 11)
                    .vampGlassOutline(cornerRadius: 11, color: VampGlassPalette.ruleStrong)
            }
            .buttonStyle(VampGlassPressStyle())
            .accessibilityLabel("Connect to \(metadata.displayName)")
        } else if !row.isAvailable {
            VampGlassStatusPill(text: "Offline", color: VampGlassPalette.inkSecondary)
        } else if isBusy {
            VampGlassStatusPill(text: "Busy", color: VampGlassPalette.warning)
        } else {
            VampGlassStatusPill(text: "Unsupported", color: VampGlassPalette.warning)
        }
    }

    private func statusLine(
        row: DiscoveredHostRow,
        isManual: Bool,
        isSupported: Bool,
        supportsTerminal: Bool,
        supportsMultipleTerminals: Bool,
        isBusy: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: connectionIcon(for: row.endpoint))
                .font(.system(size: 10, weight: .semibold))
            Text(connectionLabel(for: row.endpoint))
            Text("·")
            if isManual {
                Text("Capabilities checked after pairing")
            } else if !supportsTerminal {
                Text("Terminal Mode unavailable")
            } else if !supportsMultipleTerminals {
                Text("Single terminal only")
            } else if isBusy {
                Text("Another client is connected")
            } else if row.isAvailable && isSupported {
                Text("8 tabs")
            } else {
                Text("Waiting for host")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(VampGlassPalette.inkTertiary)
        .lineLimit(1)
    }

    private var emptyHostsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(VampGlassPalette.inkSecondary)
            Text("Looking for Vamp Host")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(VampGlassPalette.ink)
            Text("Keep Vamp Host open on your Mac, or enter its Tailscale MagicDNS name below.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .vampGlassSurface(.card, cornerRadius: 16)
        .vampGlassOutline(cornerRadius: 16)
    }

    private var manualAddressEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showingManualAddress.toggle()
            } label: {
                Label("Connect with Tailscale address", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.ink)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(VampGlassPressStyle())

            if showingManualAddress {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        addressField
                        addAddressButton
                    }

                    VStack(spacing: 8) {
                        addressField
                        addAddressButton
                            .frame(maxWidth: .infinity)
                    }
                }
                Text("Vamp Terminal uses the Vamp Host pairing protocol on port 9471. Tailscale must be active on both devices.")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 3)
    }

    private var addressField: some View {
        TextField("mac.tailnet.ts.net or 100.x.y.z", text: $manualAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(VampGlassPalette.ink)
            .padding(.horizontal, 11)
            .frame(minHeight: 44)
            .vampGlassSurface(.field, cornerRadius: 11)
            .vampGlassOutline(cornerRadius: 11)
            .submitLabel(.go)
            .onSubmit {
                addManualHost()
            }
    }

    private var addAddressButton: some View {
        Button {
            addManualHost()
        } label: {
            Text("Add")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(VampGlassPalette.ink)
                .padding(.horizontal, 13)
                .frame(minHeight: 44)
                .vampGlassSurface(.button, cornerRadius: 11)
                .vampGlassOutline(cornerRadius: 11, color: VampGlassPalette.ruleStrong)
        }
        .buttonStyle(VampGlassPressStyle())
        .disabled(manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var pairingNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(VampGlassPalette.good)
            Text("Connections stay on your LAN or Tailscale. On first use, approve the pairing request in Vamp Host; the signed host identity is then remembered on this device.")
                .font(.footnote)
                .foregroundStyle(VampGlassPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .vampGlassSurface(.card, cornerRadius: 14)
        .vampGlassOutline(cornerRadius: 14, color: VampGlassPalette.good.opacity(0.28))
    }

    private var connectionProgressCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(VampGlassPalette.ink)
            VStack(alignment: .leading, spacing: 3) {
                Text(connectionPhaseTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                Text("Waiting for the signed WebRTC session to become ready…")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await environment.sessionCoordinator.endSession() }
            } label: {
                Text("Cancel")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.ink)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .vampGlassSurface(.button, cornerRadius: 10)
                    .vampGlassOutline(cornerRadius: 10)
            }
            .buttonStyle(VampGlassPressStyle())
        }
        .padding(14)
        .vampGlassSurface(.card, cornerRadius: 16)
        .vampGlassOutline(cornerRadius: 16, color: VampGlassPalette.ruleStrong)
    }

    private func messageCard(title: String, message: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(VampGlassPalette.ink)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(VampGlassPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .vampGlassSurface(.card, cornerRadius: 16)
        .vampGlassOutline(cornerRadius: 16, color: tint.opacity(0.30))
    }

    private func terminalUnavailableCard(title: String, message: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon)
                    .foregroundStyle(VampGlassPalette.warning)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(VampGlassPalette.ink)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(VampGlassPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await environment.sessionCoordinator.endSession() }
            } label: {
                Text("Disconnect")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VampGlassPalette.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .vampGlassSurface(.button, cornerRadius: 10)
                    .vampGlassOutline(cornerRadius: 10, color: VampGlassPalette.ruleStrong)
            }
            .buttonStyle(VampGlassPressStyle())
        }
        .padding(14)
        .vampGlassSurface(.card, cornerRadius: 16)
        .vampGlassOutline(cornerRadius: 16, color: VampGlassPalette.warning.opacity(0.30))
    }

    private var isConnecting: Bool {
        switch environment.sessionCoordinator.phase {
        case .connecting, .signalingConnected, .negotiating:
            return true
        case .idle, .waitingForMedia, .receiving, .error:
            return false
        }
    }

    private var connectionPhaseTitle: String {
        switch environment.sessionCoordinator.phase {
        case .connecting: return "Connecting to Mac"
        case .signalingConnected: return "Pairing with Mac"
        case .negotiating: return "Opening secure channel"
        default: return "Connecting"
        }
    }

    private func connect(to row: DiscoveredHostRow) {
        hosts.connect(to: row)
        Task {
            await environment.sessionCoordinator.connect(
                to: row.endpoint,
                qualityPreset: .performance
            )
            if environment.sessionCoordinator.phase != .error {
                hosts.markHostConnected(row.id)
            }
        }
    }

    private func addManualHost() {
        guard let row = hosts.addManualHost(address: manualAddress) else { return }
        manualAddress = ""
        showingManualAddress = false
        connect(to: row)
    }

    private func connectionIcon(for endpoint: ResolvedHostEndpoint) -> String {
        let hostname = endpoint.hostname.lowercased()
        if hostname.contains("ts.net") || hostname.hasPrefix("100.") {
            return "shield.lefthalf.filled"
        }
        return "wifi"
    }

    private func connectionLabel(for endpoint: ResolvedHostEndpoint) -> String {
        let hostname = endpoint.hostname.lowercased()
        if hostname.contains("ts.net") || hostname.hasPrefix("100.") {
            return "Tailscale"
        }
        return "LAN"
    }
}
