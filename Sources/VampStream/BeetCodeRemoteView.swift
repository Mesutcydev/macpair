import Combine
import CoreGraphics
import SwiftUI
import SharedModels

#if canImport(UIKit)
import UIKit

/// Full-screen Vamp Assistant control surface. Unlike Vamp app streaming, Vamp Assistant exposes the Mac
/// display as one H.264/JPEG surface and accepts its own authenticated HTTP input commands.
struct BeetCodeRemoteView: View {
    let session: BeetCodeRemoteSessionViewModel.Session
    let onClose: () -> Void
    let onRefresh: () async -> String?

    @StateObject private var renderer: BeetCodeVideoRendererViewModel
    @StateObject private var input: BeetCodeRemoteInputController
    @State private var keyboardActive = false
    @State private var keyboardOverlayBottomPad: CGFloat = 0
    @State private var viewportZoom: CGFloat = 1
    @State private var viewportOffset: CGSize = .zero
    @State private var isRefreshing = false
    @State private var refreshError: String?

    init(
        session: BeetCodeRemoteSessionViewModel.Session,
        onClose: @escaping () -> Void,
        onRefresh: @escaping () async -> String?
    ) {
        self.session = session
        self.onClose = onClose
        self.onRefresh = onRefresh
        _renderer = StateObject(wrappedValue: BeetCodeVideoRendererViewModel())
        _input = StateObject(wrappedValue: BeetCodeRemoteInputController(client: session.client))
    }

    var body: some View {
        Group {
            if session.status.ready {
                streamSurface
            } else {
                permissionState
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: "\(session.address)-\(session.status.ready)") {
            guard session.status.ready else { return }
            renderer.start(client: session.client)
        }
        .onDisappear {
            renderer.stop()
            input.stop()
        }
    }

    private var permissionState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.orange)
            Text("Mac Control is not ready")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(permissionMessage)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Text("On the Mac, open Vamp Assistant → Settings → Permissions. Vamp Stream cannot grant these permissions remotely.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.56))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            if let refreshError {
                Text(refreshError)
                    .font(.footnote)
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }
            Button {
                Task {
                    isRefreshing = true
                    refreshError = await onRefresh()
                    isRefreshing = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isRefreshing { ProgressView().tint(.white) }
                    Text(isRefreshing ? "Checking…" : "Check again")
                }
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(isRefreshing)
            .accessibilityLabel(isRefreshing ? "Checking Vamp Assistant permissions" : "Check Vamp Assistant permissions again")
            Button("Back", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.top, 6)
                .accessibilityHint("Return to the host picker")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionMessage: String {
        if !session.status.enabled { return "Mac Control is turned off in Vamp Assistant." }
        if !session.status.screenRecording { return "Screen Recording permission is required to receive the Mac display." }
        if !session.status.accessibility { return "Accessibility permission is required to send pointer and keyboard input." }
        return session.status.message ?? "Vamp Assistant is still preparing Mac Control."
    }

    private var streamSurface: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black

                if renderer.latestPixelBuffer != nil {
                    VideoFrameRendererView(
                        pixelBuffer: renderer.latestPixelBuffer,
                        displayMode: .fitDisplay)
                        .scaleEffect(viewportZoom, anchor: .center)
                        .offset(viewportOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    AppStreamGestureView(
                        viewportZoom: viewportZoom,
                        viewportOffset: viewportOffset,
                        viewSize: proxy.size,
                        onTap: { input.tap(at: $0) },
                        onDoubleTap: { input.doubleTap(at: $0) },
                        onRightClick: { input.rightClick(at: $0) },
                        onMiddleClick: { input.middleClick(at: $0) },
                        onPointerMove: { input.pointerMoved(at: $0) },
                        onPointerEnded: { input.pointerEnded() },
                        onScroll: { input.scroll(deltaX: $0, deltaY: $1) },
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
                        onLongPress: { input.toggleDragLock(at: $0) },
                        onHoverDelta: { input.relativePointerMove(deltaX: $0, deltaY: $1) }
                    )
                    .allowsHitTesting(!keyboardActive)
                } else {
                    VStack(spacing: 12) {
                        if let error = renderer.lastError {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 34, weight: .light))
                            Text("Vamp Assistant stream stopped")
                                .font(.headline)
                            Text(error)
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.72))
                            Button("Reconnect") {
                                renderer.start(client: session.client)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        } else {
                            ProgressView().tint(.white)
                            Text("Opening \(session.displayName)…")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.84))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(28)
                }

                if let inputError = input.lastError {
                    Text(inputError)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.82), in: Capsule())
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .accessibilityLabel("Input error: \(inputError)")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar
                    .background(.black.opacity(0.28))
            }
            .overlay(alignment: .bottom) {
                if keyboardActive {
                    AppStreamKeyboardOverlayView(
                        onText: { input.sendText($0) },
                        onKey: { keyCode, modifiers in
                            input.sendKey(keyName(for: keyCode), modifiers: modifierNames(for: modifiers))
                        },
                        onDismiss: { keyboardActive = false }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, keyboardOverlayBottomPad)
                }
            }
            .onAppear { configureInput(viewSize: proxy.size) }
            .onChangeCompat(of: proxy.size) {
                configureInput(viewSize: $0)
                resetViewportZoom()
            }
            .onChangeCompat(of: renderer.geometry) { _ in
                configureInput(viewSize: proxy.size)
                resetViewportZoom()
            }
#if canImport(UIKit) && !os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillChangeFrameNotification)) { notification in
                guard let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
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

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Label("Hosts", systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to hosts")

            Spacer()

            Text("Vamp Assistant")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button { keyboardActive.toggle() } label: {
                Image(systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(keyboardActive ? "Hide keyboard" : "Show keyboard")
            .accessibilityHint("Type into the Mac through the on-screen keyboard")

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func configureInput(viewSize: CGSize) {
        input.setGeometry(renderer.geometry)
        input.setViewSize(viewSize)
    }

    private func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        default: return "key\(keyCode)"
        }
    }

    private func modifierNames(for flags: KeyboardModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.function) { names.append("function") }
        return names
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
        guard zoom > 1, let geometry = renderer.geometry,
              geometry.imageWidth > 0, geometry.imageHeight > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }

        let streamAspect = CGFloat(geometry.imageWidth) / CGFloat(geometry.imageHeight)
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

/// Vamp Assistant's coordinate contract is global display points, while the iPhone gesture surface is
/// a letterboxed video. This mapper matches the host's aspect-fit policy and ignores letterbox
/// taps for clicks while clamping pointer movement to the nearest display edge.
@MainActor
final class BeetCodeRemoteInputController: ObservableObject {
    private let client: BeetCodeRemoteClient
    private var geometry: BeetCodeDisplayGeometry?
    private var viewSize: CGSize = .zero
    private var pendingMove: BeetCodeInputCommand?
    private var pendingScrollDX = 0.0
    private var pendingScrollDY = 0.0
    private var hasPendingScroll = false
    private var sendTail: Task<Void, Never>?
    private var flushLink: CADisplayLink?
    @Published private(set) var lastError: String?
    private(set) var dragLocked = false

    init(client: BeetCodeRemoteClient) {
        self.client = client
    }

    deinit {
        flushLink?.invalidate()
        sendTail?.cancel()
    }

    func setGeometry(_ geometry: BeetCodeDisplayGeometry?) { self.geometry = geometry }
    func setViewSize(_ size: CGSize) { viewSize = size }

    func tap(at point: CGPoint) {
        guard let mapped = map(point, clamp: false) else { return }
        route(.click(x: mapped.x, y: mapped.y, button: "left", count: 1))
    }

    func doubleTap(at point: CGPoint) {
        guard let mapped = map(point, clamp: false) else { return }
        route(.click(x: mapped.x, y: mapped.y, button: "left", count: 2))
    }

    func rightClick(at point: CGPoint) {
        guard let mapped = map(point, clamp: false) else { return }
        route(.click(x: mapped.x, y: mapped.y, button: "right", count: 1))
    }

    func middleClick(at point: CGPoint) {
        guard let mapped = map(point, clamp: false) else { return }
        route(.click(x: mapped.x, y: mapped.y, button: "middle", count: 1))
    }

    func pointerMoved(at point: CGPoint) {
        guard let mapped = map(point, clamp: true) else { return }
        route(.move(x: mapped.x, y: mapped.y))
    }

    func pointerEnded() { flush() }

    func toggleDragLock(at point: CGPoint) {
        guard let mapped = map(point, clamp: true) else { return }
        route(.move(x: mapped.x, y: mapped.y))
        route(dragLocked ? .up(button: "left") : .down(button: "left"))
        dragLocked.toggle()
    }

    func scroll(deltaX: Double, deltaY: Double) {
        guard let geometry, let rect = contentRect(for: geometry) else { return }
        let scaled = (
            dx: deltaX * geometry.displayWidth / max(rect.width, 1),
            dy: deltaY * geometry.displayHeight / max(rect.height, 1))
        pendingScrollDX += scaled.dx
        pendingScrollDY += scaled.dy
        hasPendingScroll = true
        ensureFlushLink()
    }

    func relativePointerMove(deltaX: Double, deltaY: Double) {
        guard let geometry, let rect = contentRect(for: geometry) else { return }
        let scale = max(geometry.displayWidth / max(rect.width, 1), geometry.displayHeight / max(rect.height, 1))
        let speed = hypot(deltaX * scale, deltaY * scale)
        let acceleration = 1.0 + min(speed / 50.0, 1.5)
        route(.relative(dx: deltaX * scale * acceleration, dy: deltaY * scale * acceleration))
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        route(.type(text))
    }

    func sendKey(_ key: String, modifiers: [String] = []) {
        route(.key(key, modifiers: modifiers))
    }

    func stop() {
        sendTail?.cancel()
        sendTail = nil
        flushLink?.invalidate()
        flushLink = nil
        if dragLocked {
            enqueue(.up(button: "left"))
            dragLocked = false
        }
        pendingMove = nil
        pendingScrollDX = 0
        pendingScrollDY = 0
        hasPendingScroll = false
        lastError = nil
    }

    private func map(_ point: CGPoint, clamp: Bool) -> CGPoint? {
        guard let geometry, let rect = contentRect(for: geometry), rect.width > 0, rect.height > 0 else { return nil }
        let clamped = CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY))
        guard clamp || rect.contains(point) else { return nil }
        let nx = (clamped.x - rect.minX) / rect.width
        let ny = (clamped.y - rect.minY) / rect.height
        return CGPoint(
            x: geometry.displayX + nx * geometry.displayWidth,
            y: geometry.displayY + ny * geometry.displayHeight)
    }

    private func contentRect(for geometry: BeetCodeDisplayGeometry) -> CGRect? {
        guard geometry.imageWidth > 0, geometry.imageHeight > 0,
              viewSize.width > 0, viewSize.height > 0 else { return nil }
        let imageAspect = CGFloat(geometry.imageWidth) / CGFloat(geometry.imageHeight)
        let viewAspect = viewSize.width / viewSize.height
        let size: CGSize
        if imageAspect > viewAspect {
            size = CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
        } else {
            size = CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
        }
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height)
    }

    private func route(_ command: BeetCodeInputCommand) {
        switch command {
        case .move:
            pendingMove = command
            ensureFlushLink()
        case .relative:
            flushMove()
            enqueue(command)
        case .scroll:
            flushMove()
            enqueueScrollIfNeeded()
        default:
            flush()
            enqueue(command)
        }
    }

    private func flush() {
        flushMove()
        enqueueScrollIfNeeded()
        if pendingMove == nil, !hasPendingScroll {
            flushLink?.invalidate()
            flushLink = nil
        }
    }

    private func flushMove() {
        guard let pendingMove else { return }
        enqueue(pendingMove)
        self.pendingMove = nil
    }

    private func enqueueScrollIfNeeded() {
        guard hasPendingScroll else { return }
        enqueue(.scroll(x: nil, y: nil, dx: pendingScrollDX, dy: pendingScrollDY))
        pendingScrollDX = 0
        pendingScrollDY = 0
        hasPendingScroll = false
    }

    private func ensureFlushLink() {
        guard flushLink == nil else { return }
        let link = CADisplayLink(
            target: BeetCodeDisplayLinkProxy { [weak self] in self?.flush() },
            selector: #selector(BeetCodeDisplayLinkProxy.tick)
        )
        link.add(to: .main, forMode: .common)
        flushLink = link
    }

    private func enqueue(_ command: BeetCodeInputCommand) {
        let previous = sendTail
        sendTail = Task { [client, weak self] in
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            do {
                _ = try await client.sendControlBatch([command])
                self?.lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.lastError = error.localizedDescription
            }
        }
    }
}

private final class BeetCodeDisplayLinkProxy {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func tick() {
        handler()
    }
}
#endif
