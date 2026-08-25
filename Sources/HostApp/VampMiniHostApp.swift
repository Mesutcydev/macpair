#if VAMP_MINI_HOST && os(macOS)
import AppKit
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

    @StateObject private var hostEnvironment = environment
    @NSApplicationDelegateAdaptor(VampMiniHostAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            VampMiniHostPopover(environment: hostEnvironment)
        } label: {
            VampMiniHostTrayLabel(environment: hostEnvironment)
                .contextMenu {
                    Button("Quit Vamp Mini Host") {
                        NSApp.terminate(nil)
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class VampMiniHostAppDelegate: NSObject, NSApplicationDelegate {
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
}

private struct VampMiniHostTrayLabel: View {
    @ObservedObject var environment: HostAppEnvironment

    var body: some View {
        VampMiniHostAppIcon(size: 18)
            .accessibilityLabel("Vamp Mini Host")
    }
}

private struct VampMiniHostPopover: View {
    @ObservedObject var environment: HostAppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var trustedPeers: [TrustedPeer] = []
    @State private var isRefreshingPeers = false
    @State private var tailscaleInfo: TailscaleConnectionInfo?
    @State private var tailscaleInstalled = false
    @State private var copiedFingerprint = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                statusCard

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
                controls
                footer
            }
            .padding(14)
        }
        .frame(width: 370, height: 650)
        .background(VampMiniHostBackdrop())
        .task {
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
            VampMiniHostAppIcon(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vamp Mini Host")
                    .font(.headline)
                Text("Pairing-first Mac host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VampMiniStatusBadge(text: statusTitle, color: statusColor)
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
        .padding(12)
        .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(statusColor.opacity(0.24), lineWidth: 1)
        }
    }

    private var pairingCard: some View {
        VampMiniHostSection(title: "Pairing", systemImage: "person.badge.key.fill") {
            if let pairingLink, let pairingAddress {
                HStack(alignment: .top, spacing: 10) {
                    HostBrowserPairingQRCode(
                        pairingURL: pairingLink,
                        accessibilityLabel: "QR code for Vamp Stream pairing"
                    )
                    .frame(width: 118, height: 118)

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
            Text("Mini Host does not capture the display or inject keyboard and pointer events, so those permissions are not required.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VampMiniPermissionRow(
                title: "Screen Recording",
                summary: "Not required for this app",
                systemImage: "rectangle.inset.filled.and.person.filled"
            ) {
                openPrivacySettings("Privacy_ScreenCapture")
            }
            VampMiniPermissionRow(
                title: "Accessibility",
                summary: "Not required for this app",
                systemImage: "accessibility"
            ) {
                openPrivacySettings("Privacy_Accessibility")
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
        default: return "Starting secure host"
        }
    }

    private var statusColor: Color {
        switch statusTitle {
        case "LIVE": return .blue
        case "READY": return .green
        case "ERROR": return .orange
        default: return .secondary
        }
    }

    private func refreshPeers() async {
        isRefreshingPeers = true
        defer { isRefreshingPeers = false }
        trustedPeers = (try? await environment.trustedPeerStore.trustedPeers()) ?? []
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

    @State private var fingerprintConfirmation = ""

    private var isConfirmed: Bool {
        fingerprintConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == prompt.fingerprint.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("New device wants to pair", systemImage: "person.badge.key.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(prompt.displayName)
                .font(.headline)
            Text("Compare the complete fingerprint out of band. Type it below to unlock Approve.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(prompt.fingerprint)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type fingerprint to confirm", text: $fingerprintConfirmation)
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
                .textContentType(.none)
                .autocorrectionDisabled()
                .accessibilityLabel("Fingerprint confirmation")
            HStack {
                Button("Reject", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isConfirmed)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.orange.opacity(0.35), lineWidth: 1)
        }
        .onChange(of: prompt.id) { _ in
            fingerprintConfirmation = ""
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
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
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
    }
}

private struct VampMiniHostAppIcon: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityLabel("Vamp Mini Host")
    }
}

private struct VampMiniHostBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.blue.opacity(0.08), Color.clear, Color.purple.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
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
