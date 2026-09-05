#if canImport(UIKit)
import SwiftUI
import SharedModels
import SharedProtocol
import UIKit

/// Vamp Stream's core screen: the Mac's applications. Tap one to stream just that app's window
/// (reusing the shared video renderer + input via `MirrorScreen`). All state comes from
/// `AppStreamViewModel` — never a fake "connected" while frozen.
@available(iOS 16.1, *)
struct AppStreamBrowserView: View {
    let environment: ClientAppEnvironment
    @ObservedObject var vm: AppStreamViewModel
    @ObservedObject private var sessionCoordinator: ClientSessionCoordinator
    /// Disconnect / leave this Mac.
    var onClose: () -> Void
    @StateObject private var rendererVM: VideoRendererViewModel
    @StateObject private var input: AppStreamInputController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("vampstream.favoriteApps") private var favoriteStorage = "[]"
    @AppStorage("vampstream.recentApps") private var recentStorage = "[]"
    @AppStorage("vampstream.qualityMode") private var qualityMode = "quality"
    @AppStorage("vampstream.didShowGestureHelp") private var didShowGestureHelp = false
    @State private var searchText = ""
    @State private var windowChoice: RemoteApplication?
    @State private var closeChoice: RemoteApplication?
    @State private var showsHelp = false
    @State private var videoStalled = false
    @State private var keyboardActive = false
    @State private var keyboardOverlayBottomPad: CGFloat = 0
    @State private var adjustsViewport = false
    @State private var viewportZoom: CGFloat = 1
    @State private var viewportOffset: CGSize = .zero

    init(environment: ClientAppEnvironment, vm: AppStreamViewModel, onClose: @escaping () -> Void) {
        self.environment = environment
        self.vm = vm
        self.onClose = onClose
        self.sessionCoordinator = environment.sessionCoordinator
        _rendererVM = StateObject(
            wrappedValue: VideoRendererViewModel(webRTCSessionManager: environment.webRTCSessionManager)
        )
        _input = StateObject(
            wrappedValue: AppStreamInputController(webRTC: environment.webRTCSessionManager, onFailure: { reason in
                Task { await environment.sessionCoordinator.disconnectForInputFailure(reason) }
            })
        )
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if hostIsLocked {
                    AppStreamLockedStateView(
                        sessionCoordinator: sessionCoordinator,
                        onDisconnect: onClose
                    )
                } else {
                    switch vm.status {
                    case .streaming(_, let name):
                        streamSurface(name: name)
                    case .launching(let name):
                        launching(name: name)
                    default:
                        browser
                    }
                }
            }
            .onAppear { vm.updateClientViewport(size: proxy.size) }
            .onChangeCompat(of: proxy.size) { size in
                if case .streaming = vm.status { return }
                vm.updateClientViewport(size: size)
            }
        }
        .task {
            rendererVM.onNeedsKeyframe = { [weak sc = environment.sessionCoordinator] in
                sc?.requestKeyframeRefresh(reason: "app stream decode")
            }
            vm.start()
            if hostIsLocked {
                vm.pauseForHostLock()
            } else {
                vm.requestApplicationList()
            }
        }
        .onChangeCompat(of: vm.status) { status in
            guard !hostIsLocked else { return }
            switch status {
            case .streaming:
                resetViewportZoom()
                if !didShowGestureHelp { showsHelp = true; didShowGestureHelp = true }
            default:
                // Leaving the stream surface must release any drag-lock and stop decoding;
                // the browser can remain mounted while the app target changes.
                input.stop()
                rendererVM.stopReceiving()
            }
        }
        .onChangeCompat(of: vm.geometryRevision) { _ in
            input.isEnabled = false
            if scenePhase == .active, !hostIsLocked {
                rendererVM.startReceiving()
                sessionCoordinator.requestKeyframeRefresh(reason: "App window geometry changed")
            }
        }
        .onChangeCompat(of: canInteract) { enabled in input.isEnabled = enabled }
        .onChangeCompat(of: scenePhase) { phase in
            input.isEnabled = false
            if phase == .active, !hostIsLocked {
                vm.resumeAfterHostUnlock()
                if case .streaming = vm.status { rendererVM.startReceiving() }
            } else {
                vm.suspendInteraction()
                rendererVM.stopReceiving()
            }
        }
        .onChangeCompat(of: sessionCoordinator.hostLockState) { state in
            if state == .lockedOrLoginWindow {
                rendererVM.stopReceiving()
                input.stop()
                vm.pauseForHostLock()
            } else {
                vm.resumeAfterHostUnlock()
                if case .streaming = vm.status { rendererVM.startReceiving() }
            }
        }
        .sheet(isPresented: $showsHelp) { AppStreamGestureHelpView() }
        .confirmationDialog("Choose a window", isPresented: Binding(
            get: { windowChoice != nil }, set: { if !$0 { windowChoice = nil } }
        ), titleVisibility: .visible) {
            if let app = windowChoice {
                ForEach(Array(app.windowIDs.enumerated()), id: \.element) { index, id in
                    Button(app.windowTitles?[id] ?? "Window \(index + 1)") { open(app, windowID: id) }
                }
                Button("Open active window") { open(app) }
            }
        }
        .confirmationDialog(
            closePromptTitle,
            isPresented: Binding(
                get: { closeChoice != nil },
                set: { if !$0 { closeChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let app = closeChoice {
                Button("Close \(app.name)", role: .destructive) { vm.close(app) }
            }
            Button("Cancel", role: .cancel) { closeChoice = nil }
        } message: {
            Text("Unsaved changes on the Mac may be lost.")
        }
        .onChangeCompat(of: qualityMode) { _ in applyQuality() }
        .onDisappear {
            rendererVM.stopReceiving()
            input.stop()
            vm.stop()
        }
    }

    private var canInteract: Bool {
        scenePhase == .active && !hostIsLocked && !vm.isResizing && !vm.isGeometryChanging && !videoStalled
            && rendererVM.latestPixelBuffer != nil && rendererVM.isReceiving
    }

    private var closePromptTitle: String {
        if let closeChoice { return "Close \(closeChoice.name)?" }
        return "Close this app?"
    }

    private var macName: String { sessionCoordinator.connectedHostName ?? "My Mac" }
    private var hostIsLocked: Bool {
        sessionCoordinator.hostLockState == .lockedOrLoginWindow
    }
    private var favoriteIDs: [String] { decodeIDs(favoriteStorage) }
    private var matchingApps: [RemoteApplication] {
        vm.applications.filter { searchText.isEmpty || $0.name.localizedStandardContains(searchText) }
    }
    private var favorites: [RemoteApplication] { matchingApps.filter { favoriteIDs.contains($0.id) } }
    private var recent: [RemoteApplication] {
        decodeIDs(recentStorage).compactMap { id in matchingApps.first { $0.id == id && !favoriteIDs.contains(id) } }
    }
    private var running: [RemoteApplication] { matchingApps.filter { $0.isRunning } }
    private var installed: [RemoteApplication] { matchingApps.filter { !$0.isRunning } }
    private func decodeIDs(_ value: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
    }
    private func encodeIDs(_ value: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "[]"
    }
    private func open(_ app: RemoteApplication, windowID: String? = nil) {
        recentStorage = encodeIDs(Array(([app.id] + decodeIDs(recentStorage).filter { $0 != app.id }).prefix(10)))
        windowChoice = nil
        vm.select(app, windowID: windowID)
    }
    private func applyQuality() {
        let preset: StreamQualityPreset = qualityMode == "performance" ? .performance
            : qualityMode == "auto" ? .balanced : (environment.isUltraQualityEntitled ? .ultra : .quality)
        environment.preferredQualityPreset = preset
        sessionCoordinator.setPreferredQuality(preset)
    }

    // MARK: - Browser

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .accessibilityHint("Return to the Mac picker")
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            VampAppSearchField(text: $searchText)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let reason = bannerReason { banner(reason) }

                    if vm.applications.isEmpty {
                        loadingOrEmpty
                    } else {
                        if !favorites.isEmpty { section("Favorites", favorites) }
                        if searchText.isEmpty, !recent.isEmpty { section("Recent", recent) }
                        if matchingApps.isEmpty {
                            VampStreamAppListEmptyHint(title: "No apps match")
                        }
                        if !running.isEmpty {
                            section("Running", running)
                        }
                        if !installed.isEmpty {
                            section("All Apps", installed)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { vm.requestApplicationList() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func section(_ title: String, _ apps: [RemoteApplication]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(PR.dim)
                .padding(.horizontal, 4)
                .padding(.top, 6)
            LazyVStack(spacing: 10) {
                ForEach(apps) { appRow($0) }
            }
        }
    }

    private func appRow(_ app: RemoteApplication) -> some View {
        AppStreamApplicationRow(application: app, isFavorite: favoriteIDs.contains(app.id)) {
            if app.windowIDs.count > 1 { windowChoice = app } else { open(app) }
        }
        .contextMenu {
            Button(favoriteIDs.contains(app.id) ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: favoriteIDs.contains(app.id) ? "star.slash" : "star") {
                favoriteStorage = encodeIDs(favoriteIDs.contains(app.id)
                    ? favoriteIDs.filter { $0 != app.id } : favoriteIDs + [app.id])
            }
            if app.isRunning, ApplicationClosePolicy.canClose(app.bundleIdentifier) {
                Button("Close \(app.name)", systemImage: "xmark.app", role: .destructive) {
                    closeChoice = app
                }
            }
        }
    }

    private var bannerReason: String? {
        switch vm.status {
        case .failed(let reason), .targetLost(let reason): return reason
        default: return nil
        }
    }

    private func banner(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PR.warn)
            Text(reason).font(.footnote).foregroundStyle(PR.fg)
            Spacer()
            Button("Retry") { vm.requestApplicationList() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PR.fg)
        }
        .padding(14)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }

    @ViewBuilder private var loadingOrEmpty: some View {
        VampStreamAppListEmptyHint(
            title: vmIsLoading ? "Loading applications…" : "No applications found",
            isLoading: vmIsLoading,
            actionTitle: vmIsLoading ? nil : "Refresh",
            action: vmIsLoading ? nil : { vm.requestApplicationList() }
        )
    }

    private var vmIsLoading: Bool {
        if case .loadingApps = vm.status { return true }
        return false
    }

    // MARK: - Launching / streaming

    private func launching(name: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().tint(PR.fg).controlSize(.large)
            Text("Launching \(name)…")
                .font(.headline)
                .foregroundStyle(PR.fg)
            VampGlassActionButton(title: "Cancel", action: { vm.backToApps() })
        }
        .padding(22)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func streamSurface(name: String) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black

                if rendererVM.latestPixelBuffer != nil {
                    // The app window itself. `resizeAspect` preserves the actual window shape;
                    // StreamOrientation chooses portrait vs landscape from that same shape so a
                    // portrait app is not forced into a landscape canvas with side bars.
                    VideoFrameRendererView(
                        pixelBuffer: rendererVM.latestPixelBuffer,
                        displayMode: .fitDisplay,
                        renderer: rendererVM
                    )
                    .scaleEffect(viewportZoom, anchor: .center)
                    .offset(viewportOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Direct-touch control: uses the same gesture semantics and ordered input
                    // pipeline as Vamp Control. Coordinates map through the streamed window's
                    // synthetic display descriptor (see configureInteraction).
                    AppStreamGestureView(
                        allowsViewportAdjustment: adjustsViewport,
                        viewportZoom: viewportZoom,
                        viewportOffset: viewportOffset,
                        viewSize: proxy.size,
                        onTap: { input.tap(at: DesktopPoint(x: $0.x, y: $0.y)) },
                        onDoubleTap: { input.doubleTap(at: DesktopPoint(x: $0.x, y: $0.y)) },
                        onRightClick: { input.rightClick(at: DesktopPoint(x: $0.x, y: $0.y)) },
                        onMiddleClick: { input.middleClick(at: DesktopPoint(x: $0.x, y: $0.y)) },
                        onPointerMove: { input.pointerMoved(at: DesktopPoint(x: $0.x, y: $0.y)) },
                        onPointerEnded: { input.pointerEnded() },
                        onScroll: { dx, dy in input.scroll(deltaX: dx, deltaY: dy) },
                        onViewportPan: { delta in
                            viewportOffset = clampedViewportOffset(
                                CGSize(width: viewportOffset.width + delta.width,
                                       height: viewportOffset.height + delta.height),
                                zoom: viewportZoom,
                                in: proxy.size
                            )
                        },
                        onPinchChanged: { scale, focalPoint in
                            updateViewportZoom(scale: scale, focalPoint: focalPoint, in: proxy.size)
                        },
                        onPinchEnded: {
                            if viewportZoom < 1.15 {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                                    resetViewportZoom()
                                }
                            }
                        },
                        onLongPress: { input.toggleDragLock(at: DesktopPoint(x: $0.x, y: $0.y)) },
                        onLongPressEnded: { input.releaseDragLock() },
                        onHoverDelta: { dx, dy in input.relativePointerMove(deltaX: dx, deltaY: dy) }
                    )
                    .allowsHitTesting(!keyboardActive && canInteract)
                    if videoStalled {
                        VStack(spacing: 8) {
                            Text("Waiting for video…").font(.headline)
                            Button("Retry video") { sessionCoordinator.requestKeyframeRefresh(reason: "Stalled app stream") }
                                .buttonStyle(.borderedProminent)
                        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Opening \(name)…")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            }
            .overlay(alignment: .bottom) {
                if let notice = vm.sizingNotice, !keyboardActive {
                    Text(notice).font(.caption).padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 12).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if keyboardActive {
                    AppStreamKeyboardOverlayView(
                        mode: isStreamingTerminal ? .terminal : .standard,
                        onText: { input.sendText($0) },
                        onKey: { keyCode, modifiers in input.pressKey(keyCode, modifiers: modifiers) },
                        onDismiss: { keyboardActive = false }
                    )
                    .allowsHitTesting(canInteract)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, keyboardOverlayBottomPad)
                }
            }
            .task {
                while !Task.isCancelled {
                    videoStalled = rendererVM.lastDecodedAt.map { ProcessInfo.processInfo.systemUptime - $0 > 5 } ?? true
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
            .onAppear {
                configureInteraction(viewSize: proxy.size)
                vm.updateClientViewport(size: proxy.size)
            }
            .onChangeCompat(of: proxy.size) { newSize in
                configureInteraction(viewSize: newSize)
                if !keyboardActive { vm.updateClientViewport(size: newSize) }
                resetViewportZoom()
            }
            .onChangeCompat(of: vm.streamedWindow) { _ in
                configureInteraction(viewSize: proxy.size)
                resetViewportZoom()
            }
            .background(AppStreamKeyboardInsetReader { inset in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { keyboardOverlayBottomPad = inset }
            })

        }
        .safeAreaInset(edge: .top, spacing: 0) {
            streamTopBar(name: name).background(.black.opacity(0.28))
        }
        .ignoresSafeArea(edges: [.horizontal, .bottom])
    }

    private func streamTopBar(name: String) -> some View {
        HStack(spacing: 10) {
            Button { vm.backToApps() } label: {
                Label("Apps", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to apps")
            .accessibilityHint("Stop streaming and return to the Mac app list")
            Spacer()
            Text(adjustsViewport ? "Adjust view" : name)
                .lineLimit(1)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            if viewportZoom > 1.05 {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                        resetViewportZoom()
                    }
                } label: {
                    Text("1×")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset zoom")
                .accessibilityValue("Currently zoomed to \(Int(viewportZoom * 100)) percent")
            }
            Button {
                if input.dragLocked { input.releaseDragLock() }
                adjustsViewport.toggle()
            } label: {
                Image(systemName: adjustsViewport ? "checkmark" : "viewfinder")
                    .frame(minWidth: 44, minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel(adjustsViewport ? "Done adjusting" : "Adjust view")
            .accessibilityHint("Switch between controlling the Mac and moving or zooming the picture")
            Menu {
                Button("Adaptive") { vm.setSizingMode(.adaptive) }
                Button("Original Size") { vm.setSizingMode(.original) }
                Picker("Quality", selection: $qualityMode) {
                    Text("Auto").tag("auto")
                    Text("Sharper text").tag("quality")
                    Text("Lower bandwidth").tag("performance")
                }
                if let streamed = vm.streamedApplication,
                   ApplicationClosePolicy.canClose(streamed.bundleIdentifier) {
                    Button("Close \(streamed.name)", systemImage: "xmark.app", role: .destructive) {
                        closeChoice = streamed
                    }
                }
                Button("Gesture help", systemImage: "hand.draw") { showsHelp = true }
                if input.dragLocked {
                    Button("Release drag lock", systemImage: "lock.open") { input.releaseDragLock() }
                }
                Button("Refresh video", systemImage: "arrow.clockwise") {
                    sessionCoordinator.requestKeyframeRefresh(reason: "User requested video refresh")
                }
                Button("Reconnect", systemImage: "wifi") { Task { await sessionCoordinator.reconnectLast() } }
            } label: {
                Image(systemName: input.dragLocked ? "lock.fill" : "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(input.dragLocked ? "Stream options, drag lock on" : "Stream options")
            Button {
                if !keyboardActive, isStreamingTerminal { input.focusTerminal() }
                keyboardActive.toggle()
            } label: {
                Image(systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(keyboardActive ? "Hide keyboard" : "Show keyboard")
            .accessibilityHint("Type into the streamed Mac app")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var isStreamingTerminal: Bool {
        guard let application = vm.streamedApplication else { return false }
        return AppStreamApplicationProfile.isTerminal(
            bundleIdentifier: application.bundleIdentifier,
            name: application.name)
    }

    private func configureInteraction(viewSize: CGSize) {
        input.sessionID = environment.sessionCoordinator.activeSessionID
        input.isEnabled = canInteract
        if let window = vm.streamedWindow {
            input.setWindow(DisplayDescriptor(
                id: window.windowID,
                name: "window",
                frame: DesktopRect(
                    origin: DesktopPoint(x: 0, y: 0),
                    size: DesktopSize(width: window.pointWidth, height: window.pointHeight)
                ),
                pixelSize: DesktopSize(width: window.pointWidth * window.scale, height: window.pointHeight * window.scale),
                scaleFactor: window.scale,
                isPrimary: true,
                isActive: true
            ))
        }
        input.setViewSize(DesktopSize(width: viewSize.width, height: viewSize.height))
    }

    private func updateViewportZoom(scale: CGFloat, focalPoint: CGPoint, in viewSize: CGSize) {
        let oldZoom = viewportZoom
        let newZoom = min(max(viewportZoom * scale, 1), 5)
        viewportZoom = newZoom
        guard newZoom > 1 else {
            viewportOffset = .zero
            return
        }

        let ratio = newZoom / max(oldZoom, 0.001)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let anchored = CGSize(
            width: viewportOffset.width + (1 - ratio) * (focalPoint.x - center.x - viewportOffset.width),
            height: viewportOffset.height + (1 - ratio) * (focalPoint.y - center.y - viewportOffset.height)
        )
        viewportOffset = clampedViewportOffset(anchored, zoom: newZoom, in: viewSize)
    }

    private func resetViewportZoom() {
        viewportZoom = 1
        viewportOffset = .zero
    }

    private func clampedViewportOffset(_ proposed: CGSize, zoom: CGFloat, in viewSize: CGSize) -> CGSize {
        guard zoom > 1, let window = vm.streamedWindow,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }

        let streamAspect = window.pointWidth / max(window.pointHeight, 1)
        let viewAspect = viewSize.width / viewSize.height
        let contentSize: CGSize
        if streamAspect > viewAspect {
            contentSize = CGSize(width: viewSize.width, height: viewSize.width / streamAspect)
        } else {
            contentSize = CGSize(width: viewSize.height * streamAspect, height: viewSize.height)
        }
        let content = CGRect(
            x: (viewSize.width - contentSize.width) / 2,
            y: (viewSize.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        func clamp(_ value: CGFloat, min edgeMin: CGFloat, max edgeMax: CGFloat, viewport: CGFloat, center: CGFloat) -> CGFloat {
            let scaledMin = center + (edgeMin - center) * zoom
            let scaledMax = center + (edgeMax - center) * zoom
            if scaledMax - scaledMin <= viewport {
                return viewport / 2 - (scaledMin + scaledMax) / 2
            }
            return min(max(value, viewport - scaledMax), -scaledMin)
        }

        return CGSize(
            width: clamp(proposed.width, min: content.minX, max: content.maxX, viewport: viewSize.width, center: center.x),
            height: clamp(proposed.height, min: content.minY, max: content.maxY, viewport: viewSize.height, center: center.y)
        )
    }
}

/// Keeps a locked host attached and offers the same authenticated Remote Unlock path as
/// Vamp Control. The password is cleared before it is sent and is never retained by this view.
@available(iOS 16.1, *)
private struct AppStreamLockedStateView: View {
    @ObservedObject var sessionCoordinator: ClientSessionCoordinator
    let onDisconnect: () -> Void

    @State private var password = ""
    @State private var isSubmitting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(PR.accent)

                Text("Mac is locked")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PR.fg)

                Text("Enter your Mac login password to unlock remotely. Vamp Stream will load your applications when the Mac unlocks.")
                    .font(.subheadline)
                    .foregroundStyle(PR.fg2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .privacySensitive()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .foregroundStyle(PR.fg)
                    .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
                    .frame(maxWidth: 340)
                    .onSubmit(submitUnlock)
                    .accessibilityLabel("Mac login password")

                Button(action: submitUnlock) {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(PR.bg)
                        }
                        Text(isSubmitting ? "Unlocking…" : "Unlock")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PR.bg)
                    .frame(maxWidth: 312)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(PR.fg)
                    )
                }
                .buttonStyle(PRGlassPressButtonStyle())
                .disabled(password.isEmpty || isSubmitting)
                .opacity(password.isEmpty || isSubmitting ? 0.4 : 1)

                Text("Remote Unlock must be enabled in Vamp Sync or Vamp Host.")
                    .font(.caption)
                    .foregroundStyle(PR.dim)

                HStack(spacing: 12) {
                    Button("Check connection") {
                        sessionCoordinator.sendConnectionProbe()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .prGlassSurface(
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                        isInteractive: true
                    )
                    .buttonStyle(PRGlassPressButtonStyle())

                    Button("Disconnect", action: onDisconnect)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PR.fg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .prGlassSurface(
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                            isInteractive: true
                        )
                        .buttonStyle(PRGlassPressButtonStyle())
                }
                .frame(maxWidth: 340)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
    }

    private func submitUnlock() {
        guard !password.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        let submittedPassword = password
        password = ""
        sessionCoordinator.sendUnlockPassword(submittedPassword)

        // A failed password intentionally produces no detailed authentication response. Re-enable
        // the form after a short delay so another attempt is possible while the Mac remains locked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            isSubmitting = false
        }
    }
}
private struct AppStreamApplicationRow: View {
    let application: RemoteApplication
    let isFavorite: Bool
    let onOpen: () -> Void
    @State private var icon: UIImage?
    private static let icons = NSCache<NSString, UIImage>()
    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 13) {
                Group {
                    if let icon { Image(uiImage: icon).resizable() }
                    else { Image(systemName: "app.dashed").resizable() }
                }.frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name).font(.body.weight(.semibold)).foregroundStyle(PR.fg)
                    Text(application.isActive ? "Active now" : application.isRunning ? "Running" : "Installed")
                        .font(.caption).foregroundStyle(PR.fg2)
                }
                Spacer()
                if isFavorite { Image(systemName: "star.fill").foregroundStyle(PR.accent) }
                Image(systemName: "chevron.right").foregroundStyle(PR.dim)
            }.padding(14).frame(maxWidth: .infinity, minHeight: 60)
                .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous), isInteractive: true)
        }.buttonStyle(PRGlassPressButtonStyle())
        .accessibilityLabel(application.name)
        .accessibilityHint("Open app. More actions include Favorites.")
        .task(id: application.iconPNGBase64) {
            guard let encoded = application.iconPNGBase64 else { icon = nil; return }
            let key = (application.id + String(encoded.hashValue)) as NSString
            Self.icons.countLimit = 256
            if let cached = Self.icons.object(forKey: key) { icon = cached; return }
            guard let data = Data(base64Encoded: encoded), let decoded = UIImage(data: data) else { return }
            Self.icons.setObject(decoded, forKey: key)
            icon = decoded
        }
    }
}

struct AppStreamGestureHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Label("Tap to click; double-tap to double-click.", systemImage: "hand.tap")
                Label("Tap with two fingers to right-click.", systemImage: "hand.point.up.left")
                Label("Move two fingers to scroll.", systemImage: "arrow.up.arrow.down")
                Label("Choose Adjust view to pinch and pan the picture, then Done adjusting to control the Mac. Use 1× to reset.", systemImage: "plus.magnifyingglass")
                Label("Long-press and move to drag. Lift your finger to release.", systemImage: "lock.open")
                Label("Use the keyboard button to type into the Mac app.", systemImage: "keyboard")
            }.navigationTitle("Stream controls")
                .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct AppStreamKeyboardInsetReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void
    func makeUIView(context: Context) -> KeyboardInsetView {
        let view = KeyboardInsetView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }
    func updateUIView(_ view: KeyboardInsetView, context: Context) { view.onChange = onChange }
}

final class KeyboardInsetView: UIView {
    var onChange: ((CGFloat) -> Void)?
    private var lastInset: CGFloat = -1
    override func layoutSubviews() {
        super.layoutSubviews()
        // The guide belongs to this view, so split-screen and external-display
        // coordinates never need to be converted from a global screen.
        let occlusion = max(0, bounds.maxY - keyboardLayoutGuide.layoutFrame.minY)
        let inset = occlusion > safeAreaInsets.bottom + 1 ? occlusion : 0
        guard abs(inset - lastInset) > 0.5 else { return }
        lastInset = inset
        DispatchQueue.main.async { [weak self] in self?.onChange?(inset) }
    }
}
#endif
