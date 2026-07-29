import SwiftUI
import SharedModels
import Diagnostics

/// App settings window (⌘,): stream quality, behavior toggles, trusted hosts,
/// diagnostics, and open-source release information.
struct MacSettingsScreen: View {
    @ObservedObject var environment: ClientAppEnvironment
    @StateObject private var trustedHostsVM: ClientTrustedHostsViewModel

    // Diagnostics tab: connection log + on-device "explain this log".
    @State private var logItems: [EventLogItem] = []
    @State private var explainAvailable = false
    @State private var explaining = false
    @State private var explanation: String?
    @State private var explainEngine: LogExplainer.Engine?

    // Feature toggles share the same keys the iOS client uses, so a user's
    // preference is consistent across both apps' shared logic.
    @AppStorage("com.remotedesktop.client.filetransfer.enabled") private var fileTransferEnabled = true
    @AppStorage("client.clipboard.enabled") private var clipboardEnabled = true

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        _trustedHostsVM = StateObject(wrappedValue: ClientTrustedHostsViewModel(
            peerStore: environment.trustedPeerStore
        ))
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            trustedHostsTab
                .tabItem { Label("Trusted Hosts", systemImage: "checkmark.shield") }
            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            openSourceTab
                .tabItem { Label("Open Source", systemImage: "checkmark.seal") }
        }
        .frame(width: 520, height: 440)
    }

    // MARK: - Diagnostics

    private var diagnosticsTab: some View {
        Form {
            if explainAvailable {
                Section {
                    if let explanation {
                        Text(explanation).font(.callout).textSelection(.enabled)
                        Button("Analyze again") { Task { await explain() } }.disabled(explaining)
                    } else {
                        Button {
                            Task { await explain() }
                        } label: {
                            Label(explaining ? "Analyzing…" : "Explain this log", systemImage: "sparkles")
                        }
                        .disabled(explaining || logItems.isEmpty)
                    }
                    Text(explainEngine.map { "Answered by \($0.label) · your log isn’t stored or shared." }
                         ?? "Runs privately — on-device or via Apple Private Cloud Compute; your log isn’t stored or shared.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("AI help") }
            }
            Section {
                if logItems.isEmpty {
                    Text("No events yet — connect to a Mac, then reopen this.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(logItems.reversed()) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(item.severity.rawValue.uppercased())
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(logColor(item.severity))
                                    Text("\(item.category): \(item.message)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 220)
                }
            } header: { Text("Connection log") }
        }
        .formStyle(.grouped)
        .task { await reloadLog() }
    }

    private func reloadLog() async {
        logItems = await environment.eventLogStore.recentItems(limit: 500)
        explainAvailable = LogExplainer.availability.isAvailable
    }

    private func explain() async {
        explaining = true
        explanation = nil
        let result = await LogExplainer.explain(logItems)
        explanation = result?.text ?? "Couldn’t analyze the log right now — try again in a moment."
        explainEngine = result?.engine
        explaining = false
    }

    private func logColor(_ s: EventSeverity) -> Color {
        switch s {
        case .error: return .red
        case .warning: return .orange
        case .info, .debug: return .secondary
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Picker(selection: $environment.preferredQualityPreset) {
                    Text("Performance — lighter, 30 fps").tag(StreamQualityPreset.performance)
                    Text("Balanced — smooth everyday use, 30 fps").tag(StreamQualityPreset.balanced)
                    Text("Quality — sharp 4K, 60 fps").tag(StreamQualityPreset.quality)
                    if environment.isUltraQualityEntitled {
                        Text("Ultra — native resolution, 60 fps").tag(StreamQualityPreset.ultra)
                    }
                } label: {
                    Label("Stream quality", systemImage: "dial.high")
                }
                if let message = environment.ultraQualityAvailabilityMessage {
                    Label(message, systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Streaming")
            }

            Section {
                Toggle(isOn: $environment.showsStatsOverlay) {
                    Label("Show connection stats during sessions", systemImage: "waveform.path.ecg")
                }
                Toggle(isOn: $environment.prefersViewOnly) {
                    Label("View only (don't send mouse or keyboard)", systemImage: "eye")
                }
                Toggle(isOn: $environment.lowPowerModeEnabled) {
                    Label("Low power mode (reduce refresh rate)", systemImage: "leaf")
                }
                Picker("Connection Controls", selection: connectionControlsPresentation) {
                    ForEach(ConnectionControlsPresentation.allCases) { mode in
                        Text(mode.settingsLabel).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("During Sessions")
            }

            Section {
                Toggle(isOn: $fileTransferEnabled) {
                    Label("File transfer", systemImage: "arrow.up.arrow.down.circle")
                }
                Toggle(isOn: $clipboardEnabled) {
                    Label("Clipboard sync", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("Features")
            } footer: {
                Text("Send files to the host and share text both ways. Turn off to hide these controls during a session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Text(environment.clientIdentity.displayName)
                } label: {
                    Label("Appears to hosts as", systemImage: "desktopcomputer")
                }
                LabeledContent {
                    Text(String(environment.clientIdentity.publicKeyFingerprint.prefix(16)) + "…")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } label: {
                    Label("Key fingerprint", systemImage: "key")
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Your device identity is generated on-device and never leaves it. Hosts verify it before accepting a connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var connectionControlsPresentation: Binding<ConnectionControlsPresentation> {
        Binding(
            get: {
                ConnectionControlsPresentation(
                    rawValue: UserDefaults.standard.string(
                        forKey: ConnectionControlsPresentation.storageKey
                    ) ?? ""
                ) ?? .floatingPill
            },
            set: { UserDefaults.standard.set($0.rawValue, forKey: ConnectionControlsPresentation.storageKey) }
        )
    }

    // MARK: - Trusted hosts

    private var trustedHostsTab: some View {
        Group {
            if trustedHostsVM.trustedHosts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No trusted Macs yet")
                        .font(.headline)
                    Text("Macs you connect to and approve will appear here. You can forget any of them at any time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                Form {
                    Section {
                        ForEach(trustedHostsVM.trustedHosts, id: \.id) { peer in
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName).font(.headline)
                                    Text(String(peer.fingerprint.prefix(24)) + "…")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button("Forget") { Task { await trustedHostsVM.forget(peer) } }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        Text("Trusted Macs")
                    }
                    if let error = trustedHostsVM.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .task { await trustedHostsVM.refresh() }
    }

    // MARK: - Open-source distribution

    private var openSourceTab: some View {
        VStack(spacing: 18) {
            proBadge(symbol: "checkmark.seal.fill", tint: .green)
            Text("Open source. All features included.")
                .font(.title3.weight(.semibold))
            Text("This Apache-2.0 website build includes unlimited streaming and every supported quality preset. There are no subscriptions or in-app purchases.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Link("Source, licenses, and release integrity",
                 destination: URL(string: "https://github.com/Mesutcydev/screenharbor")!)
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func proBadge(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 84, height: 84)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: MacBrand.cardCornerRadius, style: .continuous))
    }
}
