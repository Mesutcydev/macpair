#if os(macOS)
import AppKit
import SwiftUI

/// Focused dashboard for the separate Vamp Terminal Host product.
///
/// This deliberately does not expose screen capture, remote input, file
/// transfer, widgets, or full-host settings. The underlying environment still
/// reuses the signed Vamp transport and pairing stack, while the product mode
/// rejects non-terminal clients and never starts a capture pipeline.
struct VampTerminalHostShellView: View {
    @ObservedObject var environment: HostAppEnvironment

    @State private var tailscaleInfo: TailscaleConnectionInfo?
    @State private var copiedValue: String?
    @State private var showingGuide = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                browserCard
                commandCard
                safetyCard
            }
            .padding(22)
            .frame(minWidth: 620, maxWidth: 760, alignment: .topLeading)
        }
        .background(VampTerminalHostBackdrop())
        .task {
            await environment.startRuntimeIfNeeded()
            let info = await Task.detached(priority: .utility) {
                getTailscaleConnectionInfo()
            }.value
            tailscaleInfo = info
            await environment.discoveryAdvertiserViewModel.updateTailscaleIdentity(
                hostname: info?.dnsName,
                ip: info?.ipAddress
            )
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingGuide = true
                } label: {
                    Label("How it works", systemImage: "questionmark.circle")
                }
                Button {
                    Task { await environment.startRuntimeIfNeeded() }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showingGuide) {
            VampTerminalHostGuideView()
                .frame(width: 500, height: 430)
        }
        .alert(
            environment.pendingTrustPrompt.map { "Allow \($0.displayName)?" } ?? "Allow Vamp Terminal?",
            isPresented: Binding(
                get: { environment.pendingTrustPrompt != nil },
                set: { isPresented in
                    if !isPresented, environment.pendingTrustPrompt != nil {
                        environment.resolveTrustPrompt(approved: false)
                    }
                }
            ),
            presenting: environment.pendingTrustPrompt
        ) { _ in
            Button("Reject", role: .destructive) {
                environment.resolveTrustPrompt(approved: false)
            }
            Button("Approve") {
                environment.resolveTrustPrompt(approved: true)
            }
        } message: { prompt in
            Text("Approve the signed terminal pairing for \(prompt.displayName). Fingerprint: \(prompt.fingerprint)")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 25, weight: .medium))
                .frame(width: 56, height: 56)
                .vampTerminalHostGlass(.icon, cornerRadius: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text("Vamp Terminal Host")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("A focused Mac host for terminal tabs, Safari control, and signed pairing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("TERMINAL ONLY  ·  TAILSCALE READY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            VampTerminalHostStatusPill(
                text: statusTitle,
                color: statusColor,
                systemImage: statusIcon
            )
        }
        .accessibilityElement(children: .combine)
    }

    private var statusCard: some View {
        VampTerminalHostSection(title: "Connection") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(environment.hostIdentity.displayName)
                        .font(.headline)
                    Text("Advertised as a Vamp Terminal-only host")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(environment.discoveryAdvertiserViewModel.endpointText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 7) {
                    Text("Terminal Mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label("Always on", systemImage: "checkmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Text("Up to 8 independent PTYs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 10) {
                if let tailscaleInfo {
                    VampTerminalHostAddress(
                        title: "Tailscale",
                        value: tailscaleInfo.connectAddress,
                        systemImage: "network",
                        onCopy: { copy(tailscaleInfo.connectAddress) }
                    )
                } else {
                    Label("Tailscale not detected", systemImage: "network.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    Task {
                        await environment.stopRuntime()
                        await environment.startRuntimeIfNeeded()
                    }
                } label: {
                    Label("Restart host", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var browserCard: some View {
        VampTerminalHostSection(title: "Safari control") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "safari")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Use Safari without the iOS app")
                        .font(.headline)
                    Text("The Mac keeps the service private to loopback and Tailscale. Use the HTTPS link through Tailscale Serve, or the direct 100.x address as a fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VampTerminalHostStatusPill(
                    text: environment.browserControlStatus.running ? "READY" : "OFFLINE",
                    color: environment.browserControlStatus.running ? .green : .secondary,
                    systemImage: "circle.fill"
                )
            }

            if environment.browserControlStatus.running {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pairing code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(environment.browserControlStatus.pairingCode.isEmpty ? "Starting…" : environment.browserControlStatus.pairingCode)
                            .font(.system(size: 23, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button("Rotate code") {
                        environment.rotateBrowserPairingCode()
                    }
                    .buttonStyle(.bordered)
                    if let port = environment.browserControlStatus.port {
                        Text("Mac local · 127.0.0.1:\(port)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if let tailscaleInfo {
                    if let browserURL = tailscaleInfo.browserControlURL {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Serve HTTPS · recommended")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(browserURL)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Button(copiedValue == browserURL ? "Copied" : "Copy link") {
                                copy(browserURL)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    if let port = environment.browserControlStatus.port {
                        let directURL = "http://\(tailscaleInfo.ipAddress):\(port)"
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Direct Tailscale fallback")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(directURL)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Button(copiedValue == directURL ? "Copied" : "Copy link") {
                                copy(directURL)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else {
                    Text("On a phone or tablet, do not open 127.0.0.1 — that address points to the phone itself. Enable Tailscale to receive a private HTTPS link or direct 100.x fallback.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let serveCommand = environment.browserControlStatus.serveCommand {
                    HStack(spacing: 10) {
                        Text(serveCommand)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button(copiedValue == serveCommand ? "Copied" : "Copy") {
                            copy(serveCommand)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } else if let error = environment.browserControlStatus.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Starting the host will create the private browser endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commandCard: some View {
        VampTerminalHostSection(title: "CLI and agent handoff") {
            Text("Use the Vamp CLI to prepare sessions before opening the app. tmux and screen keep an agent alive while the phone changes network or the app is backgrounded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(VampTerminalHostCommands.all) { command in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(command.command)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text(command.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(copiedValue == command.command ? "Copied" : "Copy") {
                            copy(command.command)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 9)
                    if command.id != VampTerminalHostCommands.all.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var safetyCard: some View {
        VampTerminalHostSection(title: "Safety boundary") {
            Label("Only authenticated Vamp Terminal clients are accepted.", systemImage: "checkmark.shield")
            Label("The host never starts ScreenCaptureKit or remote input.", systemImage: "rectangle.slash")
            Label("Terminal Mode is always enabled; disabling the runtime closes every PTY.", systemImage: "power")
            Label("Safari access stays private to loopback and Tailscale; no public port forwarding is used.", systemImage: "lock")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusTitle: String {
        switch environment.sessionCoordinator.phase {
        case .streaming: return "CONNECTED"
        case .advertising, .awaitingClient: return "READY"
        case .idle: return "STOPPED"
        case .error: return "ERROR"
        default: return "CONNECTING"
        }
    }

    private var statusIcon: String {
        switch statusTitle {
        case "CONNECTED": return "checkmark.circle.fill"
        case "ERROR": return "exclamationmark.triangle.fill"
        case "STOPPED": return "pause.circle.fill"
        default: return "circle.fill"
        }
    }

    private var statusColor: Color {
        switch statusTitle {
        case "CONNECTED", "READY": return .green
        case "ERROR": return .orange
        default: return .secondary
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedValue == value { copiedValue = nil }
        }
    }
}

private struct VampTerminalHostCommands: Identifiable, Equatable {
    let id: String
    let command: String
    let detail: String

    static let all = [
        Self(id: "list", command: "vamp terminal list", detail: "List tmux and screen sessions."),
        Self(id: "start", command: "vamp terminal start --session work", detail: "Create or resume a persistent shell."),
        Self(id: "attach", command: "vamp terminal attach work", detail: "Hand an existing shell to a new tab."),
        Self(id: "agent", command: "vamp terminal agent codex --session codex", detail: "Start a tmux-backed coding agent."),
        Self(id: "browser", command: "vamp browser serve", detail: "Expose Safari control through Tailscale Serve.")
    ]
}

private struct VampTerminalHostSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .vampTerminalHostGlass(.card, cornerRadius: 18)
    }
}

private struct VampTerminalHostAddress: View {
    let title: String
    let value: String
    let systemImage: String
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy address")
        }
    }
}

private struct VampTerminalHostStatusPill: View {
    let text: String
    let color: Color
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(0.10), in: Capsule())
            .overlay { Capsule().stroke(color.opacity(0.26), lineWidth: 0.5) }
    }
}

private struct VampTerminalHostBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.white.opacity(0.04), .clear, Color.black.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private enum VampTerminalHostGlassRole {
    case card
    case icon

    var radius: CGFloat {
        switch self {
        case .card: return 18
        case .icon: return 16
        }
    }
}

private struct VampTerminalHostGlassModifier: ViewModifier {
    let role: VampTerminalHostGlassRole
    let cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? role.radius
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 0.6)
            }
    }
}

private extension View {
    func vampTerminalHostGlass(
        _ role: VampTerminalHostGlassRole,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(VampTerminalHostGlassModifier(role: role, cornerRadius: cornerRadius))
    }
}

private struct VampTerminalHostGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How Vamp Terminal Host works")
                .font(.title2.weight(.semibold))
            Text("Vamp Terminal Host is the small Mac companion for people who only need their command line. It keeps the same signed pairing and WebRTC data-channel security as Vamp Host, but it has no screen-sharing or remote-input surface.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("Enable Tailscale on the Mac and phone.", systemImage: "1.circle")
                Label("Approve the signed Vamp Terminal pairing request.", systemImage: "2.circle")
                Label("Open up to eight independent terminal tabs.", systemImage: "3.circle")
                Label("Use tmux or screen when a shell or agent must survive a handoff.", systemImage: "4.circle")
            }
            Spacer()
        }
        .padding(26)
    }
}
#endif
