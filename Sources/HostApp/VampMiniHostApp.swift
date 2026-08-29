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
    private var permissionObserver: AnyCancellable?
    private weak var statusDotView: VampSyncMenuBarStatusDotView?

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

            let dotView = VampSyncMenuBarStatusDotView()
            dotView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(dotView)
            NSLayoutConstraint.activate([
                dotView.widthAnchor.constraint(equalToConstant: 9),
                dotView.heightAnchor.constraint(equalToConstant: 9),
                dotView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                dotView.topAnchor.constraint(equalTo: button.topAnchor, constant: 2)
            ])
            statusDotView = dotView
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: VampSyncRedesignDesign.popoverWidth, height: VampSyncRedesignDesign.popoverHeight)
        popover.contentViewController = NSHostingController(
            rootView: VampSyncRedesignPopover(
                environment: environment,
                onClose: { [weak self] in self?.closePopover() }
            )
        )
        self.popover = popover

        phaseObserver = environment.sessionCoordinator.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }

        // Mini Host is menu-bar-only, so it has no dashboard window for the
        // shared trust gate to bring forward. Present the popover as soon as
        // a new client reaches the approval gate; otherwise pairing silently
        // expires while the approval card is hidden.
        trustPromptObserver = environment.$pendingTrustPrompt
            .receive(on: RunLoop.main)
            .sink { [weak self] prompt in
                self?.updateStatusItem()
                guard prompt != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.showTrustPromptPopover()
                }
            }

        permissionObserver = environment.permissionsViewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.updateStatusItem()
            }
        updateStatusItem()
    }

    private func statusImage(for phase: HostSessionCoordinator.SessionPhase) -> NSImage? {
        let symbol = phase == .error ? "exclamationmark.triangle.fill" : "rectangle.on.rectangle"
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: phase == .error ? "Vamp Sync needs attention" : "Vamp Sync"
        )
        image?.isTemplate = true
        return image
    }

    private func updateStatusItem() {
        guard let environment else { return }
        statusItem?.button?.image = statusImage(for: environment.sessionCoordinator.phase)
        statusItem?.button?.image?.isTemplate = true

        let dotState: VampSyncMenuBarStatusDotView.State
        if environment.sessionCoordinator.phase == .error {
            dotState = .problem
        } else if environment.pendingTrustPrompt != nil {
            dotState = .approval
        } else if environment.sessionCoordinator.phase == .streaming {
            dotState = .streaming
        } else {
            dotState = .none
        }
        statusDotView?.state = dotState
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
    @AppStorage("vampSyncAppearance") private var appearance = VampSyncAppearance.system

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
                detail: statusDetail,
                statusColor: statusColor,
                endpoint: pairingAddress
            )
            .padding(.horizontal, VampSyncDesign.outerPadding)
            .padding(.top, 4)

            VampSyncSectionPicker(
                selection: $selectedSection,
                hasPendingPairing: environment.pendingTrustPrompt != nil
            )
            .padding(.horizontal, VampSyncDesign.outerPadding)
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
                            grantedPermissionCount: grantedPermissionCount,
                            totalPermissionCount: permissionsViewModel.statuses.count,
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
                .padding(.horizontal, VampSyncDesign.outerPadding)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.visible)

            VampSyncActionBar(
                isRuntimeActive: isRuntimeActive,
                appearance: $appearance,
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
        .frame(width: VampSyncDesign.windowWidth, height: selectedSection.preferredHeight)
        .background(VampSyncPopoverBackground())
        .foregroundStyle(.primary)
        .preferredColorScheme(appearance.colorScheme)
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
        if environment.pendingTrustPrompt != nil { return "Pairing" }
        switch environment.sessionCoordinator.phase {
        case .streaming: return "Live"
        case .advertising, .awaitingClient: return "Ready"
        case .error: return "Error"
        case .idle: return "Stopped"
        default: return "Starting"
        }
    }

    private var statusMessage: String {
        switch statusTitle {
        case "Live": return "Trusted client connected"
        case "Ready": return "Waiting for a trusted device"
        case "Error": return "Host needs attention"
        case "Stopped": return "Host is stopped"
        case "Pairing": return "Verify the device fingerprint"
        default: return "Starting secure host"
        }
    }

    private var statusDetail: String {
        switch statusTitle {
        case "Live": return "A trusted device is connected"
        case "Ready": return "Signed discovery is listening"
        case "Error": return environment.sessionCoordinator.errorMessage ?? "Check the host configuration"
        case "Stopped": return "Discovery and transport are offline"
        case "Pairing": return "Compare the fingerprint before approving"
        default: return "Preparing signed discovery"
        }
    }

    private var statusColor: Color {
        switch statusTitle {
        case "Live": return .green
        case "Ready": return .green
        case "Error": return .orange
        case "Pairing": return .orange
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

    private var grantedPermissionCount: Int {
        permissionsViewModel.statuses.filter(\.isGranted).count
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum VampSyncAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private enum VampSyncPopoverSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case permissions = "Permissions"
    case pairing = "Pairing"

    var id: String { rawValue }

    var preferredHeight: CGFloat {
        switch self {
        case .overview: 620
        case .permissions: 670
        case .pairing: 740
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .permissions: return "checkmark.shield"
        case .pairing: return "person.badge.key"
        }
    }
}

private enum VampSyncDesign {
    static let windowWidth: CGFloat = 500
    static let outerPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 12
    static let statusRadius: CGFloat = 16
    static let controlRadius: CGFloat = 9
    static let controlHeight: CGFloat = 30
    static let hairline: CGFloat = 0.75
}

private struct VampSyncPopoverBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(colorScheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.10))
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
        HStack(spacing: 12) {
            VampMiniHostMark(size: 36)
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
                    .font(.caption.weight(.medium))
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: VampSyncDesign.controlHeight, height: VampSyncDesign.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close Vamp Sync")
            .accessibilityLabel("Close Vamp Sync")
        }
        .padding(.horizontal, VampSyncDesign.outerPadding)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

private struct VampSyncStatusHero: View {
    let title: String
    let detail: String
    let statusColor: Color
    let endpoint: String?

    var body: some View {
        VampSyncSurface(cornerRadius: VampSyncDesign.statusRadius) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(statusColor.opacity(0.12)).frame(width: 44, height: 44)
                    Circle()
                        .stroke(statusColor.opacity(0.42), lineWidth: 1)
                        .frame(width: 36, height: 36)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: statusColor.opacity(0.65), radius: 5)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(detail)
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
        HStack(spacing: 2) {
            ForEach(VampSyncPopoverSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 5) {
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
                    .frame(maxWidth: .infinity, minHeight: VampSyncDesign.controlHeight)
                    .foregroundStyle(selection == section ? .primary : .secondary)
                    .background(
                        selection == section ? Color.primary.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: VampSyncDesign.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VampSyncDesign.controlRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: VampSyncDesign.hairline))
    }
}

private struct VampSyncOverview: View {
    let trustedDeviceCount: Int
    let grantedPermissionCount: Int
    let totalPermissionCount: Int
    let pairingAddress: String?
    let tailscaleInfo: TailscaleConnectionInfo?
    let tailscaleInstalled: Bool
    let onOpenTailscale: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: VampSyncDesign.sectionSpacing) {
            VampSyncSurface {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 0) {
                        VampSyncSummaryMetric(title: "Trusted Devices", value: "\(trustedDeviceCount)", detail: trustedDeviceCount == 0 ? "No trusted devices yet" : "Approved devices")
                        Divider().padding(.horizontal, 16)
                        VampSyncSummaryMetric(title: "Permissions", value: "\(grantedPermissionCount) / \(totalPermissionCount)", detail: "Permissions granted")
                    }
                    Divider()
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

            VStack(spacing: 0) {
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
                .padding(.vertical, 2)
            }

            Label {
                Text("Vamp Sync only accepts authenticated connections on your private LAN or tailnet.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
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

private struct VampSyncSummaryMetric: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @Binding var appearance: VampSyncAppearance
    let onToggleRuntime: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleRuntime) {
                Label(isRuntimeActive ? "Stop Host" : "Start Host", systemImage: isRuntimeActive ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            Button {
                appearance = colorScheme == .dark ? .light : .dark
            } label: {
                Image(systemName: colorScheme == .dark ? "sun.max" : "moon.fill")
                    .frame(width: VampSyncDesign.controlHeight, height: VampSyncDesign.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(colorScheme == .dark ? "Switch to Light Mode" : "Switch to Dark Mode")
            .accessibilityLabel(colorScheme == .dark ? "Switch to Light Mode" : "Switch to Dark Mode")
            Button(action: onRestart) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: VampSyncDesign.controlHeight, height: VampSyncDesign.controlHeight)
            }
            .buttonStyle(.bordered)
            .help("Restart host")
            Spacer(minLength: 4)
            Button("Quit", action: onQuit)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, VampSyncDesign.outerPadding)
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
private enum VampSyncRedesignDesign {
    static let popoverWidth: CGFloat = 380
    static let popoverHeight: CGFloat = 650
    static let contentInset: CGFloat = 16
    static let stageRadius: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 8
    static let hairline: CGFloat = 0.5
}

private struct VampSyncRedesignPalette {
    let colorScheme: ColorScheme

    private var isDark: Bool { colorScheme == .dark }

    var popover: Color { isDark ? Color(red: 0.094, green: 0.094, blue: 0.094) : Color(red: 0.965, green: 0.965, blue: 0.955) }
    var primary: Color { isDark ? Color(red: 0.98, green: 0.98, blue: 0.98) : Color(red: 0.10, green: 0.10, blue: 0.095) }
    var secondary: Color { isDark ? Color(red: 0.84, green: 0.84, blue: 0.84) : Color(red: 0.22, green: 0.22, blue: 0.21) }
    var tertiary: Color { isDark ? Color(red: 0.66, green: 0.66, blue: 0.66) : Color(red: 0.34, green: 0.34, blue: 0.33) }
    var muted: Color { isDark ? Color(red: 0.54, green: 0.54, blue: 0.54) : Color(red: 0.39, green: 0.39, blue: 0.38) }
    // Keep metadata subdued without dropping below a readable contrast level
    // against either the dark or light popover surface.
    var faint: Color { isDark ? Color(red: 0.50, green: 0.50, blue: 0.50) : Color(red: 0.40, green: 0.40, blue: 0.39) }
    var raised: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.055) }
    var subtle: Color { isDark ? Color.white.opacity(0.045) : Color.black.opacity(0.035) }
    var attention: Color { isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.06) }
    var tile: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07) }
    var divider: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.14) }
    var border: Color { isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.15) }
    var strongBorder: Color { isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.25) }
    var primaryButton: Color { isDark ? Color(red: 0.98, green: 0.98, blue: 0.98) : Color(red: 0.10, green: 0.10, blue: 0.095) }
    var primaryButtonText: Color { isDark ? Color(red: 0.095, green: 0.095, blue: 0.095) : Color.white }
    var errorSurface: Color { Color(red: 1.0, green: 0.176, blue: 0.145).opacity(isDark ? 0.13 : 0.10) }
    var errorBorder: Color { Color(red: 1.0, green: 0.176, blue: 0.145).opacity(isDark ? 0.32 : 0.35) }
}

private enum VampSyncRedesignState: Equatable {
    case stopped
    case starting
    case ready
    case live
    case pending(displayName: String, fingerprint: String)
    case permissionMissing(kind: PermissionKind, title: String)
    case error(message: String)
}

private final class VampSyncMenuBarStatusDotView: NSView {
    enum State: Equatable {
        case none
        case streaming
        case approval
        case problem
    }

    var state: State = .none {
        didSet {
            isHidden = state == .none
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard state != .none, let context = NSGraphicsContext.current?.cgContext else { return }
        let dotColor: NSColor
        switch state {
        case .none: return
        case .streaming: dotColor = NSColor(calibratedRed: 0.298, green: 0.851, blue: 0.392, alpha: 1)
        case .approval: dotColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.0, alpha: 1)
        case .problem: dotColor = NSColor(calibratedRed: 1.0, green: 0.271, blue: 0.227, alpha: 1)
        }

        let ringRect = bounds.insetBy(dx: 0.4, dy: 0.4)
        NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
        context.fillEllipse(in: ringRect)
        dotColor.setFill()
        context.fillEllipse(in: bounds.insetBy(dx: 2.0, dy: 2.0))
    }
}

private struct VampSyncRedesignPopover: View {
    @ObservedObject var environment: HostAppEnvironment
    @ObservedObject private var permissionsViewModel: HostPermissionsViewModel
    @ObservedObject private var sessionCoordinator: HostSessionCoordinator
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var trustedPeers: [TrustedPeer] = []
    @State private var revokedPeers: [TrustedPeer] = []
    @State private var isRefreshingPeers = false
    @State private var tailscaleInfo: TailscaleConnectionInfo?
    @State private var copiedText: String?
    @State private var selectedSection: VampSyncRedesignSection = .status
    @State private var onboardingStep = 1
    @State private var framesPerSecond: Int?
    @State private var lastFrameSampleCount: UInt64?
    @State private var lastFrameSampleAt: Date?
    @AppStorage("vampSyncAppearance") private var appearance = VampSyncAppearance.system
    @AppStorage("vampSync.onboarding.completed") private var hasCompletedOnboarding = false

    init(environment: HostAppEnvironment, onClose: @escaping () -> Void = {}) {
        self.environment = environment
        self.onClose = onClose
        _permissionsViewModel = ObservedObject(wrappedValue: environment.permissionsViewModel)
        _sessionCoordinator = ObservedObject(wrappedValue: environment.sessionCoordinator)
    }

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                VampSyncRedesignDashboard(
                    environment: environment,
                    permissionsViewModel: permissionsViewModel,
                    selectedSection: $selectedSection,
                    appearance: $appearance,
                    stageState: selectedStageState,
                    pendingPrompt: environment.pendingTrustPrompt,
                    trustedPeers: trustedPeers,
                    revokedPeers: revokedPeers,
                    isRefreshingPeers: isRefreshingPeers,
                    tailscaleInfo: tailscaleInfo,
                    localAddress: localAddress,
                    pairingLink: pairingLink,
                    copiedText: copiedText,
                    framesPerSecond: framesPerSecond,
                    onClose: onClose,
                    onStart: startRuntime,
                    onStop: stopRuntime,
                    onPairDevice: pairDevice,
                    onReviewPrompt: { selectedSection = .devices },
                    onApprovePrompt: { environment.resolveTrustPrompt(approved: true) },
                    onRejectPrompt: { environment.resolveTrustPrompt(approved: false) },
                    onOpenPermissionSettings: openPermissionSettings,
                    onRefresh: { Task { await refreshAll() } },
                    onRestart: restartRuntime,
                    onCopy: copyToPasteboard,
                    onRevoke: revokePeer,
                    onPairAgain: allowFreshPairing,
                    onQuit: { NSApp.terminate(nil) },
                    onAppearanceChange: { appearance = $0 }
                )
            } else {
                VampSyncRedesignOnboarding(
                    step: $onboardingStep,
                    permissions: permissionsViewModel.statuses,
                    accessibilityRequired: environment.runtimePolicy.requiresAccessibilityPermission,
                    accessibilitySystemManaged: !environment.runtimePolicy.canRequestAccessibilityPermission,
                    pairingLink: pairingLink,
                    pairingAddress: pairingAddress,
                    fingerprint: environment.hostIdentity.publicKeyFingerprint,
                    onClose: onClose,
                    onStart: startRuntime,
                    onOpenPermissionSettings: openPermissionSettings,
                    onFinish: { hasCompletedOnboarding = true }
                )
            }
        }
        .frame(width: VampSyncRedesignDesign.popoverWidth, height: VampSyncRedesignDesign.popoverHeight)
        .background(VampSyncRedesignBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(VampSyncRedesignPalette(colorScheme: colorScheme).border, lineWidth: VampSyncRedesignDesign.hairline)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(appearance.colorScheme)
        .task {
            await refreshAll()
        }
        .task {
            await sampleStreamingRate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissionsViewModel.refresh(requestOSPromptIfNeeded: false) }
        }
        .onChange(of: environment.pendingTrustPrompt?.id) { _ in
            Task { await refreshPeers() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selectedSection)
    }

    private var baseStageState: VampSyncRedesignState {
        if sessionCoordinator.phase == .error {
            return .error(message: sessionCoordinator.errorMessage ?? "Vamp Sync could not start the host.")
        }
        if let blocker = permissionsViewModel.blockers.first {
            return .permissionMissing(kind: blocker.kind, title: blocker.title)
        }

        switch sessionCoordinator.phase {
        case .streaming:
            return .live
        case .advertising, .awaitingClient:
            return .ready
        case .idle:
            return .stopped
        default:
            return .starting
        }
    }

    private var selectedStageState: VampSyncRedesignState {
        if case .error = baseStageState { return baseStageState }
        if selectedSection == .devices, let prompt = environment.pendingTrustPrompt {
            return .pending(displayName: prompt.displayName, fingerprint: prompt.fingerprint)
        }
        return baseStageState
    }

    private var localAddress: String? {
        guard isRuntimeActive else { return nil }
        return localIPv4AddressForPairing()
    }

    private var pairingAddress: String? {
        guard isRuntimeActive else { return nil }
        if let localAddress { return "\(localAddress):\(RemoteDesktopConstants.defaultSignalingPort)" }
        return tailscaleInfo?.connectAddress
    }

    private var pairingLink: String? {
        guard let pairingAddress else { return nil }
        return VampHostPairingLink.make(address: pairingAddress, displayName: environment.hostIdentity.displayName)
    }

    private var isRuntimeActive: Bool {
        let phase = sessionCoordinator.phase
        return phase != .idle && phase != .error
    }

    private func startRuntime() {
        Task { await environment.startRuntimeIfNeeded() }
    }

    private func stopRuntime() {
        Task { await environment.stopRuntime() }
    }

    private func restartRuntime() {
        Task {
            await environment.stopRuntime()
            await environment.startRuntimeIfNeeded()
        }
    }

    private func pairDevice() {
        selectedSection = .devices
        if !isRuntimeActive { startRuntime() }
    }

    private func openPermissionSettings(_ kind: PermissionKind) {
        Task { await permissionsViewModel.openSettings(for: kind) }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedText = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [value] in
            if copiedText == value { copiedText = nil }
        }
    }

    private func revokePeer(_ peer: TrustedPeer) {
        Task {
            try? await environment.trustedPeerStore.revokePeer(id: peer.id)
            await refreshPeers()
        }
    }

    private func allowFreshPairing(_ peer: TrustedPeer) {
        Task {
            guard let persistent = environment.trustedPeerStore as? PersistentTrustedPeerStore else { return }
            try? await persistent.removePeer(id: peer.id)
            await refreshPeers()
        }
    }

    private func refreshAll() async {
        await permissionsViewModel.refresh(requestOSPromptIfNeeded: false)
        await refreshPeers()
        let snapshot = await Task.detached(priority: .utility) {
            getTailscaleDetectionSnapshot()
        }.value
        guard !Task.isCancelled else { return }
        tailscaleInfo = snapshot.info
        await environment.discoveryAdvertiserViewModel.updateTailscaleIdentity(
            hostname: snapshot.info?.dnsName,
            ip: snapshot.info?.ipAddress
        )
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

    private func sampleStreamingRate() async {
        while !Task.isCancelled {
            let count = environment.streamingCoordinator.streamDiagnostics.framesSent
            let now = Date()
            if let lastCount = lastFrameSampleCount, let lastDate = lastFrameSampleAt {
                let elapsed = max(now.timeIntervalSince(lastDate), 0.1)
                let delta = count >= lastCount ? count - lastCount : 0
                framesPerSecond = max(0, Int((Double(delta) / elapsed).rounded()))
            }
            lastFrameSampleCount = count
            lastFrameSampleAt = now
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

private enum VampSyncRedesignSection: String, CaseIterable, Identifiable {
    case status = "Status"
    case devices = "Devices"
    case access = "Access"

    var id: String { rawValue }
}

private struct VampSyncRedesignDashboard: View {
    @ObservedObject var environment: HostAppEnvironment
    @ObservedObject private var sessionCoordinator: HostSessionCoordinator
    @ObservedObject var permissionsViewModel: HostPermissionsViewModel
    @Binding var selectedSection: VampSyncRedesignSection
    @Binding var appearance: VampSyncAppearance
    let stageState: VampSyncRedesignState
    let pendingPrompt: HostAppEnvironment.TrustPrompt?
    let trustedPeers: [TrustedPeer]
    let revokedPeers: [TrustedPeer]
    let isRefreshingPeers: Bool
    let tailscaleInfo: TailscaleConnectionInfo?
    let localAddress: String?
    let pairingLink: String?
    let copiedText: String?
    let framesPerSecond: Int?
    let onClose: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onPairDevice: () -> Void
    let onReviewPrompt: () -> Void
    let onApprovePrompt: () -> Void
    let onRejectPrompt: () -> Void
    let onOpenPermissionSettings: (PermissionKind) -> Void
    let onRefresh: () -> Void
    let onRestart: () -> Void
    let onCopy: (String) -> Void
    let onRevoke: (TrustedPeer) -> Void
    let onPairAgain: (TrustedPeer) -> Void
    let onQuit: () -> Void
    let onAppearanceChange: (VampSyncAppearance) -> Void

    init(
        environment: HostAppEnvironment,
        permissionsViewModel: HostPermissionsViewModel,
        selectedSection: Binding<VampSyncRedesignSection>,
        appearance: Binding<VampSyncAppearance>,
        stageState: VampSyncRedesignState,
        pendingPrompt: HostAppEnvironment.TrustPrompt?,
        trustedPeers: [TrustedPeer],
        revokedPeers: [TrustedPeer],
        isRefreshingPeers: Bool,
        tailscaleInfo: TailscaleConnectionInfo?,
        localAddress: String?,
        pairingLink: String?,
        copiedText: String?,
        framesPerSecond: Int?,
        onClose: @escaping () -> Void,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onPairDevice: @escaping () -> Void,
        onReviewPrompt: @escaping () -> Void,
        onApprovePrompt: @escaping () -> Void,
        onRejectPrompt: @escaping () -> Void,
        onOpenPermissionSettings: @escaping (PermissionKind) -> Void,
        onRefresh: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onCopy: @escaping (String) -> Void,
        onRevoke: @escaping (TrustedPeer) -> Void,
        onPairAgain: @escaping (TrustedPeer) -> Void,
        onQuit: @escaping () -> Void,
        onAppearanceChange: @escaping (VampSyncAppearance) -> Void
    ) {
        self.environment = environment
        self._sessionCoordinator = ObservedObject(wrappedValue: environment.sessionCoordinator)
        self.permissionsViewModel = permissionsViewModel
        self._selectedSection = selectedSection
        self._appearance = appearance
        self.stageState = stageState
        self.pendingPrompt = pendingPrompt
        self.trustedPeers = trustedPeers
        self.revokedPeers = revokedPeers
        self.isRefreshingPeers = isRefreshingPeers
        self.tailscaleInfo = tailscaleInfo
        self.localAddress = localAddress
        self.pairingLink = pairingLink
        self.copiedText = copiedText
        self.framesPerSecond = framesPerSecond
        self.onClose = onClose
        self.onStart = onStart
        self.onStop = onStop
        self.onPairDevice = onPairDevice
        self.onReviewPrompt = onReviewPrompt
        self.onApprovePrompt = onApprovePrompt
        self.onRejectPrompt = onRejectPrompt
        self.onOpenPermissionSettings = onOpenPermissionSettings
        self.onRefresh = onRefresh
        self.onRestart = onRestart
        self.onCopy = onCopy
        self.onRevoke = onRevoke
        self.onPairAgain = onPairAgain
        self.onQuit = onQuit
        self.onAppearanceChange = onAppearanceChange
    }

    var body: some View {
        VStack(spacing: 0) {
            VampSyncRedesignHeader(
                statusTitle: statusBadgeTitle,
                statusColor: statusColor,
                onClose: onClose
            )

            VampSyncRedesignStatusStage(
                state: stageState,
                connectedClientName: environment.sessionCoordinator.connectedClientName,
                framesPerSecond: framesPerSecond,
                linkLabel: tailscaleInfo == nil ? "LAN" : "tailnet",
                onStart: onStart,
                onStop: onStop,
                onPairDevice: onPairDevice,
                onApprove: onApprovePrompt,
                onReject: onRejectPrompt,
                copiedText: copiedText,
                onCopyFingerprint: onCopy,
                onOpenSettings: { kind in onOpenPermissionSettings(kind) },
                onRecheck: onRefresh,
                onRestart: onRestart,
                onCopyLog: { onCopy(environment.sessionCoordinator.errorMessage ?? "Vamp Sync error log unavailable.") }
            )
            .padding(.horizontal, VampSyncRedesignDesign.contentInset)

            VampSyncRedesignTabs(selection: $selectedSection, hasPendingApproval: pendingPrompt != nil)

            ScrollView {
                Group {
                    switch selectedSection {
                    case .status:
                        VampSyncRedesignStatusSection(
                            pendingPrompt: pendingPrompt,
                            trustedCount: trustedPeers.count,
                            grantedPermissionCount: permissionsViewModel.statuses.filter(\.isGranted).count,
                            totalPermissionCount: permissionsViewModel.statuses.count,
                            tailscaleInfo: tailscaleInfo,
                            localAddress: localAddress,
                            isRuntimeActive: runtimeIsActive,
                            onReviewPrompt: onReviewPrompt
                        )
                    case .devices:
                        VampSyncRedesignDevicesSection(
                            pairingLink: pairingLink,
                            trustedPeers: trustedPeers,
                            revokedPeers: revokedPeers,
                            isRefreshing: isRefreshingPeers,
                            onRevoke: onRevoke,
                            onPairAgain: onPairAgain,
                            onAddDevice: onPairDevice
                        )
                    case .access:
                        VampSyncRedesignAccessSection(
                            statuses: permissionsViewModel.statuses,
                            accessibilityRequired: environment.runtimePolicy.requiresAccessibilityPermission,
                            accessibilitySystemManaged: !environment.runtimePolicy.canRequestAccessibilityPermission,
                            isRefreshing: permissionsViewModel.isRefreshing,
                            onRefresh: onRefresh,
                            onOpenSettings: onOpenPermissionSettings
                        )
                    }
                }
                .padding(.horizontal, VampSyncRedesignDesign.contentInset)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.visible)

            VampSyncRedesignFooter(
                trustedCount: trustedPeers.count,
                appearance: $appearance,
                onRefresh: onRefresh,
                onRestart: onRestart,
                onQuit: onQuit,
                onAppearanceChange: onAppearanceChange
            )
        }
    }

    private var statusBadgeTitle: String {
        switch stageState {
        case .error: return "PROBLEM"
        case .permissionMissing: return "PROBLEM"
        case .pending: return "APPROVE"
        case .live: return "LIVE"
        case .ready: return "READY"
        case .stopped: return "OFF"
        case .starting: return "STARTING"
        }
    }

    private var statusColor: Color {
        switch stageState {
        case .error: return VampSyncRedesignColors.error
        case .permissionMissing, .pending: return VampSyncRedesignColors.attention
        case .live, .ready: return VampSyncRedesignColors.live
        case .stopped: return VampSyncRedesignColors.off
        case .starting: return VampSyncRedesignColors.neutral
        }
    }

    private var runtimeIsActive: Bool {
        let phase = environment.sessionCoordinator.phase
        return phase != .idle && phase != .error
    }
}

private enum VampSyncRedesignColors {
    static let live = Color(red: 0.298, green: 0.851, blue: 0.392)
    static let attention = Color(red: 1.0, green: 0.8, blue: 0.0)
    static let error = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let off = Color(red: 0.365, green: 0.365, blue: 0.337)
    static let neutral = Color(red: 0.72, green: 0.72, blue: 0.72)
}

private struct VampSyncRedesignStatusSection: View {
    let pendingPrompt: HostAppEnvironment.TrustPrompt?
    let trustedCount: Int
    let grantedPermissionCount: Int
    let totalPermissionCount: Int
    let tailscaleInfo: TailscaleConnectionInfo?
    let localAddress: String?
    let isRuntimeActive: Bool
    let onReviewPrompt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pendingPrompt {
                VampSyncRedesignPendingApprovalRow(prompt: pendingPrompt, onReview: onReviewPrompt)
            }

            VampSyncRedesignThisMacCard(
                trustedCount: trustedCount,
                grantedPermissionCount: grantedPermissionCount,
                totalPermissionCount: totalPermissionCount,
                tailscaleInfo: tailscaleInfo,
                localAddress: localAddress,
                isRuntimeActive: isRuntimeActive
            )
        }
    }
}

private struct VampSyncRedesignPendingApprovalRow: View {
    let prompt: HostAppEnvironment.TrustPrompt
    let onReview: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncRedesignSurface(style: .attention, cornerRadius: VampSyncRedesignDesign.cardRadius, padding: 11) {
            HStack(spacing: 10) {
                Circle()
                    .fill(VampSyncRedesignColors.attention)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(prompt.displayName) wants to pair")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                        .lineLimit(1)
                    Text(vampSyncRedesignGroupedFingerprint(prompt.fingerprint).joined(separator: " "))
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                VampSyncRedesignButton(title: "Review", variant: .primary, maxWidth: false, action: onReview)
                    .frame(width: 58)
            }
        }
    }
}

private struct VampSyncRedesignThisMacCard: View {
    let trustedCount: Int
    let grantedPermissionCount: Int
    let totalPermissionCount: Int
    let tailscaleInfo: TailscaleConnectionInfo?
    let localAddress: String?
    let isRuntimeActive: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncRedesignSurface(style: .subtle, cornerRadius: VampSyncRedesignDesign.cardRadius, padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    VampSyncRedesignSectionLabel(text: "THIS MAC")
                    Spacer(minLength: 8)
                    Text("9471 · 9472")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).faint)
                }

                VampSyncRedesignAddressRow(
                    value: tailscaleInfo?.connectAddress ?? (isRuntimeActive ? "Not connected" : "Start host to publish"),
                    label: "Tailnet",
                    isAvailable: tailscaleInfo != nil
                )
                VampSyncRedesignAddressRow(
                    value: localAddress.map { "\($0):\(RemoteDesktopConstants.defaultSignalingPort)" } ?? (isRuntimeActive ? "Not available" : "Start host to publish"),
                    label: "LAN",
                    isAvailable: localAddress != nil
                )

                VampSyncRedesignHairline()

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                    Text("Authenticated peers only. No relay, no account.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Authenticated peers only. No relay, no account.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This Mac. \(trustedSummary), \(permissionSummary)")
    }

    private var trustedSummary: String {
        "\(trustedCount) trusted device\(trustedCount == 1 ? "" : "s")"
    }

    private var permissionSummary: String {
        "\(grantedPermissionCount) of \(totalPermissionCount) permissions granted"
    }
}

private struct VampSyncRedesignAddressRow: View {
    let value: String
    let label: String
    let isAvailable: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isAvailable ? VampSyncRedesignColors.live : VampSyncRedesignPalette(colorScheme: colorScheme).faint)
                .frame(width: 6, height: 6)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(isAvailable ? VampSyncRedesignPalette(colorScheme: colorScheme).secondary : VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

private struct VampSyncRedesignSectionLabel: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
    }
}

private struct VampSyncRedesignDevicesSection: View {
    let pairingLink: String?
    let trustedPeers: [TrustedPeer]
    let revokedPeers: [TrustedPeer]
    let isRefreshing: Bool
    let onRevoke: (TrustedPeer) -> Void
    let onPairAgain: (TrustedPeer) -> Void
    let onAddDevice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VampSyncRedesignDeviceGroup(
                title: "TRUSTED · \(trustedPeers.count)",
                peers: trustedPeers,
                isRefreshing: isRefreshing,
                isRevoked: false,
                actionTitle: "Revoke",
                onAction: onRevoke
            )

            if trustedPeers.isEmpty, !isRefreshing {
                VampSyncRedesignEmptyDevicesCard(pairingLink: pairingLink, onAddDevice: onAddDevice)
            }

            if !revokedPeers.isEmpty {
                VampSyncRedesignHairline()
                VampSyncRedesignDeviceGroup(
                    title: "BLOCKED · \(revokedPeers.count)",
                    peers: revokedPeers,
                    isRefreshing: false,
                    isRevoked: true,
                    actionTitle: "Allow again",
                    onAction: onPairAgain
                )
            }

            VampSyncRedesignAddDeviceRow(pairingLink: pairingLink, onAddDevice: onAddDevice)
        }
    }
}

private struct VampSyncRedesignDeviceGroup: View {
    let title: String
    let peers: [TrustedPeer]
    let isRefreshing: Bool
    let isRevoked: Bool
    let actionTitle: String
    let onAction: (TrustedPeer) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VampSyncRedesignSectionLabel(text: title)
                Spacer(minLength: 8)
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                }
            }

            if peers.isEmpty && !isRefreshing {
                Text(isRevoked ? "No blocked devices." : "No devices have been approved yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).tertiary)
            } else {
                ForEach(peers) { peer in
                    VampSyncRedesignDeviceRow(
                        peer: peer,
                        isRevoked: isRevoked,
                        actionTitle: actionTitle,
                        onAction: { onAction(peer) }
                    )
                }
            }
        }
    }
}

private struct VampSyncRedesignDeviceRow: View {
    let peer: TrustedPeer
    let isRevoked: Bool
    let actionTitle: String
    let onAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(VampSyncRedesignPalette(colorScheme: colorScheme).tile)
                Image(systemName: isRevoked ? "nosign" : deviceSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isRevoked ? VampSyncRedesignPalette(colorScheme: colorScheme).faint : VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isRevoked ? VampSyncRedesignPalette(colorScheme: colorScheme).secondary : VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                    .lineLimit(1)
                Text("\(vampSyncRedesignCompactFingerprint(peer.fingerprint)) · \(peerStatus)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 4)
            VampSyncRedesignButton(title: actionTitle, variant: .smallSecondary, maxWidth: false, action: onAction)
                .frame(width: isRevoked ? 82 : 54)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peer.displayName), \(peerStatus)")
    }

    private var deviceSymbol: String {
        peer.displayName.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
    }

    private var peerStatus: String {
        if isRevoked { return "blocked" }
        return peer.lastSeenAt == nil ? "idle" : "last seen"
    }
}

private struct VampSyncRedesignEmptyDevicesCard: View {
    let pairingLink: String?
    let onAddDevice: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncRedesignSurface(style: .subtle, cornerRadius: VampSyncRedesignDesign.cardRadius, padding: 12) {
            HStack(spacing: 12) {
                if let pairingLink {
                    HostBrowserPairingQRCode(
                        pairingURL: pairingLink,
                        accessibilityLabel: "QR code for Vamp Stream pairing",
                        size: 52
                    )
                } else {
                    VampSyncRedesignIconTile(systemImage: "qrcode", tint: VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
                        .frame(width: 52, height: 52)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("No devices trusted yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                    Text(pairingLink == nil
                        ? "Start the host to create a pairing code."
                        : "Open Vamp Stream on your iPhone or iPad and scan this code to start.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .onTapGesture(perform: onAddDevice)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Starts the host if it is stopped")
    }
}

private struct VampSyncRedesignAddDeviceRow: View {
    let pairingLink: String?
    let onAddDevice: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onAddDevice) {
            HStack(spacing: 10) {
                if let pairingLink {
                    HostBrowserPairingQRCode(
                        pairingURL: pairingLink,
                        accessibilityLabel: "QR code for adding a device",
                        size: 34
                    )
                } else {
                    VampSyncRedesignIconTile(systemImage: "qrcode", tint: VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
                        .frame(width: 34, height: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a device")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                    Text("Show the pairing code full size")
                        .font(.system(size: 10.5))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(VampSyncRedesignPalette(colorScheme: colorScheme).subtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(VampSyncRedesignPalette(colorScheme: colorScheme).border, style: StrokeStyle(lineWidth: VampSyncRedesignDesign.hairline, dash: [4, 3]))
        }
        .accessibilityLabel("Add a device")
    }
}

private struct VampSyncRedesignAccessSection: View {
    let statuses: [FriendlyPermissionStatus]
    let accessibilityRequired: Bool
    let accessibilitySystemManaged: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onOpenSettings: (PermissionKind) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VampSyncRedesignSectionLabel(text: "ACCESS")
                Spacer(minLength: 8)
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                }
                VampSyncRedesignIconButton(
                    systemImage: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                    accessibilityLabel: "Refresh permission status",
                    action: onRefresh
                )
            }

            VampSyncRedesignSurface(style: .subtle, cornerRadius: VampSyncRedesignDesign.cardRadius, padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    if corePermissionsGranted {
                        VampSyncRedesignAccessLine(
                            icon: "checkmark.circle.fill",
                            tint: VampSyncRedesignColors.live,
                            title: "Screen Recording & Accessibility granted",
                            detail: "Video and input are ready.",
                            actionTitle: nil,
                            action: nil
                        )
                    } else {
                        VampSyncRedesignPermissionDetailRow(
                            status: status(for: .screenRecording),
                            fallbackTitle: "Screen Recording",
                            fallbackDetail: "Needed so video can start.",
                            isSystemManaged: false,
                            onOpenSettings: { onOpenSettings(.screenRecording) }
                        )
                        if accessibilityRequired || status(for: .accessibility) != nil {
                            VampSyncRedesignPermissionDetailRow(
                                status: status(for: .accessibility),
                                fallbackTitle: "Accessibility",
                                fallbackDetail: "Needed for keyboard and pointer control.",
                                isSystemManaged: accessibilitySystemManaged,
                                onOpenSettings: { onOpenSettings(.accessibility) }
                            )
                        }
                    }

                    VampSyncRedesignHairline()

                    VampSyncRedesignAccessLine(
                        icon: "info.circle.fill",
                        tint: VampSyncRedesignPalette(colorScheme: colorScheme).muted,
                        title: "Local Network handled by macOS",
                        detail: "Private LAN discovery uses the system permission.",
                        actionTitle: nil,
                        action: nil
                    )
                }
            }
        }
    }

    private var corePermissionsGranted: Bool {
        guard let screen = status(for: .screenRecording), screen.isGranted else { return false }
        if !accessibilityRequired { return true }
        return status(for: .accessibility)?.isGranted == true
    }

    private func status(for kind: PermissionKind) -> FriendlyPermissionStatus? {
        statuses.first(where: { $0.kind == kind })
    }
}

private struct VampSyncRedesignPermissionDetailRow: View {
    let status: FriendlyPermissionStatus?
    let fallbackTitle: String
    let fallbackDetail: String
    let isSystemManaged: Bool
    let onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = VampSyncRedesignPalette(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status?.title ?? fallbackTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(palette.primary)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if !isSystemManaged {
                    VampSyncRedesignButton(title: actionTitle, variant: .smallSecondary, maxWidth: false, action: onOpenSettings)
                        .frame(width: 54)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    private var state: PermissionAuthorizationState {
        status?.authorizationState ?? .unknown
    }

    private var stateLabel: String {
        if isSystemManaged { return "Managed by macOS" }
        switch state {
        case .granted: return "Granted"
        case .denied: return "Needs access"
        case .notDetermined: return "Not set up"
        case .restricted: return "Unavailable"
        case .unknown: return "Checking"
        }
    }

    private var actionTitle: String {
        state == .denied || state == .notDetermined || state == .unknown ? "Grant" : "Open"
    }

    private var detail: String {
        if isSystemManaged { return "Handled by macOS." }
        if state == .granted { return status?.summary ?? "Granted." }
        return status?.helperText ?? fallbackDetail
    }

    private var icon: String {
        if isSystemManaged { return "info.circle.fill" }
        switch state {
        case .granted: return "checkmark.circle.fill"
        case .restricted: return "nosign"
        case .denied, .notDetermined, .unknown: return "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        if isSystemManaged { return VampSyncRedesignPalette(colorScheme: colorScheme).muted }
        switch state {
        case .granted: return VampSyncRedesignColors.live
        case .denied, .notDetermined, .unknown: return VampSyncRedesignColors.attention
        case .restricted: return VampSyncRedesignColors.error
        }
    }
}

private struct VampSyncRedesignAccessLine: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                VampSyncRedesignButton(title: actionTitle, variant: .smallSecondary, maxWidth: false, action: action)
            }
        }
    }
}

private struct VampSyncRedesignHeader: View {
    let statusTitle: String
    let statusColor: Color
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            VampSyncRedesignProductMark(size: 28)
            Text("Vamp Sync")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
            Spacer(minLength: 6)
            VampSyncRedesignStatusBadge(text: statusTitle, color: statusColor)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).faint)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Vamp Sync")
            .accessibilityLabel("Close Vamp Sync")
        }
        .padding(.horizontal, VampSyncRedesignDesign.contentInset)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

private struct VampSyncRedesignProductMark: View {
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color(red: 0.98, green: 0.98, blue: 0.98) : Color(red: 0.10, green: 0.10, blue: 0.095))
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color(red: 0.10, green: 0.10, blue: 0.095) : Color.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Vamp Sync")
    }
}

private struct VampSyncRedesignStatusBadge: View {
    let text: String
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Color.clear, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(VampSyncRedesignPalette(colorScheme: colorScheme).strongBorder, lineWidth: VampSyncRedesignDesign.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status \(text)")
    }
}

private struct VampSyncRedesignTabs: View {
    @Binding var selection: VampSyncRedesignSection
    let hasPendingApproval: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 20) {
                ForEach(VampSyncRedesignSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        VStack(spacing: 7) {
                            HStack(spacing: 5) {
                                Text(section.rawValue)
                                    .font(.system(size: 12, weight: selection == section ? .semibold : .medium))
                                    .foregroundStyle(selection == section
                                        ? VampSyncRedesignPalette(colorScheme: colorScheme).primary
                                        : VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                                if section == .devices, hasPendingApproval {
                                    Text("1")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.095))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(VampSyncRedesignColors.attention, in: Capsule())
                                }
                            }
                            Rectangle()
                                .fill(selection == section ? VampSyncRedesignPalette(colorScheme: colorScheme).primary : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VampSyncRedesignDesign.contentInset)
            VampSyncRedesignHairline()
        }
    }
}

private struct VampSyncRedesignSurface<Content: View>: View {
    enum Style { case subtle, raised, attention }

    let style: Style
    let cornerRadius: CGFloat
    let padding: CGFloat
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(style: Style, cornerRadius: CGFloat, padding: CGFloat, @ViewBuilder content: () -> Content) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let palette = VampSyncRedesignPalette(colorScheme: colorScheme)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor(palette), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor(palette), lineWidth: VampSyncRedesignDesign.hairline)
                    .allowsHitTesting(false)
            }
    }

    private func backgroundColor(_ palette: VampSyncRedesignPalette) -> Color {
        switch style {
        case .subtle: return palette.subtle
        case .raised: return palette.raised
        case .attention: return palette.attention
        }
    }

    private func borderColor(_ palette: VampSyncRedesignPalette) -> Color {
        style == .attention ? palette.strongBorder : palette.border
    }
}

private struct VampSyncRedesignBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncRedesignPalette(colorScheme: colorScheme).popover
            .ignoresSafeArea()
    }
}

private struct VampSyncRedesignFooter: View {
    let trustedCount: Int
    @Binding var appearance: VampSyncAppearance
    let onRefresh: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void
    let onAppearanceChange: (VampSyncAppearance) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Text(buildLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            VampSyncRedesignIconButton(systemImage: "arrow.clockwise", accessibilityLabel: "Refresh Vamp Sync", action: onRefresh)
            Menu {
                Text("Appearance")
                    .font(.system(size: 11, weight: .semibold))
                ForEach(VampSyncAppearance.allCases) { option in
                    Button {
                        onAppearanceChange(option)
                    } label: {
                        Label(option.title, systemImage: option.systemImage)
                    }
                }
                Divider()
                Button("Restart host", action: onRestart)
                Button("Quit Vamp Sync", action: onQuit)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Vamp Sync settings")
            .accessibilityLabel("Vamp Sync settings")
        }
        .padding(.horizontal, VampSyncRedesignDesign.contentInset)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            VampSyncRedesignHairline()
        }
    }

    private var buildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.3.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "v\(version) · build \(build) · \(trustedCount) trusted"
    }
}

private struct VampSyncRedesignIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                .frame(width: 24, height: 24)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(VampSyncRedesignPalette(colorScheme: colorScheme).border, lineWidth: VampSyncRedesignDesign.hairline)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct VampSyncRedesignOnboarding: View {
    @Binding var step: Int
    let permissions: [FriendlyPermissionStatus]
    let accessibilityRequired: Bool
    let accessibilitySystemManaged: Bool
    let pairingLink: String?
    let pairingAddress: String?
    let fingerprint: String
    let onClose: () -> Void
    let onStart: () -> Void
    let onOpenPermissionSettings: (PermissionKind) -> Void
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image("VampFavicon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .accessibilityLabel("Vamp")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vamp Sync")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                    Text("STEP \(step) OF 3")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(0.95)
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                }
                Spacer(minLength: 6)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).faint)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Vamp Sync")
            }

            switch step {
            case 2:
                VampSyncRedesignPermissionsOnboardingStep(
                    permissions: permissions,
                    accessibilityRequired: accessibilityRequired,
                    accessibilitySystemManaged: accessibilitySystemManaged,
                    onOpenSettings: onOpenPermissionSettings,
                    onSkip: onFinish,
                    onContinue: { step = 3 }
                )
            case 3:
                VampSyncRedesignPairOnboardingStep(
                    pairingLink: pairingLink,
                    pairingAddress: pairingAddress,
                    fingerprint: fingerprint,
                    onStart: onStart,
                    onFinish: onFinish
                )
            default:
                VampSyncRedesignWhyOnboardingStep(onContinue: { step = 2 })
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }
}

private struct VampSyncRedesignWhyOnboardingStep: View {
    let onContinue: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Mac's screen, on your iPad — and nowhere else.")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.28)
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Sync runs only while you say so, on your own network. No account, no relay server, nothing leaves the room.")
                .font(.system(size: 12))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).tertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                VampSyncRedesignOnboardingBullet(text: "Every new device needs your approval")
                VampSyncRedesignOnboardingBullet(text: "You compare a code before it connects")
                VampSyncRedesignOnboardingBullet(text: "Stop everything from the menu bar")
            }

            Spacer(minLength: 10)
            VampSyncRedesignButton(title: "Set up access", variant: .primary, action: onContinue)
        }
    }
}

private struct VampSyncRedesignOnboardingBullet: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VampSyncRedesignPermissionsOnboardingStep: View {
    let permissions: [FriendlyPermissionStatus]
    let accessibilityRequired: Bool
    let accessibilitySystemManaged: Bool
    let onOpenSettings: (PermissionKind) -> Void
    let onSkip: () -> Void
    let onContinue: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VampSyncRedesignOnboardingTitle(
                title: "Two permissions",
                detail: "macOS grants these, not us. Sync reads the state and never asks twice."
            )

            VStack(alignment: .leading, spacing: 8) {
                VampSyncRedesignOnboardingPermissionRow(
                    title: "Screen Recording",
                    detail: "Needed so video can start.",
                    status: status(for: .screenRecording),
                    isSystemManaged: false,
                    onGrant: { onOpenSettings(.screenRecording) }
                )
                if accessibilityRequired || status(for: .accessibility) != nil {
                    VampSyncRedesignOnboardingPermissionRow(
                        title: "Accessibility",
                        detail: "Needed for keyboard and pointer control.",
                        status: status(for: .accessibility),
                        isSystemManaged: accessibilitySystemManaged,
                        onGrant: { onOpenSettings(.accessibility) }
                    )
                }
            }

            Spacer(minLength: 8)
            HStack(spacing: 8) {
                VampSyncRedesignButton(title: "Skip for now", variant: .secondary, action: onSkip)
                VampSyncRedesignButton(title: "Continue", variant: .primary, action: onContinue)
            }
        }
    }

    private func status(for kind: PermissionKind) -> FriendlyPermissionStatus? {
        permissions.first(where: { $0.kind == kind })
    }
}

private struct VampSyncRedesignOnboardingTitle: View {
    let title: String
    let detail: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.28)
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).tertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VampSyncRedesignOnboardingPermissionRow: View {
    let title: String
    let detail: String
    let status: FriendlyPermissionStatus?
    let isSystemManaged: Bool
    let onGrant: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = VampSyncRedesignPalette(colorScheme: colorScheme)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.primary)
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 5)
            if canGrant {
                VampSyncRedesignButton(title: "Grant", variant: .primary, maxWidth: false, action: onGrant)
                    .frame(width: 52)
            }
        }
        .padding(12)
        .background(isAttention ? palette.attention : palette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isAttention ? palette.strongBorder : palette.border, lineWidth: VampSyncRedesignDesign.hairline)
        }
    }

    private var authorizationState: PermissionAuthorizationState {
        status?.authorizationState ?? .unknown
    }

    private var isAttention: Bool {
        !isSystemManaged && authorizationState != .granted
    }

    private var canGrant: Bool {
        !isSystemManaged && authorizationState != .granted && authorizationState != .restricted
    }

    private var statusText: String {
        if isSystemManaged { return "Handled by macOS." }
        switch authorizationState {
        case .granted: return "Granted — ready to start"
        case .denied: return detail
        case .notDetermined: return "Not set up yet. \(detail)"
        case .restricted: return "Unavailable in this build."
        case .unknown: return "Checking macOS privacy settings…"
        }
    }

    private var icon: String {
        if isSystemManaged { return "checkmark.circle.fill" }
        return authorizationState == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var tint: Color {
        if isSystemManaged || authorizationState == .granted { return VampSyncRedesignColors.live }
        if authorizationState == .restricted { return VampSyncRedesignColors.error }
        return VampSyncRedesignColors.attention
    }
}

private struct VampSyncRedesignPairOnboardingStep: View {
    let pairingLink: String?
    let pairingAddress: String?
    let fingerprint: String
    let onStart: () -> Void
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VampSyncRedesignOnboardingTitle(
                title: "Pair your first device",
                detail: pairingLink == nil
                    ? "Start Sync to publish a private pairing code."
                    : "Open Vamp Stream on your iPhone or iPad and point it at this code."
            )

            HStack(alignment: .top, spacing: 14) {
                if let pairingLink {
                    HostBrowserPairingQRCode(
                        pairingURL: pairingLink,
                        accessibilityLabel: "QR code for Vamp Stream pairing",
                        size: 132
                    )
                } else {
                    VampSyncRedesignIconTile(systemImage: "qrcode", tint: VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
                        .frame(width: 132, height: 132)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("THIS MAC")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                    Text(pairingAddress ?? "Host is not advertising")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("FINGERPRINT")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                        .padding(.top, 2)
                    Text(vampSyncRedesignGroupedFingerprint(fingerprint).joined(separator: " "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
            }

            if pairingLink == nil {
                VampSyncRedesignButton(title: "Start host", systemImage: "play.fill", variant: .primary, action: onStart)
            }

            Spacer(minLength: 8)
            VampSyncRedesignButton(title: "I'll do this later", variant: .secondary, action: onFinish)
        }
    }
}

private struct VampSyncRedesignStatusStage: View {
    let state: VampSyncRedesignState
    let connectedClientName: String?
    let framesPerSecond: Int?
    let linkLabel: String
    let onStart: () -> Void
    let onStop: () -> Void
    let onPairDevice: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let copiedText: String?
    let onCopyFingerprint: (String) -> Void
    let onOpenSettings: (PermissionKind) -> Void
    let onRecheck: () -> Void
    let onRestart: () -> Void
    let onCopyLog: () -> Void

    @ViewBuilder
    var body: some View {
        switch state {
        case .stopped:
            VampSyncRedesignStoppedStage(onStart: onStart)
        case .starting:
            VampSyncRedesignStartingStage()
        case .ready:
            VampSyncRedesignReadyStage(onStop: onStop, onPairDevice: onPairDevice)
        case .live:
            VampSyncRedesignLiveStage(
                clientName: connectedClientName ?? "A trusted device",
                framesPerSecond: framesPerSecond,
                linkLabel: linkLabel,
                onStop: onStop
            )
        case let .pending(displayName, fingerprint):
            VampSyncRedesignApprovalStage(
                displayName: displayName,
                fingerprint: fingerprint,
                onApprove: onApprove,
                onReject: onReject,
                isCopied: copiedText == fingerprint,
                onCopyFingerprint: { onCopyFingerprint(fingerprint) }
            )
        case let .permissionMissing(kind, title):
            VampSyncRedesignPermissionStage(
                kind: kind,
                title: title,
                onOpenSettings: { onOpenSettings(kind) },
                onRecheck: onRecheck
            )
        case let .error(message):
            VampSyncRedesignErrorStage(message: message, onRestart: onRestart, onCopyLog: onCopyLog)
        }
    }
}

private struct VampSyncRedesignStoppedStage: View {
    let onStart: () -> Void

    var body: some View {
        VampSyncRedesignStageSurface(style: .raised) {
            VStack(alignment: .leading, spacing: 14) {
                VampSyncRedesignStageHeader(
                    indicator: .stopped,
                    headline: "Host is off",
                    detail: "No device can reach this Mac right now"
                )
                VampSyncRedesignButton(title: "Start host", systemImage: "play.fill", variant: .primary, action: onStart)
            }
        }
    }
}

private struct VampSyncRedesignStartingStage: View {
    var body: some View {
        VampSyncRedesignStageSurface(style: .raised) {
            VampSyncRedesignStageHeader(
                indicator: .starting,
                headline: "Starting up",
                detail: "Publishing signed discovery…"
            )
        }
    }
}

private struct VampSyncRedesignReadyStage: View {
    let onStop: () -> Void
    let onPairDevice: () -> Void

    var body: some View {
        VampSyncRedesignStageSurface(style: .raised) {
            VStack(alignment: .leading, spacing: 14) {
                VampSyncRedesignStageHeader(
                    indicator: .ready,
                    headline: "Listening for your devices",
                    detail: "Nothing connected · devices are trusted below"
                )
                HStack(spacing: 8) {
                    VampSyncRedesignButton(title: "Stop host", systemImage: "stop.fill", variant: .secondary, action: onStop)
                    VampSyncRedesignButton(title: "Pair a device", systemImage: "qrcode", variant: .secondary, action: onPairDevice)
                }
            }
        }
    }
}

private struct VampSyncRedesignLiveStage: View {
    let clientName: String
    let framesPerSecond: Int?
    let linkLabel: String
    let onStop: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncRedesignStageSurface(style: .raised) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VampSyncRedesignDeviceTile(systemImage: deviceSymbol)
                    VampSyncRedesignStageCopy(
                        headline: "\(clientName) is streaming",
                        detail: "Full display · connected now"
                    )
                    Spacer(minLength: 6)
                    VampSyncRedesignButton(title: "Stop", systemImage: "stop.fill", variant: .smallSecondary, action: onStop)
                }

                VampSyncRedesignMetricStrip(
                    framesPerSecond: framesPerSecond,
                    linkLabel: linkLabel
                )
            }
        }
    }

    private var deviceSymbol: String {
        clientName.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
    }
}

private struct VampSyncRedesignApprovalStage: View {
    let displayName: String
    let fingerprint: String
    let onApprove: () -> Void
    let onReject: () -> Void
    let isCopied: Bool
    let onCopyFingerprint: () -> Void

    var body: some View {
        VampSyncRedesignStageSurface(style: .attention) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VampSyncRedesignColors.attention)
                    Text("Approve \(displayName)?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                }

                Text("Open Vamp Stream on that device and check the code shown there matches this one, character for character.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VampSyncRedesignFingerprintChips(
                    fingerprint: fingerprint,
                    isCopied: isCopied,
                    onCopy: onCopyFingerprint
                )

                HStack(spacing: 8) {
                    VampSyncRedesignButton(title: "Codes match — approve", variant: .primary, action: onApprove)
                        .keyboardShortcut(.defaultAction)
                    VampSyncRedesignButton(title: "Reject", variant: .secondary, maxWidth: false, action: onReject)
                        .frame(width: 58)
                }
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
}

private struct VampSyncRedesignPermissionStage: View {
    let kind: PermissionKind
    let title: String
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncRedesignStageSurface(style: .attention) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    VampSyncRedesignIconTile(systemImage: "menubar.rectangle", tint: VampSyncRedesignColors.attention)
                    VampSyncRedesignStageCopy(
                        headline: "macOS won't let us see the screen",
                        detail: title == "Screen Recording"
                            ? "Screen Recording is off, so video can't start. Input still works."
                            : "Enable \(title) before trusted devices can use this host."
                    )
                }

                HStack(spacing: 8) {
                    VampSyncRedesignButton(title: "Open Privacy settings", variant: .primary, action: onOpenSettings)
                    VampSyncRedesignButton(title: "Re-check", variant: .secondary, maxWidth: false, action: onRecheck)
                        .frame(width: 70)
                }
            }
        }
    }
}

private struct VampSyncRedesignErrorStage: View {
    let message: String
    let onRestart: () -> Void
    let onCopyLog: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VampSyncRedesignStageSurface(style: .error) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    VampSyncRedesignIconTile(systemImage: "exclamationmark.triangle.fill", tint: VampSyncRedesignColors.error, fill: true)
                    VampSyncRedesignStageCopy(
                        headline: errorHeadline,
                        detail: message
                    )
                }

                HStack(spacing: 8) {
                    VampSyncRedesignButton(title: "Restart host", systemImage: "arrow.clockwise", variant: .primary, action: onRestart)
                    VampSyncRedesignButton(title: "Copy log", variant: .secondary, maxWidth: false, action: onCopyLog)
                        .frame(width: 70)
                }
            }
        }
    }

    private var errorHeadline: String {
        message.localizedCaseInsensitiveContains("already in use") ? "Port 9471 is already in use" : "Vamp Sync needs attention"
    }
}

private enum VampSyncRedesignStageIndicator {
    case stopped
    case starting
    case ready
}

private struct VampSyncRedesignStageHeader: View {
    let indicator: VampSyncRedesignStageIndicator
    let headline: String
    let detail: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            switch indicator {
            case .stopped:
                VampSyncRedesignPulseIndicator(dotColor: VampSyncRedesignColors.off, mode: .static)
            case .starting:
                VampSyncRedesignStartingIndicator()
            case .ready:
                VampSyncRedesignPulseIndicator(dotColor: VampSyncRedesignColors.live, mode: .pulsing)
            }
            VampSyncRedesignStageCopy(headline: headline, detail: detail)
            Spacer(minLength: 0)
        }
    }
}

private struct VampSyncRedesignStageCopy: View {
    let headline: String
    let detail: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VampSyncRedesignPulseIndicator: View {
    enum Mode { case `static`, pulsing }

    let dotColor: Color
    let mode: Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(VampSyncRedesignPalette(colorScheme: colorScheme).border, lineWidth: VampSyncRedesignDesign.hairline)
            if mode == .pulsing, !reduceMotion {
                Circle()
                    .fill(dotColor.opacity(0.28))
                    .scaleEffect(isPulsing ? 1.9 : 1)
                    .opacity(isPulsing ? 0 : 0.35)
                    .animation(.easeOut(duration: 2.6).repeatForever(autoreverses: false), value: isPulsing)
            }
            Circle()
                .fill(dotColor)
                .frame(width: mode == .static ? 11 : 12, height: mode == .static ? 11 : 12)
        }
        .frame(width: 38, height: 38)
        .onAppear {
            if mode == .pulsing, !reduceMotion { isPulsing = true }
        }
    }
}

private struct VampSyncRedesignStartingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(VampSyncRedesignPalette(colorScheme: colorScheme).border, lineWidth: VampSyncRedesignDesign.hairline)
            Circle()
                .trim(from: 0.04, to: 0.36)
                .stroke(VampSyncRedesignPalette(colorScheme: colorScheme).secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(rotation))
            Circle()
                .fill(VampSyncRedesignPalette(colorScheme: colorScheme).secondary.opacity(0.45))
                .frame(width: 10, height: 10)
        }
        .frame(width: 38, height: 38)
        .onAppear {
            if !reduceMotion {
                rotation = 360
            }
        }
        .animation(
            reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false),
            value: rotation
        )
    }
}

private struct VampSyncRedesignDeviceTile: View {
    let systemImage: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VampSyncRedesignPalette(colorScheme: colorScheme).tile)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(VampSyncRedesignPalette(colorScheme: colorScheme).border, lineWidth: VampSyncRedesignDesign.hairline)
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).secondary)
        }
        .frame(width: 38, height: 38)
    }
}

private struct VampSyncRedesignIconTile: View {
    let systemImage: String
    let tint: Color
    var fill = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fill ? tint.opacity(0.14) : VampSyncRedesignPalette(colorScheme: colorScheme).tile)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(fill ? tint.opacity(0.32) : VampSyncRedesignPalette(colorScheme: colorScheme).border, lineWidth: VampSyncRedesignDesign.hairline)
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 38, height: 38)
    }
}

private struct VampSyncRedesignMetricStrip: View {
    let framesPerSecond: Int?
    let linkLabel: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            VampSyncRedesignMetric(label: "FRAME", value: framesPerSecond.map { "\($0) fps" } ?? "—")
            VampSyncRedesignMetric(label: "LATENCY", value: "—")
            VampSyncRedesignMetric(label: "LINK", value: linkLabel)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            VampSyncRedesignHairline()
        }
    }
}

private struct VampSyncRedesignMetric: View {
    let label: String
    let value: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VampSyncRedesignStageSurface<Content: View>: View {
    enum Style { case raised, attention, error }

    let style: Style
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(style: Style, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    var body: some View {
        let palette = VampSyncRedesignPalette(colorScheme: colorScheme)
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor(palette), in: RoundedRectangle(cornerRadius: VampSyncRedesignDesign.stageRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VampSyncRedesignDesign.stageRadius, style: .continuous)
                    .strokeBorder(borderColor(palette), lineWidth: VampSyncRedesignDesign.hairline)
                    .allowsHitTesting(false)
            }
    }

    private func backgroundColor(_ palette: VampSyncRedesignPalette) -> Color {
        switch style {
        case .raised: return palette.raised
        case .attention: return palette.attention
        case .error: return palette.errorSurface
        }
    }

    private func borderColor(_ palette: VampSyncRedesignPalette) -> Color {
        switch style {
        case .raised: return palette.border
        case .attention: return palette.strongBorder
        case .error: return palette.errorBorder
        }
    }
}

private struct VampSyncRedesignFingerprintChips: View {
    let fingerprint: String
    let isCopied: Bool
    let onCopy: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let groups = vampSyncRedesignGroupedFingerprint(fingerprint)
        let midpoint = max(1, (groups.count + 1) / 2)
        HStack(alignment: .top, spacing: 8) {
            VampSyncRedesignFingerprintChip(
                text: groups.prefix(midpoint).joined(separator: " "),
                isCopied: isCopied,
                action: onCopy
            )
            VampSyncRedesignFingerprintChip(
                text: groups.dropFirst(midpoint).joined(separator: " "),
                isCopied: isCopied,
                action: onCopy
            )
        }
    }
}

private struct VampSyncRedesignFingerprintChip: View {
    let text: String
    let isCopied: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 6) {
                Text(text.isEmpty ? "—" : text)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.45)
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VampSyncRedesignPalette(colorScheme: colorScheme).muted)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.black.opacity(colorScheme == .dark ? 0.38 : 0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCopied ? "Fingerprint copied" : "Copy fingerprint")
        .accessibilityHint("Copies the full device fingerprint")
    }
}

private struct VampSyncRedesignButton: View {
    enum Variant { case primary, secondary, smallSecondary }

    let title: String
    var systemImage: String?
    let variant: Variant
    var maxWidth = true
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        systemImage: String? = nil,
        variant: Variant,
        maxWidth: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.variant = variant
        self.maxWidth = maxWidth
        self.action = action
    }

    var body: some View {
        let palette = VampSyncRedesignPalette(colorScheme: colorScheme)
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: variant == .smallSecondary ? 9 : 10, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .font(.system(size: variant == .smallSecondary ? 11 : 12, weight: variant == .primary ? .semibold : .medium))
            .foregroundStyle(foregroundColor(palette))
            .frame(maxWidth: maxWidth ? .infinity : nil, minHeight: variant == .smallSecondary ? 26 : 30)
            .padding(.horizontal, variant == .smallSecondary ? 12 : 10)
            .background(backgroundColor(palette), in: RoundedRectangle(cornerRadius: variant == .smallSecondary ? 7 : VampSyncRedesignDesign.buttonRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: variant == .smallSecondary ? 7 : VampSyncRedesignDesign.buttonRadius, style: .continuous)
                    .strokeBorder(borderColor(palette), lineWidth: VampSyncRedesignDesign.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func foregroundColor(_ palette: VampSyncRedesignPalette) -> Color {
        variant == .primary ? palette.primaryButtonText : palette.primary
    }

    private func backgroundColor(_ palette: VampSyncRedesignPalette) -> Color {
        switch variant {
        case .primary: return palette.primaryButton
        case .secondary, .smallSecondary: return palette.raised
        }
    }

    private func borderColor(_ palette: VampSyncRedesignPalette) -> Color {
        variant == .primary ? .clear : palette.strongBorder
    }
}

private struct VampSyncRedesignHairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(VampSyncRedesignPalette(colorScheme: colorScheme).divider)
            .frame(height: VampSyncRedesignDesign.hairline)
    }
}

private func vampSyncRedesignGroupedFingerprint(_ fingerprint: String) -> [String] {
    let value = fingerprint.lowercased().filter(\.isHexDigit)
    guard !value.isEmpty else { return [] }
    return stride(from: 0, to: value.count, by: 8).map { offset in
        let start = value.index(value.startIndex, offsetBy: offset)
        let end = value.index(start, offsetBy: min(8, value.count - offset))
        let chunk = String(value[start..<end])
        return stride(from: 0, to: chunk.count, by: 4).map { chunkOffset in
            let chunkStart = chunk.index(chunk.startIndex, offsetBy: chunkOffset)
            let chunkEnd = chunk.index(chunkStart, offsetBy: min(4, chunk.count - chunkOffset))
            return String(chunk[chunkStart..<chunkEnd])
        }.joined(separator: " ")
    }
}

private func vampSyncRedesignCompactFingerprint(_ fingerprint: String) -> String {
    let groups = vampSyncRedesignGroupedFingerprint(fingerprint)
    if groups.isEmpty { return "—" }
    return groups.prefix(2).joined(separator: " ")
}

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
