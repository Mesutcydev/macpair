import SwiftUI
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
    @State private var viewportAspect = 9.0 / 19.5

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let selectedApplication {
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
                        onChooseApplication: { self.selectedApplication = nil },
                        onViewportAspectChange: updateViewportAspect)
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
                        onSelect: { application in Task { await open(application) } })
                }
            }
            .tint(PR.accent)
            .onAppear { updateViewport(proxy.size) }
            .onChangeCompat(of: proxy.size) { updateViewport($0) }
            .task(id: resizeTaskID) {
                guard let windowID = selectedApplication?.windowID else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                do {
                    selectedApplication = try await session.client.resizeApplication(
                        windowID: windowID,
                        clientViewportAspect: viewportAspect)
                } catch {
                    errorMessage = "The Mac kept the closest window size: \(error.localizedDescription)"
                }
            }
            .task(id: session.address) {
                if runningApplications.isEmpty, installedApplications.isEmpty {
                    await loadApplications()
                }
            }
        }
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

    private func updateViewportAspect(_ aspect: Double) {
        guard aspect.isFinite, (0.25...4).contains(aspect),
              abs(aspect - viewportAspect) > 0.025 else { return }
        viewportAspect = aspect
    }

    private func loadApplications() async {
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

    private func open(_ application: BeetCodeRemoteApplication) async {
        guard launchingName == nil else { return }
        if application.isRunning, let windowID = application.windowID {
            do {
                selectedApplication = try await session.client.resizeApplication(
                    windowID: windowID,
                    clientViewportAspect: viewportAspect)
            } catch {
                selectedApplication = application
                errorMessage = "The Mac kept the closest window size: \(error.localizedDescription)"
            }
            return
        }
        guard let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty else {
            errorMessage = "That Mac application does not expose a launch identifier."
            return
        }
        launchingName = application.name
        errorMessage = nil
        defer { launchingName = nil }
        do {
            let launched = try await session.client.launchApplication(
                bundleIdentifier: bundleIdentifier,
                clientViewportAspect: viewportAspect)
            selectedApplication = try await resolvedApplication(
                launched,
                bundleIdentifier: bundleIdentifier)
            apply(try await session.client.applications())
        } catch {
            // Some apps return from their launch endpoint while a welcome panel, document
            // chooser, or first window is still being created. The apps endpoint sees that
            // window shortly afterwards, so recover here instead of making the user tap again.
            if let recovered = await waitForWindow(bundleIdentifier: bundleIdentifier) {
                selectedApplication = recovered
                await loadApplications()
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resolvedApplication(
        _ application: BeetCodeRemoteApplication,
        bundleIdentifier: String
    ) async throws -> BeetCodeRemoteApplication {
        if application.windowID != nil { return application }
        if let recovered = await waitForWindow(bundleIdentifier: bundleIdentifier) {
            return recovered
        }
        return application
    }

    private func waitForWindow(bundleIdentifier: String) async -> BeetCodeRemoteApplication? {
        for _ in 0..<16 {
            guard !Task.isCancelled else { return nil }
            if let applications = try? await session.client.applications(),
               let application = applications.first(where: {
                   $0.bundleIdentifier == bundleIdentifier && $0.windowID != nil
               }) {
                return (try? await session.client.resizeApplication(
                    windowID: application.windowID!,
                    clientViewportAspect: viewportAspect)) ?? application
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VampAssistantApplicationHeader(macName: macName, onClose: onClose)
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
                        VampAssistantApplicationsEmptyState(isLoading: isLoading, onRefresh: onRefresh)
                    } else {
                        if !runningApplications.isEmpty {
                            VampAssistantApplicationSection(
                                title: "Running",
                                applications: runningApplications,
                                isDisabled: launchingName != nil,
                                onSelect: onSelect)
                        }
                        if !installedApplications.isEmpty {
                            VampAssistantApplicationSection(
                                title: "All Apps",
                                applications: installedApplications,
                                isDisabled: launchingName != nil,
                                onSelect: onSelect)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .refreshable { onRefresh() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PRAppBackground().ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

private struct VampAssistantApplicationHeader: View {
    let macName: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apps").font(.largeTitle.weight(.bold)).foregroundStyle(PR.fg)
                Text(macName).font(.subheadline).foregroundStyle(PR.fg2)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(PR.fg2)
                    .frame(width: 40, height: 40)
                    .prGlassSurface(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close host")
            .accessibilityHint("Return to the Vamp Assistant picker")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }
}

private struct VampAssistantApplicationSection: View {
    let title: LocalizedStringKey
    let applications: [BeetCodeRemoteApplication]
    let isDisabled: Bool
    let onSelect: (BeetCodeRemoteApplication) -> Void

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
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
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
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
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
            Button("Retry", action: onRetry).font(.footnote.weight(.semibold))
        }
        .padding(14)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }
}

private struct VampAssistantApplicationsEmptyState: View {
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView().padding(.top, 50)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(PR.fg2)
            }
            Text(isLoading ? "Loading applications…" : "No applications found")
                .font(.subheadline)
                .foregroundStyle(PR.fg2)
            if !isLoading {
                Button("Refresh", action: onRefresh).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
