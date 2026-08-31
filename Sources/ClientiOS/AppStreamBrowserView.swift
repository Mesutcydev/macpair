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
    @State private var keyboardActive = false
    @State private var keyboardOverlayBottomPad: CGFloat = 0
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
            wrappedValue: AppStreamInputController(webRTC: environment.webRTCSessionManager)
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
            .onChangeCompat(of: proxy.size) { vm.updateClientViewport(size: $0) }
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
                rendererVM.startReceiving()
            default:
                // Leaving the stream surface must release any drag-lock and stop decoding;
                // the browser can remain mounted while the app target changes.
                input.stop()
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
        .onDisappear {
            rendererVM.stopReceiving()
            input.stop()
            vm.stop()
        }
    }

    private var macName: String { sessionCoordinator.connectedHostName ?? "My Mac" }
    private var hostIsLocked: Bool {
        sessionCoordinator.hostLockState == .lockedOrLoginWindow
    }
    private var running: [RemoteApplication] { vm.applications.filter { $0.isRunning } }
    private var installed: [RemoteApplication] { vm.applications.filter { !$0.isRunning } }

    // MARK: - Browser

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apps")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(PR.fg)
                    Text(macName)
                        .font(.subheadline)
                        .foregroundStyle(PR.fg2)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(PR.fg2)
                        .padding(10)
                        .prGlassSurface(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close host")
                .accessibilityHint("Return to the Vamp Host picker")
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    if let reason = bannerReason { banner(reason) }

                    if vm.applications.isEmpty {
                        loadingOrEmpty
                    } else {
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
            VStack(spacing: 10) {
                ForEach(apps) { appRow($0) }
            }
        }
    }

    private func appRow(_ app: RemoteApplication) -> some View {
        Button {
            vm.select(app)
        } label: {
            HStack(spacing: 13) {
                icon(for: app)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(PR.fg)
                    if app.isActive {
                        Text("Active now").font(.caption2).foregroundStyle(PR.accent)
                    } else if app.isRunning {
                        Text("Running").font(.caption2).foregroundStyle(PR.fg2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PR.dim)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name)
        .accessibilityValue(app.isActive ? "Active now" : (app.isRunning ? "Running" : "Installed"))
        .accessibilityHint("Open this Mac app in Vamp Stream")
    }

    private func icon(for app: RemoteApplication) -> Image {
        if let base64 = app.iconPNGBase64,
           let data = Data(base64Encoded: base64),
           let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "app.dashed")
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
        }
        .padding(14)
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }

    @ViewBuilder private var loadingOrEmpty: some View {
        VStack(spacing: 12) {
            if vmIsLoading {
                ProgressView().padding(.top, 50)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(PR.accent)
            }
            Text(vmIsLoading ? "Loading applications…" : "No applications found.")
                .font(.subheadline).foregroundStyle(PR.fg2)
            if !vmIsLoading {
                Button("Refresh") { vm.requestApplicationList() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var vmIsLoading: Bool {
        if case .loadingApps = vm.status { return true }
        return false
    }

    // MARK: - Launching / streaming

    private func launching(name: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Launching \(name)…").font(.headline).foregroundStyle(PR.fg)
            Button("Cancel") { vm.backToApps() }.padding(.top, 4)
        }
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
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                    resetViewportZoom()
                                }
                            }
                        },
                        onLongPress: { input.toggleDragLock(at: DesktopPoint(x: $0.x, y: $0.y)) },
                        onHoverDelta: { dx, dy in input.relativePointerMove(deltaX: dx, deltaY: dy) }
                    )
                    .allowsHitTesting(!keyboardActive)
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
            .safeAreaInset(edge: .top, spacing: 0) {
                streamTopBar(name: name)
                    .background(.black.opacity(0.28))
            }
            .overlay(alignment: .bottom) {
                if keyboardActive {
                    AppStreamKeyboardOverlayView(
                        mode: isStreamingTerminal ? .terminal : .standard,
                        onText: { input.sendText($0) },
                        onKey: { keyCode, modifiers in input.pressKey(keyCode, modifiers: modifiers) },
                        onDismiss: { keyboardActive = false }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, keyboardOverlayBottomPad)
                }
            }
            .onAppear {
                configureInteraction(viewSize: proxy.size)
                vm.updateClientViewport(size: proxy.size)
            }
            .onChangeCompat(of: proxy.size) { newSize in
                configureInteraction(viewSize: newSize)
                vm.updateClientViewport(size: newSize)
                resetViewportZoom()
            }
            .onChangeCompat(of: vm.streamedWindow) { _ in
                configureInteraction(viewSize: proxy.size)
                resetViewportZoom()
            }
#if canImport(UIKit) && !os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillChangeFrameNotification)) { notification in
                guard let end = notification.userInfo?[UIApplication.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screenHeight = UIScreen.main.bounds.height
                withAnimation(.easeOut(duration: 0.25)) {
                    keyboardOverlayBottomPad = max(0, screenHeight - end.origin.y)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    keyboardOverlayBottomPad = 0
                }
            }
#endif
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
            Text(name)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            if viewportZoom > 1.05 {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
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
                                .tint(.white)
                        }
                        Text(isSubmitting ? "Unlocking…" : "Unlock")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: 312)
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty || isSubmitting)

                Text("Remote Unlock must be enabled in Vamp Host.")
                    .font(.caption)
                    .foregroundStyle(PR.dim)

                HStack(spacing: 12) {
                    Button("Check connection") {
                        sessionCoordinator.sendConnectionProbe()
                    }
                    .buttonStyle(.bordered)

                    Button("Disconnect", action: onDisconnect)
                        .buttonStyle(.bordered)
                }
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
#endif
