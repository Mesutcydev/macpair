import SwiftUI
import SharedProtocol
#if canImport(UIKit)
import UIKit
#endif

/// Assistant-backed App Stream keeps the app browser separate from whole-display Remote
/// Control, while both destinations use the same proven control surface after selection.
struct VampAssistantAppStreamView: View {
    let session: BeetCodeRemoteSessionViewModel.Session
    let onClose: () -> Void
    let onRefreshStatus: () async -> String?

    @State private var runningApplications: [BeetCodeRemoteApplication] = []
    @State private var installedApplications: [BeetCodeRemoteApplication] = []
    @State private var selectedApplication: BeetCodeRemoteApplication?
    @State private var launchingName: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectionRevision = UUID()
    @State private var viewportAspect = 9.0 / 19.5

    var body: some View {
        GeometryReader { proxy in
            Group {
                if !session.status.ready {
                    // App inventory remains readable while macOS is at loginwindow, but
                    // launching or focusing a window cannot succeed there. Route through
                    // the same authenticated unlock/permission surface as Remote Control
                    // before exposing tappable apps.
                    BeetCodeRemoteView(
                        session: session,
                        onClose: onClose,
                        onRefresh: onRefreshStatus)
                } else if let selectedApplication {
                    BeetCodeRemoteView(
                        session: session,
                        windowID: selectedApplication.windowID,
                        streamTitle: selectedApplication.name,
                        isTerminalApplication: AppStreamApplicationProfile.isTerminal(
                            bundleIdentifier: selectedApplication.bundleIdentifier,
                            name: selectedApplication.name),
                        // ScreenCaptureKit fixes its encoder dimensions when a
                        // stream starts. Restart after the Mac confirms new AX
                        // bounds so rotation never squeezes or crops the newly
                        // resized window into the previous frame geometry.
                        streamGeometryRevision: "\(selectedApplication.windowID ?? 0)-\(selectedApplication.width)-\(selectedApplication.height)",
                        onClose: onClose,
                        onRefresh: onRefreshStatus,
                        onChooseApplication: { selectionRevision = UUID(); self.selectedApplication = nil },
                        onViewportSize: { updateViewport($0) })
                } else {
                    VampAssistantApplicationBrowser(
                        macName: session.displayName,
                        runningApplications: runningApplications,
                        installedApplications: installedApplications,
                        isLoading: isLoading,
                        launchingName: launchingName,
                        errorMessage: errorMessage,
                        onClose: onClose,
                        onRefresh: { Task { await loadApplications() } },
                        onSelect: { application in Task { await open(application) } },
                        onQuit: { application in Task { await quit(application) } })
                }
            }
            .tint(PR.accent)
            // Seeds the aspect for the launch request, before any video exists to measure.
            // Once the stream is up, `onViewportSize` refines it to the real video area.
            .onAppear { updateViewport(proxy.size) }
            .onChangeCompat(of: proxy.size) { updateViewport($0) }
            .task(id: resizeTaskID) {
                guard let windowID = selectedApplication?.windowID else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let revision = selectionRevision
                do {
                    let resized = try await session.client.resizeApplication(
                        windowID: windowID, clientViewportAspect: viewportAspect)
                    guard !Task.isCancelled, revision == selectionRevision,
                          selectedApplication?.windowID == windowID else { return }
                    present(resized)
                } catch {
                    guard !Task.isCancelled, revision == selectionRevision else { return }
                    errorMessage = "The Mac kept the closest window size: \(error.localizedDescription)"
                }
            }
            .task(id: "\(session.address)-\(session.status.ready)") {
                guard session.status.ready else { return }
                if runningApplications.isEmpty, installedApplications.isEmpty {
                    await loadApplications()
                }
            }
        }
        .onDisappear { selectionRevision = UUID(); launchingName = nil }
    }

    private var resizeTaskID: String {
        "\(selectedApplication?.windowID ?? 0)-\(viewportAspect)"
    }

    private func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = Double(size.width / size.height)
        guard aspect.isFinite, (0.25...4).contains(aspect) else { return }
        viewportAspect = aspect
    }

    private func loadApplications() async {
        guard session.status.ready else { return }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            apply(try await session.client.applications())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func quit(_ application: BeetCodeRemoteApplication) async {
        guard session.status.ready else {
            errorMessage = "Unlock the Mac before closing an application."
            return
        }
        guard launchingName == nil else { return }
        guard let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty else {
            errorMessage = "That Mac application does not expose a close identifier."
            return
        }
        guard ApplicationClosePolicy.canClose(bundleIdentifier) else {
            errorMessage = "\(application.name) cannot be closed remotely."
            return
        }
        errorMessage = nil
        do {
            try await session.client.quitApplication(bundleIdentifier: bundleIdentifier)
            if selectedApplication?.bundleIdentifier == bundleIdentifier {
                selectedApplication = nil
            }
            await loadApplications()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ application: BeetCodeRemoteApplication) async {
        guard session.status.ready else {
            errorMessage = "Unlock the Mac before opening an application."
            return
        }
        guard launchingName == nil else { return }
        let revision = UUID()
        selectionRevision = revision
        launchingName = application.name
        errorMessage = nil
        defer { if revision == selectionRevision { launchingName = nil } }
        if application.isRunning, let windowID = application.windowID {
            do {
                let resized = try await session.client.resizeApplication(
                    windowID: windowID, clientViewportAspect: viewportAspect)
                guard !Task.isCancelled, revision == selectionRevision else { return }
                present(resized)
            } catch {
                guard !Task.isCancelled, revision == selectionRevision else { return }
                present(application)
                errorMessage = "The Mac kept the closest window size: \(error.localizedDescription)"
            }
            return
        }
        guard let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty else {
            errorMessage = "That Mac application does not expose a launch identifier."
            return
        }
        do {
            let launched = try await session.client.launchApplication(
                bundleIdentifier: bundleIdentifier,
                clientViewportAspect: viewportAspect)
            guard !Task.isCancelled, revision == selectionRevision else { return }
            present(launched)
            let applications = try await session.client.applications()
            guard !Task.isCancelled, revision == selectionRevision else { return }
            apply(applications)
        } catch {
            guard !Task.isCancelled, revision == selectionRevision else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// `BeetCodeRemoteView` streams the whole Mac display when it is handed no window id, so an
    /// app the Mac could not resolve a window for would silently open the entire desktop instead
    /// of the one app the browser asked for. Stay in the browser and say what happened.
    private func present(_ application: BeetCodeRemoteApplication) {
        guard application.windowID != nil else {
            errorMessage = "\(application.name) has no open window on the Mac yet. Open one there, then tap it again."
            return
        }
        // Do not carry a previous failure into a selection that just succeeded — the browser
        // shows this banner again as soon as the user comes back from the stream.
        errorMessage = nil
        selectedApplication = application
    }

    private func apply(_ applications: [BeetCodeRemoteApplication]) {
        runningApplications = applications.filter(\.isRunning)
        installedApplications = applications.filter { !$0.isRunning }
    }
}

private struct VampAssistantApplicationBrowser: View {
    let macName: String
    let runningApplications: [BeetCodeRemoteApplication]
    let installedApplications: [BeetCodeRemoteApplication]
    let isLoading: Bool
    let launchingName: String?
    let errorMessage: String?
    let onClose: () -> Void
    let onRefresh: () -> Void
    let onSelect: (BeetCodeRemoteApplication) -> Void
    let onQuit: (BeetCodeRemoteApplication) -> Void

    @State private var closeChoice: BeetCodeRemoteApplication?

    @State private var searchText = ""
    private func matches(_ app: BeetCodeRemoteApplication) -> Bool {
        searchText.isEmpty || app.name.localizedStandardContains(searchText)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VampAssistantApplicationHeader(macName: macName, onClose: onClose)
            VampAppSearchField(text: $searchText)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let errorMessage {
                        VampAssistantApplicationError(message: errorMessage, onRetry: onRefresh)
                    }
                    if let launchingName {
                        HStack(spacing: 12) {
                            ProgressView().tint(PR.fg)
                            Text("Opening \(launchingName)…")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PR.fg)
                            Spacer()
                        }
                        .padding(14)
                        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
                    }
                    if runningApplications.isEmpty, installedApplications.isEmpty {
                        VampStreamAppListEmptyHint(
                            title: isLoading ? "Loading applications…" : "No applications found",
                            isLoading: isLoading,
                            actionTitle: isLoading ? nil : "Refresh",
                            action: isLoading ? nil : onRefresh
                        )
                    } else {
                        let runningMatches = runningApplications.filter(matches)
                        let installedMatches = installedApplications.filter(matches)
                        if runningMatches.isEmpty, installedMatches.isEmpty {
                            VampStreamAppListEmptyHint(title: "No apps match")
                        } else {
                            if !runningMatches.isEmpty {
                                VampAssistantApplicationSection(
                                    title: "Running",
                                    applications: runningMatches,
                                    isDisabled: launchingName != nil,
                                    onSelect: onSelect,
                                    onQuit: { closeChoice = $0 })
                            }
                            if !installedMatches.isEmpty {
                                VampAssistantApplicationSection(
                                    title: "All Apps",
                                    applications: installedMatches,
                                    isDisabled: launchingName != nil,
                                    onSelect: onSelect,
                                    onQuit: { closeChoice = $0 })
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { onRefresh() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PRAppBackground().ignoresSafeArea())
        .confirmationDialog(
            closeChoice.map { "Close \($0.name)?" } ?? "Close this app?",
            isPresented: Binding(
                get: { closeChoice != nil },
                set: { if !$0 { closeChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let application = closeChoice {
                Button("Close \(application.name)", role: .destructive) { onQuit(application) }
            }
            Button("Cancel", role: .cancel) { closeChoice = nil }
        } message: {
            Text("Unsaved changes on the Mac may be lost.")
        }
    }
}

private struct VampAssistantApplicationHeader: View {
    let macName: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Apps")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PR.fg)
                Text(macName)
                    .font(.title3.weight(.regular))
                    .foregroundStyle(PR.fg2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(PR.fg2)
                    .frame(width: 36, height: 36)
                    .prGlassSurface(in: Circle(), isInteractive: true)
            }
            .buttonStyle(PRGlassPressButtonStyle())
            .accessibilityLabel("Close host")
            .accessibilityHint("Return to the Vamp Assistant picker")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

private struct VampAssistantApplicationSection: View {
    let title: LocalizedStringKey
    let applications: [BeetCodeRemoteApplication]
    let isDisabled: Bool
    let onSelect: (BeetCodeRemoteApplication) -> Void
    let onQuit: (BeetCodeRemoteApplication) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(PR.dim)
                .padding(.horizontal, 4)
                .padding(.top, 6)
            VStack(spacing: 10) {
                ForEach(applications) { application in
                    Button { onSelect(application) } label: {
                        VampAssistantApplicationRow(
                            name: application.name,
                            detail: application.detail,
                            isRunning: application.isRunning,
                            isActive: application.isActive,
                            iconPNGBase64: application.iconPNGBase64)
                    }
                    .buttonStyle(PRGlassPressButtonStyle())
                    .disabled(isDisabled)
                    .contextMenu {
                        if application.isRunning,
                           let bundle = application.bundleIdentifier,
                           ApplicationClosePolicy.canClose(bundle) {
                            Button("Close \(application.name)", systemImage: "xmark.app", role: .destructive) {
                                onQuit(application)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct VampAssistantApplicationRow: View {
    let name: String
    let detail: String
    let isRunning: Bool
    let isActive: Bool
    let iconPNGBase64: String?

    var body: some View {
        HStack(spacing: 13) {
            applicationIcon
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .lineLimit(1)
                Text(isActive ? "Active now" : (isRunning ? detail : "Installed · tap to open"))
                    .font(.caption)
                    .foregroundStyle(isActive ? PR.fg : PR.fg2)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: isRunning ? "chevron.right" : "arrow.up.forward.app")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PR.dim)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous), isInteractive: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(isActive ? "Active now" : (isRunning ? "Running" : "Installed"))
        .accessibilityHint(isRunning ? "Stream this Mac application" : "Open and stream this Mac application")
    }

    @ViewBuilder private var applicationIcon: some View {
        if let iconPNGBase64,
           let data = Data(base64Encoded: iconPNGBase64),
           let image = UIImage(data: data) {
            Image(uiImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .padding(9)
                .foregroundStyle(PR.fg2)
                .background(PR.fg.opacity(0.08))
        }
    }
}

private struct VampAssistantApplicationError: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PR.warn)
            Text(message).font(.footnote).foregroundStyle(PR.fg)
            Spacer()
            Button("Retry", action: onRetry)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PR.fg)
        }
        .padding(14)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }
}
