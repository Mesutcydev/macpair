import SwiftUI

/// Vamp Stream's Mac picker — a focused first screen (not Vamp Control's home). Reuses the shared
/// discovery/connection machinery via `HostsListViewModel`, presented in the app's glass language.
struct VampStreamConnectView: View {
    let environment: ClientAppEnvironment
    var onConnect: (DiscoveredHostRow) -> Void
    var onPairVampAssistant: () -> Void
    var onScanVampHost: () -> Void
    var savedVampAssistantAddress: String?
    var vampAssistantError: String?
    var onReconnectVampAssistant: () -> Void
    @ObservedObject private var hostsVM: HostsListViewModel

    init(
        environment: ClientAppEnvironment,
        onConnect: @escaping (DiscoveredHostRow) -> Void,
        onPairVampAssistant: @escaping () -> Void,
        onScanVampHost: @escaping () -> Void,
        savedVampAssistantAddress: String?,
        vampAssistantError: String?,
        onReconnectVampAssistant: @escaping () -> Void
    ) {
        self.environment = environment
        self.onConnect = onConnect
        self.onPairVampAssistant = onPairVampAssistant
        self.onScanVampHost = onScanVampHost
        self.savedVampAssistantAddress = savedVampAssistantAddress
        self.vampAssistantError = vampAssistantError
        self.onReconnectVampAssistant = onReconnectVampAssistant
        self.hostsVM = environment.sharedHostsViewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vamp Stream")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(PR.fg)
                Text("Use a Mac app on your iPhone")
                    .font(.subheadline)
                    .foregroundStyle(PR.fg2)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 18)

            Button(action: onScanVampHost) {
                Label("Scan Vamp Host QR", systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(PR.accent)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 12) {
                    vampAssistantCard

                    if let savedVampAssistantAddress {
                        savedVampAssistantCard(savedVampAssistantAddress)
                    }
                    if let vampAssistantError {
                        vampAssistantErrorCard(vampAssistantError)
                    }

                    if hostsVM.displayHosts.isEmpty {
                        emptyState
                    } else {
                        Text("VAMP HOSTS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PR.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                        ForEach(hostsVM.displayHosts) { host in
                            hostCard(host)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .refreshable { await hostsVM.refresh() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await hostsVM.start() }
    }

    private var vampAssistantCard: some View {
        Button(action: onPairVampAssistant) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(PR.fg.opacity(0.08)).frame(width: 46, height: 46)
                    Image(systemName: "macwindow")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(PR.fg)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pair Vamp Assistant")
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                    Text("Remote control and app streaming · port 9575")
                        .font(.caption)
                        .foregroundStyle(PR.dim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PR.dim)
            }
            .padding(16)
            .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pair Vamp Assistant")
        .accessibilityHint("Enter the private address and one-time pairing code shown by Vamp Assistant")
    }

    private func savedVampAssistantCard(_ address: String) -> some View {
        Button(action: onReconnectVampAssistant) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(PR.fg.opacity(0.08)).frame(width: 40, height: 40)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(PR.fg)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reconnect to Vamp Assistant")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PR.fg)
                    Text(address)
                        .font(.caption.monospaced())
                        .foregroundStyle(PR.dim)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PR.dim)
            }
            .padding(14)
            .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reconnect to Vamp Assistant")
        .accessibilityValue(address)
    }

    private func vampAssistantErrorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PR.warn)
            Text(message)
                .font(.footnote)
                .foregroundStyle(PR.fg)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func hostCard(_ host: DiscoveredHostRow) -> some View {
        Button {
            onConnect(host)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(PR.accent.opacity(0.16)).frame(width: 46, height: 46)
                    Image(systemName: "macbook")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(PR.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.title)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                    Text(host.subtitle)
                        .font(.caption)
                        .foregroundStyle(PR.dim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PR.dim)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if hostsVM.state == .loading {
                ProgressView()
            } else {
                Image(systemName: hostsVM.hasLocalNetworkIssue ? "wifi.exclamationmark" : "macbook.and.iphone")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(PR.accent)
            }
            Text(hostsVM.state == .loading ? "Looking for your Mac…" : "No Vamp Host found")
                .font(.headline)
                .foregroundStyle(PR.fg)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if hostsVM.state != .loading {
                Button("Retry discovery") {
                    Task { await hostsVM.refresh() }
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Search the private network again for Vamp Host")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var emptyMessage: String {
        switch hostsVM.state {
        case .loading:
            return "Open Vamp Host on your Mac and keep both devices on the same private network."
        case .localNetworkIssue(let message):
            return message
        case .unavailable:
            return "Vamp Host is saved but unavailable. Check that it is running and that both devices are on a trusted network."
        case .empty, .available:
            return "Open Vamp Host on your Mac and keep both devices on the same private network or Tailscale."
        }
    }
}

private extension HostsListViewModel {
    var hasLocalNetworkIssue: Bool {
        if case .localNetworkIssue = state { return true }
        return false
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
