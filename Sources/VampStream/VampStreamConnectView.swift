import SwiftUI

private var anonymizeStreamPreview: Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment["VAMP_SCREENSHOT_PREVIEW"] == "1"
    #else
    false
    #endif
}

/// The first screen in Vamp Stream. App Stream leads with Vamp Sync, then
/// Assistant as a follow-on pairing path. Remote Control remains Assistant-only
/// and is not the default destination in this build.
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

    private var legacyHostsForAppStream: [DiscoveredHostRow] {
        hostsVM.displayHosts.filter { !$0.isTerminalOnlyHost }
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
            Text(VampStreamHomeCopy.headerTitle)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(PR.fg)
            Text(VampStreamHomeCopy.headerDetail)
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
                .fixedSize(horizontal: false, vertical: true)
            VampStreamVersionBadge()
                .padding(.top, 5)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }
}

private struct VampStreamVersionBadge: View {
    private let version: String
    private let build: String

    init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        Text(verbatim: "Version \(version) (\(build))")
            .font(.caption2.monospaced())
            .foregroundStyle(PR.dim)
            .accessibilityLabel("Version \(version), build \(build)")
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
                    detail: "Vamp Assistant is the only source for full Mac control. Vamp Sync entries stay out of this flow.",
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


    @State private var manualAddress = ""
    @State private var manualError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(
                    VampStreamHomeLayout.sections(
                        hasSyncHosts: !legacyHosts.isEmpty,
                        hasAssistants: !pairedAssistants.isEmpty,
                        hasAssistantError: errorMessage != nil
                    )
                ) { section in
                    homeSection(section)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .refreshable { await hostsVM.refresh() }
    }

    @ViewBuilder
    private func homeSection(_ section: VampStreamHomeLayout.Section) -> some View {
        switch section {
        case .syncHostCard:
            VampSyncConnectCard(
                manualAddress: $manualAddress,
                manualError: $manualError,
                onScan: onScan,
                onConnectByAddress: connectByAddress)
        case .syncMacs:
            VStack(alignment: .leading, spacing: 12) {
                VampStreamSectionLabel(title: VampStreamHomeCopy.syncMacsHeading)
                ForEach(anonymizeStreamPreview ? Array(legacyHosts.prefix(1)) : legacyHosts) { host in
                    VampHostMacCard(host: host, onConnect: { onConnect(host) })
                }
            }
        case .syncEmptyHint:
            VampSyncEmptyHint(hostsVM: hostsVM)
        case .assistantError:
            if let errorMessage {
                VampStreamConnectionError(message: errorMessage)
            }
        case .assistantHostCard:
            VampAssistantFollowOnCard(
                onPair: onPair,
                hasSavedAssistants: !pairedAssistants.isEmpty)
        case .assistantMacs:
            VStack(alignment: .leading, spacing: 12) {
                VampStreamSectionLabel(title: VampStreamHomeCopy.assistantMacsHeading)
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
        }
    }

    private func connectByAddress() {
        guard let host = hostsVM.addManualHost(address: manualAddress) else {
            manualError = VampStreamHomeCopy.addressError
            return
        }
        manualError = nil
        onConnect(host)
    }
}

private struct VampStreamSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PR.dim)
            .padding(.top, 4)
    }
}

private struct VampSyncConnectCard: View {
    @Binding var manualAddress: String
    @Binding var manualError: String?
    let onScan: () -> Void
    let onConnectByAddress: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "macbook.and.iphone")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .frame(width: 38, height: 38)
                    .prGlassSurface(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(VampStreamHomeCopy.syncTitle)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                    Text(VampStreamHomeCopy.syncDetail)
                        .font(.footnote)
                        .foregroundStyle(PR.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onScan) {
                Label(VampStreamHomeCopy.scanSync, systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(PR.fg)
            .foregroundStyle(PR.bg)
            .accessibilityHint(Text(VampStreamHomeCopy.scanSyncHint))

            VStack(alignment: .leading, spacing: 8) {
                Text(VampStreamHomeCopy.orConnectByAddress)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PR.dim)
                TextField(
                    "",
                    text: $manualAddress,
                    prompt: Text(VampStreamHomeCopy.addressPlaceholder)
                )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(VampStreamHomeCopy.addressPlaceholder))
                Button(action: onConnectByAddress) {
                    Text(VampStreamHomeCopy.connectByAddress)
                }
                    .buttonStyle(.bordered)
                    .disabled(manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let manualError {
                    Text(manualError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(VampStreamHomeCopy.syncTitle))
    }
}

private struct VampSyncEmptyHint: View {
    @ObservedObject var hostsVM: HostsListViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(PR.fg)
                .frame(width: 38, height: 38)
                .prGlassSurface(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PR.fg)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(PR.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                if !isLoading {
                    Button {
                        Task { await hostsVM.refresh() }
                    } label: {
                        Text(VampStreamHomeCopy.retryDiscovery)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var isLoading: Bool {
        if case .loading = hostsVM.state { return true }
        return false
    }

    private var icon: String {
        if isLoading { return "hourglass" }
        return hostsVM.hasLocalNetworkIssue ? "wifi.exclamationmark" : "macbook.and.iphone"
    }

    private var title: String {
        isLoading ? VampStreamHomeCopy.lookingForSync : VampStreamHomeCopy.noSyncFound
    }

    private var message: String {
        switch hostsVM.state {
        case .loading:
            return VampStreamHomeCopy.syncNetworkHint
        case .localNetworkIssue(let message):
            return message
        case .unavailable:
            return VampStreamHomeCopy.unavailableSync
        case .empty, .available:
            return VampStreamHomeCopy.syncNetworkHint
        }
    }
}

private struct VampAssistantFollowOnCard: View {
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
                    Text(VampStreamHomeCopy.assistantTitle)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                    Text(VampStreamHomeCopy.assistantDetail)
                        .font(.footnote)
                        .foregroundStyle(PR.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onPair) {
                Label(
                    VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: hasSavedAssistants),
                    systemImage: "plus"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(Text(VampStreamHomeCopy.pairAssistantHint))
        }
        .padding(16)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(VampStreamHomeCopy.assistantTitle))
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
                Label(
                    VampStreamHomeCopy.pairAssistantTitle(hasSavedAssistants: hasSavedAssistants),
                    systemImage: "plus"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PR.fg)
            .foregroundStyle(PR.bg)
            .accessibilityHint(Text(VampStreamHomeCopy.pairAssistantHint))
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
                    HStack(spacing: 7) {
                        if assistant.hasGenericDisplayName {
                            switch assistant.connectionKind {
                            case .localNetwork:
                                Text("Local Mac")
                            case .tailscale:
                                Text("Tailscale Mac")
                            case .privateNetwork:
                                Text("Private Mac")
                            }
                        } else {
                            Text(assistant.displayName)
                        }
                        Text("Vamp Assistant")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PR.dim)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PR.fg.opacity(0.08), in: Capsule())
                    }
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
        case .reachable: return .green
        case .unavailable: return .red
        case .checking: return .gray
        }
    }

    private var text: String {
        switch availability {
        case .reachable: return "Online"
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
                    Text("Vamp Sync")
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
                .accessibilityHint("Scan a Vamp Sync pairing code")
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
                    Text(anonymizeStreamPreview ? "Your Mac" : host.title)
                        .font(.headline)
                        .foregroundStyle(PR.fg)
                        .lineLimit(1)
                    Text(host.isTerminalOnlyHost ? "Terminal-only host" : (anonymizeStreamPreview ? "App windows · Private network" : "App windows · \(host.subtitle)"))
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
        .accessibilityLabel(anonymizeStreamPreview ? "Your Mac" : host.title)
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
            title: hostsVM.state == .loading ? "Looking for Vamp Sync…" : "No Vamp Sync found",
            message: message,
            actionTitle: hostsVM.state == .loading ? nil : (onScan == nil ? "Retry discovery" : "Scan QR"),
            action: onScan ?? { Task { await hostsVM.refresh() } })
    }

    private var message: String {
        switch hostsVM.state {
        case .loading:
            return "Open Vamp Sync on your Mac and keep both devices on the same LAN or private Tailscale network."
        case .localNetworkIssue(let message):
            return message
        case .unavailable:
            return "A saved host is unavailable. Check that it is running and reachable on a trusted network."
        case .empty, .available:
            return "Open Vamp Sync on your Mac and keep both devices on the same LAN or private Tailscale network."
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

/// A small identity adapter used only by the picker. Assistant and Vamp Sync use
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
