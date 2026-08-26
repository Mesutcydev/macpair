import SwiftUI

/// The first screen in Vamp Stream. The user chooses an experience first, then a Mac.
/// Remote Control is intentionally Assistant-only; App Stream can use Assistant or a
/// legacy Vamp Host when that Mac has not already been paired through Assistant.
struct VampStreamConnectView: View {
    enum ConnectionDestination: String, CaseIterable, Identifiable {
        case remoteControl
        case appStream

        var id: String { rawValue }

        var title: String {
            switch self {
            case .remoteControl: return "Remote Control"
            case .appStream: return "App Stream"
            }
        }

        var icon: String {
            switch self {
            case .remoteControl: return "display"
            case .appStream: return "macwindow"
            }
        }
    }

    let environment: ClientAppEnvironment
    let onConnect: (DiscoveredHostRow) -> Void
    let onPairVampAssistant: () -> Void
    let onScanVampHost: () -> Void
    let pairedVampAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant]
    let vampAssistantAvailability: [String: BeetCodeRemoteSessionViewModel.Availability]
    let vampAssistantError: String?
    let onRemoteControl: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onAppStream: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onForgetVampAssistant: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    @ObservedObject private var hostsVM: HostsListViewModel

    // Remote Control remains implemented behind the transport adapter, but this
    // build intentionally exposes only App Stream while that surface is being
    // finalized. Flip this gate when the classic control screen is ready to
    // return to the destination picker.
    private static let showsRemoteControlDestination = false

    private var legacyHostsForAppStream: [DiscoveredHostRow] {
        let assistantHosts = Set(
            pairedVampAssistants.compactMap { VampStreamEndpointIdentity.host(from: $0.address) }
        )
        return hostsVM.displayHosts.filter {
            guard let host = VampStreamEndpointIdentity.host(from: $0.endpoint.hostname) else { return true }
            return !assistantHosts.contains(host)
        }
    }

    init(
        environment: ClientAppEnvironment,
        onConnect: @escaping (DiscoveredHostRow) -> Void,
        onPairVampAssistant: @escaping () -> Void,
        onScanVampHost: @escaping () -> Void,
        pairedVampAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant],
        vampAssistantAvailability: [String: BeetCodeRemoteSessionViewModel.Availability],
        vampAssistantError: String?,
        onRemoteControl: @escaping (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void,
        onAppStream: @escaping (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void,
        onForgetVampAssistant: @escaping (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    ) {
        self.environment = environment
        self.onConnect = onConnect
        self.onPairVampAssistant = onPairVampAssistant
        self.onScanVampHost = onScanVampHost
        self.pairedVampAssistants = pairedVampAssistants
        self.vampAssistantAvailability = vampAssistantAvailability
        self.vampAssistantError = vampAssistantError
        self.onRemoteControl = onRemoteControl
        self.onAppStream = onAppStream
        self.onForgetVampAssistant = onForgetVampAssistant
        self.hostsVM = environment.sharedHostsViewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VampStreamConnectHeader()
            if Self.showsRemoteControlDestination {
                VampStreamConnectionDestinationPicker(selection: .constant(.remoteControl))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
            VampAppStreamSection(
                pairedAssistants: pairedVampAssistants,
                availability: vampAssistantAvailability,
                errorMessage: vampAssistantError,
                legacyHosts: legacyHostsForAppStream,
                hostsVM: hostsVM,
                onPair: onPairVampAssistant,
                onAppStream: onAppStream,
                onForget: onForgetVampAssistant,
                onScan: onScanVampHost,
                onConnect: onConnect)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await hostsVM.start() }
    }
}

private struct VampStreamConnectHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Stream an app from your Mac")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(PR.fg)
            Text("Choose a trusted Mac, then open and control one app at a time.")
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }
}

private struct VampStreamConnectionDestinationPicker: View {
    @Binding var selection: VampStreamConnectView.ConnectionDestination

    var body: some View {
        Picker("Experience", selection: $selection) {
            ForEach(VampStreamConnectView.ConnectionDestination.allCases) { destination in
                Label(destination.title, systemImage: destination.icon)
                    .tag(destination)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Connection experience")
    }
}

private struct VampAssistantRemoteControlSection: View {
    let pairedAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant]
    let availability: [String: BeetCodeRemoteSessionViewModel.Availability]
    let errorMessage: String?
    let onPair: () -> Void
    let onRemoteControl: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onForget: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VampAssistantSourceIntro(
                    title: "Remote Control",
                    detail: "Vamp Assistant is the only source for full Mac control. Vamp Host entries stay out of this flow.",
                    onPair: onPair,
                    hasSavedAssistants: !pairedAssistants.isEmpty)

                if let errorMessage {
                    VampStreamConnectionError(message: errorMessage)
                }

                if pairedAssistants.isEmpty {
                    VampStreamEmptyState(
                        icon: "macwindow.badge.plus",
                        title: "No Assistant Macs yet",
                        message: "Pair Vamp Assistant to control a Mac. App Stream is a separate experience and never adds a host control button here.")
                } else {
                    Text("SAVED ASSISTANT MACS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PR.dim)
                        .padding(.top, 4)
                    ForEach(pairedAssistants) { assistant in
                        VampAssistantMacCard(
                            assistant: assistant,
                            availability: availability[assistant.address] ?? .checking,
                            onRemoteControl: { onRemoteControl(assistant) },
                            onAppStream: {},
                            showsRemoteControl: true,
                            showsAppStream: false,
                            onForget: { onForget(assistant) })
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
    }
}

private struct VampAppStreamSection: View {
    let pairedAssistants: [BeetCodeRemoteSessionViewModel.SavedAssistant]
    let availability: [String: BeetCodeRemoteSessionViewModel.Availability]
    let errorMessage: String?
    let legacyHosts: [DiscoveredHostRow]
    @ObservedObject var hostsVM: HostsListViewModel
    let onPair: () -> Void
    let onAppStream: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onForget: (BeetCodeRemoteSessionViewModel.SavedAssistant) -> Void
    let onScan: () -> Void
    let onConnect: (DiscoveredHostRow) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VampAssistantSourceIntro(
                    title: "App Stream",
                    detail: "Open one Mac app in a focused stream. Assistant is preferred; compatible Vamp Host Macs appear only as a fallback.",
                    onPair: onPair,
                    hasSavedAssistants: !pairedAssistants.isEmpty)

                if let errorMessage {
                    VampStreamConnectionError(message: errorMessage)
                }

                if !pairedAssistants.isEmpty {
                    Text("ASSISTANT APP STREAMS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PR.dim)
                        .padding(.top, 4)
                    ForEach(pairedAssistants) { assistant in
                        VampAssistantMacCard(
                            assistant: assistant,
                            availability: availability[assistant.address] ?? .checking,
                            onRemoteControl: {},
                            onAppStream: { onAppStream(assistant) },
                            showsRemoteControl: false,
                            showsAppStream: true,
                            onForget: { onForget(assistant) })
                    }
                }

                if !legacyHosts.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("OTHER APP-STREAM HOSTS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PR.dim)
                        Spacer(minLength: 8)
                        Button(action: onScan) {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(PR.fg)
                    }
                    ForEach(legacyHosts) { host in
                        VampHostMacCard(host: host, onConnect: { onConnect(host) })
                    }
                    Text("Vamp Host is shown only when this Mac is not already paired through Vamp Assistant.")
                        .font(.caption2)
                        .foregroundStyle(PR.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !pairedAssistants.isEmpty {
                    Text("Vamp Host entries for paired Macs are hidden automatically. Your Assistant connection is the single app-stream path for those Macs.")
                        .font(.caption)
                        .foregroundStyle(PR.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } else {
                    VampHostEmptyState(hostsVM: hostsVM, onScan: onScan)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .refreshable { await hostsVM.refresh() }
    }
}

private struct VampAssistantSourceIntro: View {
    let title: String
    let detail: String
    let onPair: () -> Void
    let hasSavedAssistants: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles.tv")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .frame(width: 38, height: 38)
                    .prGlassSurface(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(PR.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onPair) {
                Label(hasSavedAssistants ? "Pair another Mac" : "Pair Vamp Assistant", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PR.fg)
            .foregroundStyle(PR.bg)
            .accessibilityHint("Enter the private address and one-time pairing code shown by Vamp Assistant")
        }
        .padding(16)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }
}

private struct VampAssistantMacCard: View {
    let assistant: BeetCodeRemoteSessionViewModel.SavedAssistant
    let availability: BeetCodeRemoteSessionViewModel.Availability
    let onRemoteControl: () -> Void
    let onAppStream: () -> Void
    let showsRemoteControl: Bool
    let showsAppStream: Bool
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: "macbook")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .frame(width: 38, height: 38)
                    .prGlassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(assistant.displayName)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                        .lineLimit(1)
                    Text(assistant.address)
                        .font(.caption.monospaced())
                        .foregroundStyle(PR.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VampAssistantAvailabilityBadge(availability: availability)
                Menu {
                    Button("Forget this Mac", role: .destructive, action: onForget)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(PR.dim)
                }
                .accessibilityLabel("More actions for \(assistant.displayName)")
            }

            HStack(spacing: 10) {
                if showsRemoteControl {
                    VampAssistantActionButton(
                        title: "Control Mac",
                        systemImage: "display",
                        action: onRemoteControl)
                }
                if showsAppStream {
                    VampAssistantActionButton(
                        title: "Stream an app",
                        systemImage: "macwindow.badge.plus",
                        action: onAppStream)
                }
            }
        }
        .padding(14)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(assistant.displayName), \(assistant.address)")
    }
}

private struct VampAssistantActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PR.fg)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct VampAssistantAvailabilityBadge: View {
    let availability: BeetCodeRemoteSessionViewModel.Availability

    private var color: Color {
        switch availability {
        case .ready: return .green
        case .unavailable: return .red
        case .checking: return .gray
        }
    }

    private var text: String {
        switch availability {
        case .ready: return "Ready"
        case .unavailable: return "Offline"
        case .checking: return "Checking"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.65), radius: 3)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PR.fg2)
        }
        .accessibilityLabel("\(text) Mac")
    }
}

private struct VampHostConnectionSection: View {
    @ObservedObject var hostsVM: HostsListViewModel
    let onScan: () -> Void
    let onConnect: (DiscoveredHostRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vamp Host")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(PR.fg)
                    Text("Browse Mac apps over the original host session.")
                        .font(.footnote)
                        .foregroundStyle(PR.fg2)
                }
                Spacer()
                Button(action: onScan) {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(PR.fg)
                .accessibilityHint("Scan a Vamp Host pairing code")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 12) {
                    if hostsVM.displayHosts.isEmpty {
                        VampHostEmptyState(hostsVM: hostsVM)
                    } else {
                        ForEach(hostsVM.displayHosts) { host in
                            VampHostMacCard(host: host, onConnect: { onConnect(host) })
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .refreshable { await hostsVM.refresh() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct VampHostMacCard: View {
    let host: DiscoveredHostRow
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 13) {
                Image(systemName: host.isTerminalOnlyHost ? "terminal" : "macbook")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .frame(width: 40, height: 40)
                    .prGlassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(host.title)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                        .lineLimit(1)
                    Text(host.isTerminalOnlyHost ? "Terminal-only host" : "App windows · \(host.subtitle)")
                        .font(.caption)
                        .foregroundStyle(PR.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if host.isTerminalOnlyHost {
                    Text("Unavailable")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PR.dim)
                } else {
                    Label("Browse apps", systemImage: "macwindow")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PR.fg)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(host.isTerminalOnlyHost)
        .accessibilityLabel(host.title)
        .accessibilityValue(host.isTerminalOnlyHost ? "Terminal-only host" : "Ready to browse apps")
    }
}

private struct VampHostEmptyState: View {
    @ObservedObject var hostsVM: HostsListViewModel
    var onScan: (() -> Void)? = nil

    var body: some View {
        VampStreamEmptyState(
            icon: hostsVM.state == .loading
                ? "hourglass"
                : (hostsVM.hasLocalNetworkIssue ? "wifi.exclamationmark" : "macbook.and.iphone"),
            title: hostsVM.state == .loading ? "Looking for Vamp Hosts…" : "No Vamp Host found",
            message: message,
            actionTitle: hostsVM.state == .loading ? nil : (onScan == nil ? "Retry discovery" : "Scan QR"),
            action: onScan ?? { Task { await hostsVM.refresh() } })
    }

    private var message: String {
        switch hostsVM.state {
        case .loading:
            return "Open Vamp Host on your Mac and keep both devices on the same LAN or private Tailscale network."
        case .localNetworkIssue(let message):
            return message
        case .unavailable:
            return "A saved host is unavailable. Check that it is running and reachable on a trusted network."
        case .empty, .available:
            return "Open Vamp Host on your Mac and keep both devices on the same LAN or private Tailscale network."
        }
    }
}

private struct VampStreamConnectionError: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.footnote)
                .foregroundStyle(PR.fg)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PR.warn)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct VampStreamEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    init(
        icon: String,
        title: String,
        message: String,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(PR.fg)
            Text(title)
                .font(.headline)
                .foregroundStyle(PR.fg)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .tint(PR.fg)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }
}

private extension HostsListViewModel {
    var hasLocalNetworkIssue: Bool {
        if case .localNetworkIssue = state { return true }
        return false
    }
}

/// A small identity adapter used only by the picker. Assistant and Vamp Host use
/// different transports and ports, so the private host/IP is the useful common key.
private enum VampStreamEndpointIdentity {
    static func host(from address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        if let host = URLComponents(string: candidate)?.host {
            return normalize(host)
        }
        return normalize(trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .lowercased()
    }
}

/// Full-screen connecting state.
struct VampStreamConnectingView: View {
    let name: String
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Connecting to \(name)…")
                .font(.headline)
                .foregroundStyle(PR.fg)
            Text("Approve this iPhone on your Mac the first time.")
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("Cancel", role: .cancel, action: onCancel)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Centered message + single action (unsupported host, errors).
struct VampStreamMessageView: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(PR.accent)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(PR.fg)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
