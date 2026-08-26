#if VAMP_MINI_HOST && os(macOS)
import AppKit
import Combine
import Darwin
import SwiftUI
import SharedModels
import SharedUtilities
import Permissions

/// Storage used by the standalone Vamp Sync product. The legacy directory is
/// intentionally retained so existing trust data remains upgrade-compatible.
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
    private var trustPromptObserver: AnyCancellable?

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
            button.toolTip = "Vamp Sync"
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // The redesigned dashboard uses a narrow navigation rail and a
        // readable detail column. Keep it compact enough for a menu-bar popover
        // while giving state labels and actions room to breathe.
        popover.contentSize = NSSize(width: 500, height: 760)
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

        // Mini Host is menu-bar-only, so it has no dashboard window for the
        // shared trust gate to bring forward. Present the popover as soon as
        // a new client reaches the approval gate; otherwise pairing silently
        // expires while the approval card is hidden.
        trustPromptObserver = environment.$pendingTrustPrompt
            .receive(on: RunLoop.main)
            .sink { [weak self] prompt in
                guard prompt != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.showTrustPromptPopover()
                }
            }
    }

    private func statusImage(for phase: HostSessionCoordinator.SessionPhase) -> NSImage? {
        let symbol = phase == .error ? "exclamationmark.triangle.fill" : "rectangle.on.rectangle"
        return NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: phase == .error ? "Vamp Sync needs attention" : "Vamp Sync"
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
            makePopoverWindowTransparent()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Liquid Glass needs real desktop pixels behind the SwiftUI hierarchy.
    /// NSPopover otherwise supplies an opaque system background that turns every
    /// material surface into a flat gray card.
    private func makePopoverWindowTransparent() {
        guard let view = popover?.contentViewController?.view else { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // NSPopover owns one or more bezel/container views outside the hosting
        // view. Clear their layer fills too; otherwise that system gray remains
        // visible behind every SwiftUI glass surface.
        clearOpaqueLayerBackgrounds(in: window.contentView)
        DispatchQueue.main.async { [weak self] in
            self?.clearOpaqueLayerBackgrounds(in: window.contentView)
        }
    }

    private func clearOpaqueLayerBackgrounds(in view: NSView?) {
        guard let view else { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.subviews.forEach { clearOpaqueLayerBackgrounds(in: $0) }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Vamp Sync")
        addMenuItem("Open Vamp Sync", action: #selector(openPopover), to: menu)

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

        addMenuItem("Quit Vamp Sync", action: #selector(quitApp), keyEquivalent: "q", to: menu)
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

    private func showTrustPromptPopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown != true {
            togglePopover(relativeTo: button)
        }
        NSApp.activate(ignoringOtherApps: true)
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
    @State private var revokedPeers: [TrustedPeer] = []
    @State private var isRefreshingPeers = false
    @State private var tailscaleInfo: TailscaleConnectionInfo?
    @State private var tailscaleInstalled = false
    @State private var copiedFingerprint = false
    @State private var selectedSection: VampSyncPopoverSection = .overview

    init(environment: HostAppEnvironment, onClose: @escaping () -> Void = {}) {
        self.environment = environment
        self.onClose = onClose
        _permissionsViewModel = ObservedObject(wrappedValue: environment.permissionsViewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            VampSyncTopBar(
                statusTitle: statusTitle,
                statusColor: statusColor,
                onClose: onClose
            )

            VampSyncStatusHero(
                title: statusMessage,
                statusTitle: statusTitle,
                statusColor: statusColor,
                endpoint: pairingAddress
            )
            .padding(.horizontal, 16)
            .padding(.top, 4)

            VampSyncSectionPicker(
                selection: $selectedSection,
                hasPendingPairing: environment.pendingTrustPrompt != nil
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let prompt = environment.pendingTrustPrompt {
                        VampSyncPendingTrustBanner(
                            prompt: prompt,
                            onReject: { environment.resolveTrustPrompt(approved: false) },
                            onApprove: { environment.resolveTrustPrompt(approved: true) }
                        )
                        .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                    }

                    switch selectedSection {
                    case .overview:
                        VampSyncOverview(
                            trustedDeviceCount: trustedPeers.count,
                            permissionSummary: permissionOverviewText,
                            pairingAddress: pairingAddress,
                            tailscaleInfo: tailscaleInfo,
                            tailscaleInstalled: tailscaleInstalled,
                            onOpenTailscale: openTailscaleApplication
                        )
                    case .permissions:
                        VampSyncPermissions(
                            statuses: permissionsViewModel.statuses,
                            accessibilityRequired: environment.runtimePolicy.requiresAccessibilityPermission,
                            accessibilitySystemManaged: !environment.runtimePolicy.canRequestAccessibilityPermission,
                            isRefreshing: permissionsViewModel.isRefreshing,
                            permissionSummary: permissionOverviewText,
                            onRefresh: {
                                Task { await permissionsViewModel.refresh(requestOSPromptIfNeeded: false) }
                            },
                            onOpenSettings: { kind in
                                Task { await permissionsViewModel.openSettings(for: kind) }
                            }
                        )
                    case .pairing:
                        VampSyncPairing(
                            pairingLink: pairingLink,
                            pairingAddress: pairingAddress,
                            fingerprint: environment.hostIdentity.publicKeyFingerprint,
                            copiedFingerprint: copiedFingerprint,
                            trustedPeers: trustedPeers,
                            revokedPeers: revokedPeers,
                            isRefreshingPeers: isRefreshingPeers,
                            onCopyFingerprint: copyFingerprint,
                            onRevoke: revokePeer,
                            onPairAgain: { peer in
                                Task { await allowFreshPairing(for: peer) }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.visible)

            VampSyncActionBar(
                isRuntimeActive: isRuntimeActive,
                onToggleRuntime: {
                    Task {
                        if isRuntimeActive {
                            await environment.stopRuntime()
                        } else {
                            await environment.startRuntimeIfNeeded()
                        }
                    }
                },
                onRestart: {
                    Task {
                        await environment.stopRuntime()
                        await environment.startRuntimeIfNeeded()
                    }
                },
                onQuit: { NSApp.terminate(nil) }
            )
        }
        .frame(width: 500, height: 760)
        .background(VampSyncPopoverBackground())
        .foregroundStyle(.primary)
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
        // Returning from System Settings does not recreate the popover. Re-read
        // TCC state when this app becomes active so the visible badge changes
        // immediately from “Needs access” to “Granted”.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissionsViewModel.refresh(requestOSPromptIfNeeded: false) }
        }
        .onChange(of: environment.pendingTrustPrompt?.id) { _ in
            Task { await refreshPeers() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: environment.pendingTrustPrompt?.id)
    }

    private var isRuntimeActive: Bool {
        environment.sessionCoordinator.phase != .idle && environment.sessionCoordinator.phase != .error
    }

    private func copyFingerprint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(environment.hostIdentity.publicKeyFingerprint, forType: .string)
        copiedFingerprint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copiedFingerprint = false
        }
    }

    private func revokePeer(_ peer: TrustedPeer) {
        Task {
            try? await environment.trustedPeerStore.revokePeer(id: peer.id)
            await refreshPeers()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VampMiniHostMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vamp Sync")
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
            .help("Close Vamp Sync")
            .accessibilityLabel("Close Vamp Sync")
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

            if !revokedPeers.isEmpty {
                Divider()
                ForEach(revokedPeers) { peer in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Label(peer.displayName, systemImage: "person.crop.circle.badge.xmark")
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button("Pair Again") {
                                Task { await allowFreshPairing(for: peer) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Text("Blocked. Pair Again removes this old decision; the next connection will ask you to verify and approve a new fingerprint.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(peer.fingerprint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var permissionsCard: some View {
        VampMiniHostSection(title: "Permissions", systemImage: "lock.shield.fill") {
            HStack(spacing: 8) {
                Image(systemName: permissionsViewModel.allRequiredGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(permissionsViewModel.allRequiredGranted ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permissionsViewModel.allRequiredGranted ? "Ready for app streaming" : "Action needed before streaming")
                        .font(.caption.weight(.semibold))
                    Text(permissionOverviewText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await permissionsViewModel.refresh(requestOSPromptIfNeeded: false) }
                } label: {
                    Image(systemName: permissionsViewModel.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh permission status")
                .accessibilityLabel("Refresh permission status")
            }

            Text("These states are read from macOS. Vamp Sync never assumes access or opens a prompt during a background refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VampMiniPermissionRow(
                title: "Screen Recording",
                explanation: "Captures the Mac display for App Stream.",
                authorizationState: authorizationState(for: .screenRecording),
                systemImage: "rectangle.inset.filled.and.person.filled",
                isRequired: true
            ) {
                Task { await permissionsViewModel.openSettings(for: .screenRecording) }
            }
            VampMiniPermissionRow(
                title: "Accessibility",
                explanation: "Enables keyboard and pointer control when requested.",
                authorizationState: authorizationState(for: .accessibility),
                systemImage: "accessibility",
                isRequired: environment.runtimePolicy.requiresAccessibilityPermission,
                isSystemManaged: !environment.runtimePolicy.canRequestAccessibilityPermission
            ) {
                Task { await permissionsViewModel.openSettings(for: .accessibility) }
            }
            VampMiniPermissionRow(
                title: "Local Network",
                explanation: "Used for private LAN discovery and pairing.",
                authorizationState: nil,
                systemImage: "network",
                isRequired: false,
                isSystemManaged: true
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
        if let persistent = environment.trustedPeerStore as? PersistentTrustedPeerStore,
           let all = try? await persistent.allPeers() {
            trustedPeers = all.filter { !$0.isRevoked }
            revokedPeers = all.filter(\.isRevoked)
        } else {
            trustedPeers = (try? await environment.trustedPeerStore.trustedPeers()) ?? []
            revokedPeers = []
        }
    }

    /// Clears only the stale denial. The client must reconnect and the user must
    /// independently verify and approve the new pairing prompt.
    private func allowFreshPairing(for peer: TrustedPeer) async {
        guard let persistent = environment.trustedPeerStore as? PersistentTrustedPeerStore else { return }
        try? await persistent.removePeer(id: peer.id)
        await refreshPeers()
    }

    private func authorizationState(for kind: PermissionKind) -> PermissionAuthorizationState? {
        permissionsViewModel.statuses.first(where: { $0.kind == kind })?.authorizationState
    }

    private var permissionOverviewText: String {
        if permissionsViewModel.statuses.isEmpty {
            return permissionsViewModel.isRefreshing ? "Checking macOS privacy settings…" : "Permission state unavailable"
        }
        let granted = permissionsViewModel.statuses.filter(\.isGranted).count
        let total = permissionsViewModel.statuses.count
        return "\(granted) of \(total) required permission\(total == 1 ? "" : "s") granted"
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum VampSyncPopoverSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case permissions = "Permissions"
    case pairing = "Pairing"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .permissions: return "checkmark.shield"
        case .pairing: return "person.badge.key"
        }
    }
}

private struct VampSyncPopoverBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white)
                .opacity(colorScheme == .dark ? 0.90 : 0.78)
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.055 : 0.52),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.20 : 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct VampSyncSurface<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(
                (colorScheme == .dark
                    ? Color.white.opacity(0.055)
                    : Color.white.opacity(0.62)),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.16 : 0.74),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }
    }
}

private struct VampSyncTopBar: View {
    let statusTitle: String
    let statusColor: Color
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 38, height: 38)
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 18, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Vamp Sync")
                    .font(.headline.weight(.semibold))
                Text("Private app-streaming host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusTitle)
                    .font(.caption2.weight(.bold))
                    .tracking(0.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.08), in: Capsule())
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Close Vamp Sync")
            .accessibilityLabel("Close Vamp Sync")
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 10)
    }
}

private struct VampSyncStatusHero: View {
    let title: String
    let statusTitle: String
    let statusColor: Color
    let endpoint: String?

    var body: some View {
        VampSyncSurface(cornerRadius: 20) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.14))
                        .frame(width: 48, height: 48)
                    Circle()
                        .stroke(statusColor.opacity(0.42), lineWidth: 1)
                        .frame(width: 40, height: 40)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 11, height: 11)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(statusTitle == "LIVE" ? "A trusted device is connected" : "Signed discovery is listening")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("PORTS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.7)
                    Text("9471 · 9472")
                        .font(.caption2.monospaced().weight(.semibold))
                    if let endpoint {
                        Text(endpoint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }
}

private struct VampSyncSectionPicker: View {
    @Binding var selection: VampSyncPopoverSection
    let hasPendingPairing: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(VampSyncPopoverSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: section.systemImage)
                            .font(.caption.weight(.semibold))
                        Text(section.rawValue)
                            .font(.caption.weight(.semibold))
                        if section == .pairing, hasPendingPairing {
                            Circle()
                                .fill(.orange)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .foregroundStyle(selection == section ? .primary : .secondary)
                    .background(
                        selection == section ? Color.primary.opacity(0.12) : Color.clear,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
    }
}

private struct VampSyncOverview: View {
    let trustedDeviceCount: Int
    let permissionSummary: String
    let pairingAddress: String?
    let tailscaleInfo: TailscaleConnectionInfo?
    let tailscaleInstalled: Bool
    let onOpenTailscale: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VampSyncSurface {
                VStack(alignment: .leading, spacing: 13) {
                    VampSyncSectionHeading(title: "At a glance", subtitle: "The host is ready when these signals are healthy.")
                    HStack(spacing: 8) {
                        VampSyncStatTile(title: "Trusted devices", value: "\(trustedDeviceCount)", systemImage: "checkmark.shield")
                        VampSyncStatTile(title: "Required access", value: permissionSummary.replacingOccurrences(of: " required", with: ""), systemImage: "lock.shield")
                    }
                    Divider().opacity(0.45)
                    VampSyncOverviewRow(
                        title: "Private transport",
                        detail: pairingAddress ?? "Start the host to publish a pairing address.",
                        systemImage: "network"
                    )
                    VampSyncOverviewRow(
                        title: "Pairing",
                        detail: pairingAddress == nil ? "Waiting for the host to start" : "Scan from Vamp Stream, then approve once",
                        systemImage: "qrcode"
                    )
                }
            }

            VampSyncSurface {
                HStack(spacing: 11) {
                    Circle()
                        .fill(tailscaleInfo == nil ? Color.secondary : Color.green)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tailscale")
                            .font(.callout.weight(.semibold))
                        Text(tailscaleInfo?.dnsName ?? tailscaleInfo?.ipAddress ?? (tailscaleInstalled ? "Installed · waiting for connection" : "Not detected"))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button {
                        _ = onOpenTailscale()
                    } label: {
                        Label(tailscaleInfo == nil ? "Open" : "Manage", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("Vamp Sync only accepts authenticated connections on your private LAN or tailnet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 3)
        }
    }
}

private struct VampSyncSectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VampSyncStatTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct VampSyncOverviewRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct VampSyncPermissions: View {
    let statuses: [FriendlyPermissionStatus]
    let accessibilityRequired: Bool
    let accessibilitySystemManaged: Bool
    let isRefreshing: Bool
    let permissionSummary: String
    let onRefresh: () -> Void
    let onOpenSettings: (PermissionKind) -> Void

    var body: some View {
        VampSyncSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VampSyncSectionHeading(title: "Required access", subtitle: "Live TCC state from macOS. Nothing is assumed.")
                    Spacer(minLength: 8)
                    Button(action: onRefresh) {
                        Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh permission status")
                    .accessibilityLabel("Refresh permission status")
                }
                Text(permissionSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Divider().opacity(0.45)

                VampSyncPermissionRow(
                    title: "Screen Recording",
                    explanation: "Captures the Mac display for App Stream.",
                    authorizationState: statuses.first(where: { $0.kind == .screenRecording })?.authorizationState,
                    required: true,
                    systemManaged: false,
                    onSettings: { onOpenSettings(.screenRecording) }
                )
                VampSyncPermissionRow(
                    title: "Accessibility",
                    explanation: "Enables keyboard and pointer control when requested.",
                    authorizationState: statuses.first(where: { $0.kind == .accessibility })?.authorizationState,
                    required: accessibilityRequired,
                    systemManaged: accessibilitySystemManaged,
                    onSettings: { onOpenSettings(.accessibility) }
                )
                VampSyncPermissionRow(
                    title: "Local Network",
                    explanation: "Used for private LAN discovery and pairing.",
                    authorizationState: nil,
                    required: false,
                    systemManaged: true,
                    onSettings: { onOpenSettings(.localNetwork) }
                )
            }
        }
    }
}

private struct VampSyncPermissionRow: View {
    let title: String
    let explanation: String
    let authorizationState: PermissionAuthorizationState?
    let required: Bool
    let systemManaged: Bool
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stateIcon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(stateColor)
                .frame(width: 28, height: 28)
                .background(stateColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    if required {
                        Text("REQUIRED")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 7)
            VStack(alignment: .trailing, spacing: 5) {
                Label(stateLabel, systemImage: stateIcon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stateColor)
                Button("Settings", action: onSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    private var stateLabel: String {
        if systemManaged { return "System-managed" }
        guard let authorizationState else { return "Checking…" }
        switch authorizationState {
        case .granted: return "Granted"
        case .denied: return "Needs access"
        case .notDetermined: return "Not set up"
        case .restricted: return "Unavailable"
        case .unknown: return "Checking…"
        }
    }

    private var stateIcon: String {
        if systemManaged { return "info.circle.fill" }
        guard let authorizationState else { return "hourglass" }
        switch authorizationState {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .notDetermined: return "circle.dashed"
        case .restricted: return "nosign"
        case .unknown: return "hourglass"
        }
    }

    private var stateColor: Color {
        if systemManaged { return .secondary }
        guard let authorizationState else { return .secondary }
        switch authorizationState {
        case .granted: return .green
        case .denied: return .orange
        case .notDetermined, .unknown: return .secondary
        case .restricted: return .red
        }
    }
}

private struct VampSyncPairing: View {
    let pairingLink: String?
    let pairingAddress: String?
    let fingerprint: String
    let copiedFingerprint: Bool
    let trustedPeers: [TrustedPeer]
    let revokedPeers: [TrustedPeer]
    let isRefreshingPeers: Bool
    let onCopyFingerprint: () -> Void
    let onRevoke: (TrustedPeer) -> Void
    let onPairAgain: (TrustedPeer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VampSyncSurface {
                VStack(alignment: .leading, spacing: 12) {
                    VampSyncSectionHeading(title: "Pair a device", subtitle: "Scan this one-time code in Vamp Stream, then verify the fingerprint.")
                    if let pairingLink, let pairingAddress {
                        HStack(alignment: .top, spacing: 13) {
                            HostBrowserPairingQRCode(
                                pairingURL: pairingLink,
                                accessibilityLabel: "QR code for Vamp Stream pairing",
                                size: 126
                            )
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Vamp Stream")
                                    .font(.callout.weight(.semibold))
                                Text("Private LAN or tailnet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(pairingAddress)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }
                    } else {
                        Label("Start the host to publish a pairing code.", systemImage: "qrcode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider().opacity(0.45)
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Host fingerprint")
                                .font(.caption.weight(.semibold))
                            Text(fingerprint)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                        Button(action: onCopyFingerprint) {
                            Image(systemName: copiedFingerprint ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(copiedFingerprint ? "Fingerprint copied" : "Copy host fingerprint")
                        .accessibilityLabel(copiedFingerprint ? "Fingerprint copied" : "Copy host fingerprint")
                    }
                }
            }

            VampSyncSurface {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VampSyncSectionHeading(title: "Trusted devices", subtitle: "Only approved clients can connect.")
                        Spacer(minLength: 8)
                        if isRefreshingPeers {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if trustedPeers.isEmpty {
                        Text("No devices have been approved yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(trustedPeers) { peer in
                            VampSyncTrustedPeerRow(peer: peer, actionTitle: "Revoke", isDestructive: true) {
                                onRevoke(peer)
                            }
                        }
                    }
                    if !revokedPeers.isEmpty {
                        Divider().opacity(0.45)
                        ForEach(revokedPeers) { peer in
                            VampSyncTrustedPeerRow(peer: peer, actionTitle: "Pair again", isDestructive: false) {
                                onPairAgain(peer)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct VampSyncTrustedPeerRow: View {
    let peer: TrustedPeer
    let actionTitle: String
    let isDestructive: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isDestructive ? "checkmark.shield.fill" : "person.crop.circle.badge.xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(peer.fingerprint)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            Button(actionTitle, role: isDestructive ? .destructive : nil, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private struct VampSyncPendingTrustBanner: View {
    let prompt: HostAppEnvironment.TrustPrompt
    let onReject: () -> Void
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval needed")
                        .font(.callout.weight(.semibold))
                    Text("Verify this device before it can connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(prompt.displayName)
                .font(.headline)
            Text(prompt.fingerprint)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
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
        .padding(14)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.38), lineWidth: 0.8)
        }
    }
}

private struct VampSyncActionBar: View {
    let isRuntimeActive: Bool
    let onToggleRuntime: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleRuntime) {
                Label(isRuntimeActive ? "Stop" : "Start", systemImage: isRuntimeActive ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            Button(action: onRestart) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 34)
            }
            .buttonStyle(.bordered)
            .help("Restart host")
            Spacer(minLength: 4)
            Button("Quit", action: onQuit)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 0.75)
        }
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
    let explanation: String
    let authorizationState: PermissionAuthorizationState?
    let systemImage: String
    let isRequired: Bool
    var isSystemManaged = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(stateColor)
                .frame(width: 30, height: 30)
                .background(stateColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    if isRequired {
                        Text("REQUIRED")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: stateIcon)
                    Text(stateLabel)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(stateColor)
                Button("Settings", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption2.weight(.semibold))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    private var stateLabel: String {
        if isSystemManaged { return "System-managed" }
        guard let authorizationState else { return "Checking…" }
        switch authorizationState {
        case .granted: return "Granted"
        case .denied: return "Needs access"
        case .notDetermined: return "Not set up"
        case .restricted: return "Unavailable"
        case .unknown: return "Checking…"
        }
    }

    private var stateIcon: String {
        if isSystemManaged { return "info.circle.fill" }
        guard let authorizationState else { return "hourglass" }
        switch authorizationState {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.triangle.fill"
        case .notDetermined: return "circle.dashed"
        case .restricted: return "nosign"
        case .unknown: return "hourglass"
        }
    }

    private var stateColor: Color {
        if isSystemManaged { return .secondary }
        guard let authorizationState else { return .secondary }
        switch authorizationState {
        case .granted: return .green
        case .denied: return .orange
        case .notDetermined, .unknown: return .secondary
        case .restricted: return .red
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
        .accessibilityLabel("Vamp Sync")
    }
}

private struct VampMiniHostBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        } else {
            ZStack {
                // Keep the popover itself transparent. Glass belongs to the
                // functional cards; frosting the entire window first makes all
                // nested surfaces sample one flat gray layer.
                Color.clear
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.035 : 0.075),
                        Color.clear,
                        Color.black.opacity(colorScheme == .dark ? 0.055 : 0.018)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        }
    }
}

/// A neutral glass plate that adapts to light and dark appearances without
/// introducing a product tint. Semantic colors remain limited to small status cues.
private struct VampMiniGlassSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
#if compiler(>=6.2)
        if reduceTransparency {
            decorated(shape.fill(Color(nsColor: .controlBackgroundColor)), shape: shape)
        } else if #available(macOS 26.0, *) {
            decorated(
                ZStack {
                    GeometryReader { proxy in
                        Color.clear
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .glassEffect(.regular, in: shape)
                            .opacity(colorScheme == .dark ? 0.78 : 0.68)
                            .allowsHitTesting(false)
                    }
                    shape.fill(Color.white.opacity(colorScheme == .dark ? 0.025 : 0.055))
                },
                shape: shape
            )
        } else {
            decorated(shape.fill(.ultraThinMaterial), shape: shape)
        }
#else
        if reduceTransparency {
            decorated(shape.fill(Color(nsColor: .controlBackgroundColor)), shape: shape)
        } else {
            decorated(shape.fill(.ultraThinMaterial), shape: shape)
        }
#endif
    }

    private func decorated<Content: View, S: InsettableShape>(_ content: Content, shape: S) -> some View {
        content
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.34 : 0.72),
                            Color.white.opacity(colorScheme == .dark ? 0.10 : 0.22),
                            Color.black.opacity(colorScheme == .dark ? 0.20 : 0.075)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                shape
                    .inset(by: 1.2)
                    .trim(from: 0.03, to: 0.47)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.34), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.11), radius: 14, y: 7)
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
