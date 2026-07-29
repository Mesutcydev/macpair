import SwiftUI
import AppKit
import Discovery
import SharedModels

/// Discovers hosts on the local network and starts sessions.
struct MacHostsScreen: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var hostsVM: HostsListViewModel
    @ObservedObject private var coordinator: ClientSessionCoordinator

    @State private var manualAddress: String = ""
    @State private var manualAddError: String?
    /// True once the first scan has produced a result, so repeated background
    /// re-scans (which momentarily reset the shared state to `.loading`) don't
    /// blow the content away and cause flicker.
    @State private var hasCompletedFirstScan = false

    /// The host currently being woken (drives its button spinner), plus a
    /// transient toast describing what the wake attempt actually dispatched.
    @State private var wakingHostID: DiscoveredHostRow.ID?
    @State private var wakeFeedback: String?
    @State private var wakeFeedbackIsError = false

    /// Set when the user taps Connect on a Tailscale/relay host while the VPN is
    /// off; drives a warning alert so we don't fire a doomed long-timeout connect
    /// to an address that can't resolve without Tailscale up.
    @State private var pendingTailscaleHost: DiscoveredHostRow?

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.hostsVM = environment.sharedHostsViewModel
        self.coordinator = environment.sessionCoordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            manualEntryBar
        }
        .background(MacBrand.pageBackdrop)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").foregroundStyle(.secondary)
                    }
                    .help("Searching the local network…")
                } else {
                    Button {
                        Task { await hostsVM.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Search the local network again")
                }
            }
        }
        .task { await hostsVM.start() }
        .onChange(of: hostsVM.state) { state in
            if state != .loading { hasCompletedFirstScan = true }
        }
        .overlay {
            if isConnecting {
                connectingOverlay
            }
        }
        .overlay(alignment: .bottom) {
            if let wakeFeedback {
                wakeToast(wakeFeedback, isError: wakeFeedbackIsError)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Warn before connecting to a Tailscale/relay host with the VPN off —
        // otherwise the connect attempt just hangs until a long timeout because
        // the ts.net / 100.x address can't resolve without Tailscale running.
        .alert("Turn on Tailscale", isPresented: Binding(
            get: { pendingTailscaleHost != nil },
            set: { if !$0 { pendingTailscaleHost = nil } }
        )) {
            Button("Open Tailscale") {
                openTailscaleApp()
                pendingTailscaleHost = nil
            }
            Button("Connect anyway") {
                let host = pendingTailscaleHost
                pendingTailscaleHost = nil
                if let host { startConnect(to: host) }
            }
            Button("Cancel", role: .cancel) { pendingTailscaleHost = nil }
        } message: {
            Text("This looks like a Tailscale address. Make sure the Tailscale VPN is connected on this Mac, then try again — otherwise the host can’t be reached.")
        }
    }

    private var isConnecting: Bool {
        switch coordinator.phase {
        case .connecting, .signalingConnected, .negotiating:
            return true
        default:
            return false
        }
    }

    private var isScanning: Bool { hostsVM.state == .loading }

    /// Only show the full-screen spinner before the very first scan completes.
    /// After that we keep stable content and surface re-scans via the toolbar.
    private var isInitialScan: Bool { isScanning && !hasCompletedFirstScan }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if case .localNetworkIssue(let message) = hostsVM.state {
            centeredState {
                statusGraphic("wifi.exclamationmark", tint: .orange)
                Text("Local Network Unavailable").font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        } else if !hostsVM.displayHosts.isEmpty {
            hostsList
        } else if isInitialScan {
            centeredState {
                DiscoveryHero(isScanning: true)
                Text("Searching for Macs running ScreenHarbor Host…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        } else {
            emptyState
        }
    }

    /// Shared centered layout for the non-list states.
    private func centeredState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
    }

    private func statusGraphic(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 72, height: 72)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyState: some View {
        centeredState {
            DiscoveryHero(isScanning: isScanning)
                .padding(.bottom, 4)
            Text("No Macs found yet")
                .font(.title2.weight(.semibold))
            Text("Open the ScreenHarbor Host app on the Mac you want to control, and make sure both Macs are on the same network — or reachable over Tailscale.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            screenHarborHostBox
                .padding(.top, 10)
            if isScanning {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Scanning your network…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            Text("…or add one by IP address below.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    // MARK: - Get ScreenHarbor Host

    /// Canonical direct-download page for the host companion.
    private static let hostWebsiteURL = URL(string: "https://mesut.uk/apps/screenharbor-host")!

    /// Small directional card pointing users to install the free ScreenHarbor Host on the Mac they
    /// want to control.
    private var screenHarborHostBox: some View {
        HStack(alignment: .top, spacing: 14) {
            Image("ScreenHarborHostIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 5) {
                Text("Don’t have ScreenHarbor Host yet?")
                    .font(.headline)
                Text("Install the free ScreenHarbor Host app on the Mac you want to control.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: Self.hostWebsiteURL) {
                    Label("Download from project website", systemImage: "arrow.down.circle")
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.bordered)
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .macGlassSurface(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            isInteractive: true
        )
    }

    // MARK: - Hosts list

    private var hostsList: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if let message = errorBannerMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    LazyVStack(spacing: 10) {
                        ForEach(hostsVM.displayHosts) { row in
                            HostCardView(
                                row: row,
                                isBusy: isConnecting,
                                canWake: canWake(row),
                                isWaking: wakingHostID == row.id,
                                onConnect: { connect(to: row) },
                                onWake: { sendWake(row) },
                                onToggleSave: {
                                    if row.isSaved { hostsVM.removeSavedHost(row.id) }
                                    else { hostsVM.saveHost(row.id) }
                                }
                            )
                        }
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                // Top-align the list: a few hosts centered in a tall window
                // floats in a void. Pinning to the top reads as intentional —
                // the native macOS list idiom (System Settings, Mail, Finder).
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Macs")
                    .font(.title.weight(.semibold))
                Text(hostSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private var hostSubtitle: String {
        let count = hostsVM.displayHosts.count
        let online = hostsVM.displayHosts.filter(\.isAvailable).count
        if count == 0 { return "Searching your network…" }
        let noun = count == 1 ? "Mac" : "Macs"
        return "\(count) \(noun) found · \(online) online"
    }

    private var errorBannerMessage: String? {
        if let message = coordinator.errorMessage, coordinator.phase == .error || coordinator.phase == .idle {
            return message
        }
        // A permission-blocked host sets `phase == .error` and `blockedState`
        // but leaves `errorMessage` nil, so without this fallback the banner
        // would be empty and the user would get no guidance about granting
        // Screen Recording / Accessibility on the host.
        if coordinator.phase == .error, let blocked = coordinator.blockedState {
            return blocked.message
        }
        return hostsVM.connectionMessage
    }

    // MARK: - Manual entry

    private var manualEntryBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("Add a Mac by IP or hostname  (e.g. 192.168.1.20:9471)", text: $manualAddress)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addManualHost)
                // A stale "Invalid address" shouldn't linger while the user is
                // already fixing the input.
                .onChange(of: manualAddress) { _ in manualAddError = nil }

            if let manualAddError {
                Text(manualAddError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Button("Add", action: addManualHost)
                .keyboardShortcut(.defaultAction)
                .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        // Match the 720pt card column so the footer aligns with the list above
        // instead of spanning the whole window edge-to-edge.
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    // MARK: - Connecting overlay

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(connectingStatusText)
                    .font(.title3.weight(.semibold))
                Text("If this is the first connection, approve this Mac in the ScreenHarbor Host window on the other computer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Cancel") {
                    Task { await coordinator.disconnect() }
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 2)
            }
            .padding(32)
            .macGlassSurface(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                isInteractive: true
            )
        }
    }

    private var connectingStatusText: String {
        switch coordinator.phase {
        case .connecting: return "Connecting…"
        case .signalingConnected: return "Contacting host…"
        case .negotiating: return "Waiting for host approval…"
        default: return "Connecting…"
        }
    }

    // MARK: - Actions

    private func addManualHost() {
        let address = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        if let row = hostsVM.addManualHost(address: address) {
            manualAddError = nil
            manualAddress = ""
            connect(to: row)
        } else {
            manualAddError = "Invalid address"
        }
    }

    private func connect(to row: DiscoveredHostRow) {
        // Remind to enable the VPN before attempting a Tailscale/relay address —
        // a ts.net / 100.x host won't resolve without Tailscale connected, so we
        // route through a warning alert instead of a doomed long-timeout connect.
        if isRelay(row) && coordinator.tailscaleVPNStatus == .inactive {
            pendingTailscaleHost = row
            return
        }
        startConnect(to: row)
    }

    /// Starts the session for `row`, after any pre-connect guards have passed.
    private func startConnect(to row: DiscoveredHostRow) {
        hostsVM.connect(to: row)
        let preset = environment.effectivePreferredQualityPreset
        Task {
            await coordinator.connect(to: row.endpoint, qualityPreset: preset)
            if coordinator.phase == .receiving || coordinator.phase == .waitingForMedia {
                hostsVM.markHostConnected(row.id)
            }
        }
    }

    /// A relay host is reachable only over Tailscale (a ts.net name or 100.x CGNAT
    /// address), so connecting to one needs the VPN up first.
    private func isRelay(_ row: DiscoveredHostRow) -> Bool {
        row.endpoint.hostname.contains("ts.net") || row.endpoint.hostname.hasPrefix("100.")
    }

    /// Opens the Tailscale app via its URL scheme (macOS uses NSWorkspace, not UIApplication).
    private func openTailscaleApp() {
        if let url = URL(string: "tailscale://") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Wake on LAN

    /// A host can be woken when it's offline but we still know how to reach it —
    /// a saved MAC (magic packet) or a Bonjour name (Sleep Proxy / Wake-on-Demand).
    private func canWake(_ row: DiscoveredHostRow) -> Bool {
        !row.isAvailable
            && (row.endpoint.metadata.macAddress != nil || row.endpoint.bonjourServiceName != nil)
    }

    private func sendWake(_ row: DiscoveredHostRow) {
        let mac = row.endpoint.metadata.macAddress
        let bonjourName = row.endpoint.bonjourServiceName
        guard mac != nil || bonjourName != nil else { return }
        wakingHostID = row.id
        let targetHost = row.endpoint.hostname
        Task {
            // WakeCoordinator fires both paths in parallel — magic packet (Ethernet / Intel)
            // and the Bonjour resolve that triggers the LAN Sleep Proxy (the only path that
            // wakes Apple-Silicon Macs on Wi-Fi) — and reports what was actually dispatched.
            let outcome = await WakeCoordinator().wake(
                macAddress: mac,
                bonjourServiceName: bonjourName,
                targetHost: targetHost,
                wakeSupported: row.endpoint.metadata.wakeSupported
            )
            if wakingHostID == row.id { wakingHostID = nil }
            showWakeFeedback(outcome)
        }
    }

    private func showWakeFeedback(_ outcome: WakeCoordinator.Outcome) {
        let message = outcome.userMessage
        withAnimation(.easeOut(duration: 0.2)) {
            wakeFeedback = message
            wakeFeedbackIsError = outcome.isError
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if wakeFeedback == message {
                withAnimation(.easeOut(duration: 0.25)) { wakeFeedback = nil }
            }
        }
    }

    private func wakeToast(_ message: String, isError: Bool) -> some View {
        let tint = isError ? Color.orange : Color.secondary
        return HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "bolt.horizontal.fill")
                .font(.callout.weight(.semibold))
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isError ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 460)
        .macGlassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 24)
    }
}

// MARK: - Discovery hero

/// First-run / empty-list illustration: a Mac framed by concentric "signal"
/// rings, used both while scanning and when no hosts are found. The rings
/// breathe while a scan is in flight, so the first thing a new user sees reads
/// as "looking for Macs on your network" rather than a bare spinner or a
/// stamped app icon.
private struct DiscoveryHero: View {
    var isScanning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(Color.accentColor.opacity(0.16 - Double(i) * 0.04), lineWidth: 1.5)
                    .frame(width: 100 + CGFloat(i) * 42, height: 100 + CGFloat(i) * 42)
                    .scaleEffect(animating ? 1.06 : 0.97)
                    .opacity(animating ? 0.9 : 0.55)
                    .animation(
                        isScanning && !reduceMotion
                            ? .easeInOut(duration: 1.9).repeatForever(autoreverses: true).delay(Double(i) * 0.22)
                            : .easeOut(duration: 0.3),
                        value: animating
                    )
            }

            Image(systemName: "desktopcomputer")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 92, height: 92)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
                )
        }
        .frame(width: 210, height: 200)
        .onAppear { animating = isScanning && !reduceMotion }
        .onChange(of: isScanning) { animating = $0 && !reduceMotion }
    }
}

// MARK: - Host card

private struct HostCardView: View {
    let row: DiscoveredHostRow
    let isBusy: Bool
    let canWake: Bool
    let isWaking: Bool
    let onConnect: () -> Void
    let onWake: () -> Void
    let onToggleSave: () -> Void

    @State private var isHovering = false

    var body: some View {
        BrandCard(hovering: isHovering) {
            HStack(spacing: 14) {
                // Icon tile — neutral fill; accent only when reachable.
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(row.isAvailable ? Color.accentColor : Color.secondary)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(row.isAvailable
                                  ? Color.accentColor.opacity(0.12)
                                  : Color.secondary.opacity(0.12))
                    )

                // Name + address
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.title)
                            .font(.headline)
                            .lineLimit(1)
                        if row.isSaved {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .help("Saved host")
                        }
                    }
                    Text(row.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                statusPill
                trailingAction
            }
            .padding(14)
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        // Finder idiom: double-click an online host to connect.
        .onTapGesture(count: 2) {
            if row.isAvailable && !isBusy { onConnect() }
        }
        .contextMenu {
            Button(row.isSaved ? "Remove from Saved" : "Save Host", action: onToggleSave)
            if canWake {
                Button(isWaking ? "Waking…" : "Wake Host", action: onWake)
                    .disabled(isWaking)
            }
        }
    }

    /// Connect when the host is reachable; Wake when it's asleep but reachable
    /// by magic packet or Sleep Proxy; otherwise a disabled Connect.
    @ViewBuilder
    private var trailingAction: some View {
        if row.isAvailable {
            Button(action: onConnect) {
                Text("Connect").frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)
        } else if canWake {
            Button(action: onWake) {
                Label(isWaking ? "Waking…" : "Wake",
                      systemImage: isWaking ? "bolt.horizontal.fill" : "power")
                    .frame(minWidth: 56)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .controlSize(.large)
            .disabled(isWaking)
            .help("Send a wake signal to this sleeping Mac")
        } else {
            Button(action: onConnect) {
                Text("Connect").frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(row.isAvailable ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(row.isAvailable ? "Online" : "Offline")
                .font(.caption.weight(.medium))
                .foregroundStyle(row.isAvailable ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            (row.isAvailable ? Color.green : Color.secondary).opacity(0.12),
            in: Capsule()
        )
    }
}
