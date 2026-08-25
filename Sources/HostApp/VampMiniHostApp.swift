#if VAMP_MINI_HOST && os(macOS)
import AppKit
import Combine
import Darwin
import SwiftUI
import SharedModels
import SharedUtilities
import Permissions

/// Storage used by the standalone Vamp Mini Host product.
///
/// The mini host deliberately does not share the full host's identity or peer
/// list. Installing it should create a separate trust boundary, even though
/// both products use the same signed signaling and authenticated transport.
private enum VampMiniHostStorage {
    static let identityTag = "com.mesutcy.remotedesktop.minhost.p256"

    static var trustedPeerDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("RemoteDesktopTool", isDirectory: true)
            .appendingPathComponent("Vamp Mini Host", isDirectory: true)
    }
}

@main
struct VampMiniHostApp: App {
    private static let environment = HostAppEnvironment.placeholder(
        mode: .mini,
        identityTag: VampMiniHostStorage.identityTag,
        trustedPeerDirectory: VampMiniHostStorage.trustedPeerDirectory
    )

    @NSApplicationDelegateAdaptor(VampMiniHostAppDelegate.self) private var appDelegate

    init() {
        _ = Self.environment
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class VampMiniHostAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var environment: HostAppEnvironment?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var phaseObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startRuntimeWhenReady(attempt: 0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            await HostAppEnvironment.shared?.stopRuntime()
        }
    }

    private func startRuntimeWhenReady(attempt: Int) {
        if let environment = HostAppEnvironment.shared {
            installStatusItemIfNeeded(environment: environment)
            Task { @MainActor in
                await environment.startRuntimeIfNeeded()
            }
            return
        }

        guard attempt < 50 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startRuntimeWhenReady(attempt: attempt + 1)
        }
    }

    private func installStatusItemIfNeeded(environment: HostAppEnvironment) {
        guard statusItem == nil else { return }
        self.environment = environment

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = statusImage(for: environment.sessionCoordinator.phase)
            button.image?.isTemplate = true
            button.toolTip = "Vamp Mini Host"
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 404, height: 690)
        popover.contentViewController = NSHostingController(
            rootView: VampMiniHostPopover(
                environment: environment,
                onClose: { [weak self] in self?.closePopover() }
            )
        )
        self.popover = popover

        phaseObserver = environment.sessionCoordinator.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.statusItem?.button?.image = self?.statusImage(for: phase)
                self?.statusItem?.button?.image?.isTemplate = true
            }
    }

    private func statusImage(for phase: HostSessionCoordinator.SessionPhase) -> NSImage? {
        let symbol = phase == .error ? "exclamationmark.triangle.fill" : "rectangle.on.rectangle"
        return NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: phase == .error ? "Vamp Mini Host needs attention" : "Vamp Mini Host"
        )
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Vamp Mini Host")
        addMenuItem("Open Mini Host", action: #selector(openPopover), to: menu)

        let status = NSMenuItem(title: "Status: \(statusMenuTitle)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        addMenuItem(isRuntimeActive ? "Stop Host" : "Start Host", action: #selector(toggleRuntime), to: menu)
        addMenuItem("Restart Host", action: #selector(restartRuntime), to: menu)
        menu.addItem(.separator())

        addMenuItem("Copy Pairing Address", action: #selector(copyPairingAddress), to: menu)
        addMenuItem("Copy Host Fingerprint", action: #selector(copyHostFingerprint), to: menu)
        menu.addItem(.separator())

        addMenuItem("Screen Recording Settings…", action: #selector(openScreenRecordingSettings), to: menu)
        addMenuItem("Accessibility Settings…", action: #selector(openAccessibilitySettings), to: menu)
        menu.addItem(.separator())

        addMenuItem("Quit Vamp Mini Host", action: #selector(quitApp), keyEquivalent: "q", to: menu)
        return menu
    }

    private func addMenuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    private var isRuntimeActive: Bool {
        guard let phase = environment?.sessionCoordinator.phase else { return false }
        return phase != .idle && phase != .error
    }

    private var statusMenuTitle: String {
        guard let environment else { return "Starting" }
        if environment.pendingTrustPrompt != nil { return "Pairing approval required" }
        switch environment.sessionCoordinator.phase {
        case .streaming: return "Connected"
        case .advertising, .awaitingClient: return "Ready"
        case .error: return "Needs attention"
        case .idle: return "Stopped"
        default: return "Starting"
        }
    }

    @objc private func openPopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown != true { togglePopover(relativeTo: button) }
    }

    @objc private func toggleRuntime() {
        guard let environment else { return }
        Task {
            if isRuntimeActive {
                await environment.stopRuntime()
            } else {
                await environment.startRuntimeIfNeeded()
            }
        }
    }

    @objc private func restartRuntime() {
        guard let environment else { return }
        Task {
            await environment.stopRuntime()
            await environment.startRuntimeIfNeeded()
        }
    }

    @objc private func copyPairingAddress() {
        guard let address = localIPv4AddressForPairing() else { return }
        copyToPasteboard("\(address):\(RemoteDesktopConstants.defaultSignalingPort)")
    }

    @objc private func copyHostFingerprint() {
        guard let fingerprint = environment?.hostIdentity.publicKeyFingerprint else { return }
        copyToPasteboard(fingerprint)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func openScreenRecordingSettings() {
        guard let environment else { return }
        Task { await environment.permissionsViewModel.openSettings(for: .screenRecording) }
    }

    @objc private func openAccessibilitySettings() {
        guard let environment else { return }
        Task { await environment.permissionsViewModel.openSettings(for: .accessibility) }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func closePopover() {
        popover?.performClose(nil)
    }
}

private struct VampMiniHostPopover: View {
    @ObservedObject var environment: HostAppEnvironment
    @ObservedObject private var permissionsViewModel: HostPermissionsViewModel
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var trustedPeers: [TrustedPeer] = []
    @State private var isRefreshingPeers = false
    @State private var tailscaleInfo: TailscaleConnectionInfo?
    @State private var tailscaleInstalled = false
    @State private var copiedFingerprint = false

    init(environment: HostAppEnvironment, onClose: @escaping () -> Void = {}) {
        self.environment = environment
        self.onClose = onClose
        _permissionsViewModel = ObservedObject(wrappedValue: environment.permissionsViewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusCard

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let prompt = environment.pendingTrustPrompt {
                        VampMiniTrustPromptCard(
                            prompt: prompt,
                            onReject: { environment.resolveTrustPrompt(approved: false) },
                            onApprove: { environment.resolveTrustPrompt(approved: true) }
                        )
                        .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                    }

                    pairingCard
                    trustedDevicesCard
                    permissionsCard
                    HostTailscaleStatusView(
                        info: $tailscaleInfo,
                        installed: $tailscaleInstalled,
                        compact: true
                    )
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)

            Divider()
            controls
            footer
        }
        .padding(16)
        .frame(width: 404, height: 690)
        .background(VampMiniHostBackdrop())
        .task {
            await permissionsViewModel.refresh(requestOSPromptIfNeeded: false)
            await refreshPeers()
            let snapshot = await Task.detached(priority: .utility) {
                getTailscaleDetectionSnapshot()
            }.value
            tailscaleInfo = snapshot.info
            tailscaleInstalled = snapshot.installed
            await environment.discoveryAdvertiserViewModel.updateTailscaleIdentity(
                hostname: snapshot.info?.dnsName,
                ip: snapshot.info?.ipAddress
            )
        }
        .onChange(of: environment.pendingTrustPrompt?.id) { _ in
            Task { await refreshPeers() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: environment.pendingTrustPrompt?.id)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VampMiniHostMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vamp Mini Host")
                    .font(.headline)
                Text("Compact app-streaming host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VampMiniStatusBadge(text: statusTitle, color: statusColor)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Close Vamp Mini Host")
            .accessibilityLabel("Close Vamp Mini Host")
        }
        .accessibilityElement(children: .combine)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusMessage)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Text("9471 / 9472")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let error = environment.sessionCoordinator.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Signed discovery and authenticated data transport are active. Keep this host on a private LAN or tailnet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(VampMiniGlassSurface(cornerRadius: 16))
    }

    private var pairingCard: some View {
        VampMiniHostSection(title: "Pairing", systemImage: "person.badge.key.fill") {
            if let pairingLink, let pairingAddress {
                HStack(alignment: .top, spacing: 10) {
                    HostBrowserPairingQRCode(
                        pairingURL: pairingLink,
                        accessibilityLabel: "QR code for Vamp Stream pairing",
                        size: 118
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scan with Vamp Stream")
                            .font(.callout.weight(.semibold))
                        Text("Adds this Mac to the private host list. You still confirm the fingerprint before pairing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pairingAddress)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            } else {
                Label("Start the host on a private LAN or tailnet to show its pairing QR.", systemImage: "qrcode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Compare this fingerprint with the client through a separate trusted channel before accepting a new device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                Text(environment.hostIdentity.publicKeyFingerprint)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(environment.hostIdentity.publicKeyFingerprint, forType: .string)
                    copiedFingerprint = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        copiedFingerprint = false
                    }
                } label: {
                    Image(systemName: copiedFingerprint ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy host fingerprint")
                .accessibilityLabel(copiedFingerprint ? "Fingerprint copied" : "Copy host fingerprint")
            }
        }
    }

    @ViewBuilder
    private var trustedDevicesCard: some View {
        VampMiniHostSection(title: "Trusted devices", systemImage: "checkmark.shield.fill") {
            if isRefreshingPeers && trustedPeers.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if trustedPeers.isEmpty {
                Text("No devices have been approved yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(trustedPeers) { peer in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(peer.displayName)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button("Revoke", role: .destructive) {
                                Task {
                                    try? await environment.trustedPeerStore.revokePeer(id: peer.id)
                                    await refreshPeers()
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        Text(peer.fingerprint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    if peer.id != trustedPeers.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var permissionsCard: some View {
        VampMiniHostSection(title: "Permissions", systemImage: "lock.shield.fill") {
            Text("Screen Recording is required to stream Mac apps. Accessibility is required for keyboard and pointer control.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VampMiniPermissionRow(
                title: "Screen Recording",
                summary: permissionSummary(for: .screenRecording),
                systemImage: "rectangle.inset.filled.and.person.filled"
            ) {
                Task { await permissionsViewModel.openSettings(for: .screenRecording) }
            }
            VampMiniPermissionRow(
                title: "Accessibility",
                summary: permissionSummary(for: .accessibility),
                systemImage: "accessibility"
            ) {
                Task { await permissionsViewModel.openSettings(for: .accessibility) }
            }
            VampMiniPermissionRow(
                title: "Local Network",
                summary: "Used for private discovery",
                systemImage: "network"
            ) {
                openPrivacySettings("Privacy_LocalNetwork")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if isRunning {
                Button(role: .destructive) {
                    Task { await environment.stopRuntime() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await environment.startRuntimeIfNeeded() }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                Task {
                    await environment.stopRuntime()
                    await environment.startRuntimeIfNeeded()
                }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var footer: some View {
        HStack {
            Text("Private network only · no public relay")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }

    private var isRunning: Bool {
        environment.sessionCoordinator.phase != .idle && environment.sessionCoordinator.phase != .error
    }

    private var pairingAddress: String? {
        guard isRunning else { return nil }
        if let address = localIPv4AddressForPairing() {
            return "\(address):\(RemoteDesktopConstants.defaultSignalingPort)"
        }
        return tailscaleInfo?.connectAddress
    }

    private var pairingLink: String? {
        guard let pairingAddress else { return nil }
        return VampHostPairingLink.make(
            address: pairingAddress,
            displayName: environment.hostIdentity.displayName
        )
    }

    private var statusTitle: String {
        if environment.pendingTrustPrompt != nil { return "PAIRING" }
        switch environment.sessionCoordinator.phase {
        case .streaming: return "LIVE"
        case .advertising, .awaitingClient: return "READY"
        case .error: return "ERROR"
        case .idle: return "STOPPED"
        default: return "STARTING"
        }
    }

    private var statusMessage: String {
        switch statusTitle {
        case "LIVE": return "Trusted client connected"
        case "READY": return "Waiting for a trusted device"
        case "ERROR": return "Host needs attention"
        case "STOPPED": return "Host is stopped"
        case "PAIRING": return "Verify the device fingerprint"
        default: return "Starting secure host"
        }
    }

    private var statusColor: Color {
        switch statusTitle {
        case "LIVE": return .blue
        case "READY": return .green
        case "ERROR": return .orange
        case "PAIRING": return .orange
        default: return .secondary
        }
    }

    private func refreshPeers() async {
        isRefreshingPeers = true
        defer { isRefreshingPeers = false }
        trustedPeers = (try? await environment.trustedPeerStore.trustedPeers()) ?? []
    }

    private func permissionSummary(for kind: PermissionKind) -> String {
        guard let status = permissionsViewModel.statuses.first(where: { $0.kind == kind }) else {
            return permissionsViewModel.isRefreshing ? "Checking…" : "Needs checking"
        }
        switch status.authorizationState {
        case .granted: return "Ready"
        case .denied: return "Required · open Settings"
        case .notDetermined: return "Required · not requested"
        case .restricted: return "Restricted"
        case .unknown: return "Checking…"
        }
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct VampMiniTrustPromptCard: View {
    let prompt: HostAppEnvironment.TrustPrompt
    let onReject: () -> Void
    let onApprove: () -> Void

    private var formattedFingerprint: String {
        let value = prompt.fingerprint.lowercased().filter(\.isHexDigit)
        return stride(from: 0, to: value.count, by: 8).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: min(8, value.count - offset))
            return String(value[start..<end])
        }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("New device wants to pair", systemImage: "person.badge.key.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(prompt.displayName)
                .font(.headline)
            Text("Confirm that this fingerprint matches Vamp Stream, then approve once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(formattedFingerprint)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reject", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(13)
        .background(VampMiniGlassSurface(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.orange.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct VampMiniHostSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VampMiniGlassSurface(cornerRadius: 16))
    }
}

private struct VampMiniPermissionRow: View {
    let title: String
    let summary: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Settings", action: action)
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}

private struct VampMiniStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.primary.opacity(0.82))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(VampMiniGlassSurface(cornerRadius: 99))
    }
}

private struct VampMiniHostMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.primary.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                }
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Vamp Mini Host")
    }
}

private struct VampMiniHostBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.clear, Color.black.opacity(0.035)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

/// A neutral glass plate that adapts to light and dark appearances without
/// introducing a product tint. Semantic colors remain limited to small status cues.
private struct VampMiniGlassSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(colorScheme == .dark ? Color.white.opacity(0.065) : Color.white.opacity(0.42))
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.20 : 0.74),
                            Color.primary.opacity(0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.10 : 0.055), radius: 12, y: 5)
    }
}

/// First non-loopback IPv4 address, preferring Wi-Fi and Ethernet interfaces.
/// It gives the QR a directly connectable LAN address when Tailscale is absent.
private func localIPv4AddressForPairing() -> String? {
    var fallback: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        guard let socketAddress = ptr.pointee.ifa_addr else { continue }
        guard socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
        let interfaceName = String(cString: ptr.pointee.ifa_name)
        guard interfaceName != "lo0" else { continue }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(socketAddress.pointee.sa_len)
        guard getnameinfo(socketAddress, length, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else {
            continue
        }
        let address = String(cString: hostname)
        if interfaceName.hasPrefix("en") { return address }
        if fallback == nil { fallback = address }
    }
    return fallback
}
#endif
