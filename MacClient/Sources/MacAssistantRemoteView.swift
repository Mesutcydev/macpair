import AppKit
import Combine
import CoreImage
import SwiftUI
import SharedModels
import SharedUtilities
import UniformTypeIdentifiers

/// Vamp Assistant uses its private HTTP transport behind the same window chrome and
/// AppKit event surface as a normal Vamp Control session. Transport differences must
/// never create a second, reduced remote-control interface.
struct MacAssistantRemoteView: View {
    @ObservedObject var model: MacAssistantSession
    @StateObject private var renderer = BeetCodeVideoRendererViewModel()
    @StateObject private var input: MacAssistantInputController
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var selectedDisplayID: UInt32?
    @State private var fullControl = true
    @State private var showsStats = true
    @State private var sessionToast: String?
    @State private var sessionToastIsError = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @AppStorage("client.displayMode") private var displayModeRaw = DisplayMappingEngine.DisplayMode.fitDisplay.rawValue

    init(model: MacAssistantSession) {
        self.model = model
        _input = StateObject(
            wrappedValue: MacAssistantInputController(client: model.connected?.client)
        )
    }

    /// Vamp Assistant streams at whatever resolution the client asks for. The
    /// renderer's shared default is 1080p, which was sized for a phone and left
    /// every Retina Mac looking soft; Vamp Stream already moved this path to
    /// native. A Mac decodes native comfortably, so ask for it here too.
    private static let streamResolution = "native"

    private var displayMode: DisplayMappingEngine.DisplayMode {
        DisplayMappingEngine.DisplayMode(rawValue: displayModeRaw) ?? .fitDisplay
    }

    var body: some View {
        Group {
            if let session = model.connected {
                if session.status.ready {
                    stream(session)
                } else {
                    permissionState(session)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .onDisappear {
            renderer.stop()
            input.stop()
        }
    }

    private func stream(_ session: MacAssistantSession.ConnectedSession) -> some View {
        ZStack {
            MacAssistantVideoStreamView(
                renderer: renderer,
                input: input,
                isInputEnabled: fullControl,
                usesLocalCursor: session.status.supportsCursorlessCapture == true,
                displayMode: displayMode)
                .ignoresSafeArea()
                .accessibilityLabel("Remote control surface for \(session.displayName)")

            if renderer.latestPixelBuffer == nil {
                streamStatus(session)
            }

            if let error = input.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.red.opacity(0.84), in: Capsule())
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .background(Color.black)
        .toolbar { assistantWindowToolbar(session) }
        .overlay(alignment: .bottom) {
            if let sessionToast {
                Label(
                    sessionToast,
                    systemImage: sessionToastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(sessionToastIsError ? Color.red.opacity(0.86) : Color.black.opacity(0.72), in: Capsule())
                    .padding(.bottom, 28)
            }
        }
        .task(id: "\(session.id)-\(selectedDisplayID ?? 0)") {
            input.updateClient(session.client)
            renderer.start(
                client: session.client,
                resolution: Self.streamResolution,
                displayID: selectedDisplayID,
                showsCursor: session.status.supportsCursorlessCapture != true)
        }
    }

    @ToolbarContentBuilder
    private func assistantWindowToolbar(
        _ session: MacAssistantSession.ConnectedSession
    ) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SessionToolbarStatusPill(
                hostName: session.displayName,
                qualityColor: .green,
                qualityLabel: "Assistant",
                differentiateWithoutColor: differentiateWithoutColor)
        }
        if showsStats {
            ToolbarItem(placement: .principal) { assistantLiveStats }
        }
        ToolbarItem(placement: .primaryAction) { displaySizingMenu }
        ToolbarItem(placement: .primaryAction) { toolsCluster(session) }
        ToolbarItem(placement: .primaryAction) { screenAIButton }
        ToolbarItem(placement: .primaryAction) { audioButton }
        ToolbarItem(placement: .primaryAction) { accessModeButton }
        ToolbarItem(placement: .primaryAction) { statsButton }
        ToolbarItem(placement: .primaryAction) {
            SessionToolbarDisconnectButton { model.disconnect() }
        }
    }

    private var displaySizingMenu: some View {
        Menu {
            Button {
                displayModeRaw = DisplayMappingEngine.DisplayMode.fitDisplay.rawValue
            } label: {
                Label("Fit Display", systemImage: displayMode == .fitDisplay ? "checkmark" : "rectangle.inset.filled")
            }
            Button {
                displayModeRaw = DisplayMappingEngine.DisplayMode.fillScreen.rawValue
            } label: {
                Label("Fill Window", systemImage: displayMode == .fillScreen ? "checkmark" : "arrow.up.left.and.arrow.down.right")
            }
            Button {
                displayModeRaw = DisplayMappingEngine.DisplayMode.actualSize.rawValue
                resizeWindowToActualSize()
            } label: {
                Label("Actual Size", systemImage: displayMode == .actualSize ? "checkmark" : "1.magnifyingglass")
            }
            Divider()
            Button {
                displayMode == .actualSize ? resizeWindowToActualSize() : matchWindowToDisplay()
            } label: {
                Label("Match Window to Display", systemImage: "aspectratio")
            }
            .disabled(renderer.geometry == nil)
        } label: {
            SessionToolbarToggleLabel(
                title: displaySizingTitle,
                systemImage: displaySizingSymbol,
                isActive: displayMode != .fitDisplay)
        }
        .menuStyle(.borderlessButton)
        .help(displaySizingHelp)
        .accessibilityLabel("Remote display sizing")
        .accessibilityValue(displaySizingTitle)
    }

    private func toolsCluster(_ session: MacAssistantSession.ConnectedSession) -> some View {
        HStack(spacing: 2) {
            if let displays = session.status.displays, displays.count > 1 {
                Menu {
                    ForEach(displays) { display in
                        Button { selectedDisplayID = display.id } label: {
                            if selectedDisplayID == display.id {
                                Label(display.name, systemImage: "checkmark")
                            } else {
                                Text(display.name)
                            }
                        }
                    }
                } label: {
                    SessionToolbarIconLabel(systemImage: "rectangle.on.rectangle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Switch display")
                .accessibilityLabel("Switch display")
            }
            unavailableTool(systemImage: "doc.on.clipboard", name: "Clipboard")
            Button(action: captureScreenshot) {
                SessionToolbarIconLabel(systemImage: "camera")
            }
            .buttonStyle(SessionToolbarIconButtonStyle())
            .disabled(renderer.latestPixelBuffer == nil)
            .help("Save a screenshot of the remote screen")
            .accessibilityLabel("Save screenshot")
            unavailableTool(systemImage: "arrow.up.doc", name: "File transfer")
            unavailableTool(systemImage: "terminal", name: "Terminal")
            Button { input.keyPress("Tab", modifiers: ["command"]) } label: {
                SessionToolbarIconLabel(systemImage: "command")
            }
            .buttonStyle(SessionToolbarIconButtonStyle())
            .disabled(!fullControl)
            .keyboardShortcut(.tab, modifiers: [.control, .option])
            .help("Send ⌘Tab to the remote Mac (local shortcut: ⌃⌥Tab)")
            .accessibilityLabel("Switch apps on the remote Mac")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .sessionToolbarClusterChrome()
    }

    private func unavailableTool(systemImage: String, name: String) -> some View {
        Button(action: {}) { SessionToolbarIconLabel(systemImage: systemImage) }
            .buttonStyle(SessionToolbarIconButtonStyle())
            .disabled(true)
            .help("\(name) is unavailable through this Assistant connection")
            .accessibilityLabel(name)
            .accessibilityHint("Unavailable through this Assistant connection")
    }

    private var screenAIButton: some View {
        Button(action: {}) {
            SessionToolbarToggleLabel(systemImage: "sparkles")
        }
        .buttonStyle(SessionToolbarToggleButtonStyle())
        .disabled(true)
        .help("Screen AI is unavailable through this Assistant connection")
        .accessibilityLabel("Screen AI")
    }

    private var audioButton: some View {
        Button(action: {}) {
            SessionToolbarToggleLabel(systemImage: "speaker.slash.fill")
        }
        .buttonStyle(SessionToolbarToggleButtonStyle())
        .disabled(true)
        .help("Remote audio is unavailable through this Assistant connection")
        .accessibilityLabel("Audio")
    }

    private var accessModeButton: some View {
        Button { fullControl.toggle() } label: {
            Label(fullControl ? "Switch to View Only" : "Enable Full Control",
                  systemImage: fullControl ? "cursorarrow.motionlines" : "eye.fill")
        }
        .labelStyle(.iconOnly)
        .help(fullControl ? "Full control — input enabled" : "View only — input disabled")
        .accessibilityLabel("Access mode")
        .accessibilityValue(fullControl ? "Full control" : "View only")
    }

    private var statsButton: some View {
        Button { showsStats.toggle() } label: {
            Label(showsStats ? "Hide Connection Stats" : "Show Connection Stats",
                  systemImage: showsStats ? "chart.bar.fill" : "chart.bar")
        }
        .labelStyle(.iconOnly)
        .help(showsStats ? "Hide connection stats" : "Show connection stats")
        .accessibilityLabel("Connection stats")
    }

    /// The Assistant transport reports neither latency nor bitrate, so this
    /// shows only what is actually measured. It previously reused the WebRTC
    /// three-metric cluster with all three values hardcoded to nil, which
    /// rendered a permanent "— — —" beside a Stats toggle that changed nothing.
    private var assistantLiveStats: some View {
        HStack(spacing: 12) {
            SessionToolbarMetric(
                label: "FPS",
                value: renderer.framesPerSecond
                    .map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
            )
            SessionToolbarMetric(
                label: "Stream",
                value: renderer.geometry
                    .map { "\($0.imageWidth)×\($0.imageHeight)" } ?? "—"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .sessionToolbarClusterChrome()
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stream statistics")
    }

    private var displaySizingTitle: String {
        switch displayMode {
        case .fitDisplay: "Fit Display"
        case .fillScreen: "Fill Window"
        case .actualSize: "Actual Size"
        }
    }

    private var displaySizingSymbol: String {
        switch displayMode {
        case .fitDisplay: "rectangle.inset.filled"
        case .fillScreen: "arrow.up.left.and.arrow.down.right"
        case .actualSize: "1.magnifyingglass"
        }
    }

    private var displaySizingHelp: String {
        switch displayMode {
        case .fitDisplay: "Fit Display — show the whole remote screen"
        case .fillScreen: "Fill Window — edges may be cropped"
        case .actualSize: "Actual Size — 1:1 remote pixels"
        }
    }

    private func matchWindowToDisplay() {
        guard let geometry = renderer.geometry else { return }
        resizeLocalWindow(
            to: CGSize(width: CGFloat(geometry.imageWidth), height: CGFloat(geometry.imageHeight)),
            actualPixels: false)
    }

    private func resizeWindowToActualSize() {
        guard let geometry = renderer.geometry else { return }
        resizeLocalWindow(
            to: CGSize(width: CGFloat(geometry.imageWidth), height: CGFloat(geometry.imageHeight)),
            actualPixels: true)
    }

    private func resizeLocalWindow(to streamSize: CGSize, actualPixels: Bool) {
        guard streamSize.width > 0, streamSize.height > 0,
              let window = NSApp.keyWindow,
              let screen = window.screen ?? NSScreen.main else { return }
        let currentContent = window.contentRect(forFrameRect: window.frame)
        let chromeHeight = window.frame.height - currentContent.height
        let maximum = CGSize(width: screen.visibleFrame.width, height: max(320, screen.visibleFrame.height - chromeHeight))
        let scale = actualPixels ? screen.backingScaleFactor : 1
        var target = CGSize(width: streamSize.width / scale, height: streamSize.height / scale)
        if !actualPixels {
            target.width = currentContent.width
            target.height = target.width * streamSize.height / streamSize.width
        }
        let downscale = min(1, min(maximum.width / target.width, maximum.height / target.height))
        target.width *= downscale
        target.height *= downscale
        var content = currentContent
        content.size = target
        var frame = window.frameRect(forContentRect: content)
        frame.origin.x = min(max(window.frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(window.frame.maxY - frame.height, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    private func captureScreenshot() {
        guard let pixelBuffer = renderer.latestPixelBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            showToast("Couldn't save screenshot", isError: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Vamp Assistant Screenshot.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: url, options: .atomic)
                showToast("Screenshot saved")
            } catch {
                showToast("Couldn't save screenshot", isError: true)
            }
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        sessionToast = message
        sessionToastIsError = isError
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard sessionToast == message else { return }
            sessionToast = nil
        }
    }

    private func streamStatus(_ session: MacAssistantSession.ConnectedSession) -> some View {
        VStack(spacing: 12) {
            if let error = renderer.lastError {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 36, weight: .light))
                Text("Vamp Assistant stream stopped").font(.headline)
                Text(error).font(.callout).foregroundStyle(.white.opacity(0.74)).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("Reconnect") {
                    renderer.start(
                        client: session.client,
                        resolution: Self.streamResolution,
                        displayID: selectedDisplayID)
                }
                    .buttonStyle(.bordered)
            } else {
                ProgressView()
                Text("Opening \(session.displayName)…").font(.callout).foregroundStyle(.white.opacity(0.78))
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .macGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func permissionState(_ session: MacAssistantSession.ConnectedSession) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 44, weight: .light))
            Text("Mac Control is not ready").font(.title2.weight(.semibold))
            Text(permissionMessage(session.status)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Text("Open Vamp Assistant → Settings → Permissions on the remote Mac, grant only the requested permission, then check again.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 500)
            if let refreshError { Text(refreshError).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center) }
            HStack {
                Button("Back to Macs") { model.disconnect() }.keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        isRefreshing = true
                        refreshError = await model.refreshStatus()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing { ProgressView().controlSize(.small) } else { Text("Check Again") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRefreshing)
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacBrand.pageBackdrop)
    }

    private func permissionMessage(_ status: BeetCodeControlStatus) -> String {
        if !status.enabled { return "Mac Control is turned off in Vamp Assistant." }
        if !status.screenRecording { return "Screen Recording permission is required to receive the remote display." }
        if !status.accessibility { return "Accessibility permission is required to send pointer and keyboard input." }
        return status.message ?? "Vamp Assistant is still preparing Mac Control."
    }
}

private struct MacAssistantVideoStreamView: NSViewRepresentable {
    @ObservedObject var renderer: BeetCodeVideoRendererViewModel
    let input: MacAssistantInputController
    let isInputEnabled: Bool
    let usesLocalCursor: Bool
    let displayMode: DisplayMappingEngine.DisplayMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RemoteStreamNSView {
        let view = RemoteStreamNSView()
        view.input = input
        view.isInputEnabled = isInputEnabled
        view.displayMode = displayMode
        view.usesLocalCursor = usesLocalCursor
        input.isEnabled = isInputEnabled
        input.updateDisplayMode(displayMode)
        input.setGeometry(renderer.geometry)
        context.coordinator.cancellable = renderer.$latestPixelBuffer.sink { [weak view] in
            view?.display(pixelBuffer: $0)
        }
        return view
    }

    func updateNSView(_ view: RemoteStreamNSView, context: Context) {
        view.input = input
        view.isInputEnabled = isInputEnabled
        view.displayMode = displayMode
        view.usesLocalCursor = usesLocalCursor
        input.isEnabled = isInputEnabled
        input.updateDisplayMode(displayMode)
        input.setGeometry(renderer.geometry)
    }

    static func dismantleNSView(_ view: RemoteStreamNSView, coordinator: Coordinator) {
        coordinator.cancellable?.cancel()
        view.setLocalCursorHidden(false)
        view.display(pixelBuffer: nil)
    }

    final class Coordinator { var cancellable: AnyCancellable? }
}

/// Assistant HTTP input adapter for Vamp Control's mature AppKit event surface.
@MainActor
final class MacAssistantInputController: ObservableObject, MacRemoteInputHandling {
    @Published private(set) var lastError: String?
    var isEnabled = true

    /// Follows the live session. A `@StateObject` is built once, so capturing
    /// the client at init would keep routing input to the previously paired Mac
    /// after a re-pair.
    private var client: BeetCodeRemoteClient?
    private var viewSize: CGSize = .zero
    private var geometry: BeetCodeDisplayGeometry?
    private var displayMode: DisplayMappingEngine.DisplayMode = .fitDisplay
    private var pendingMove: BeetCodeInputCommand?
    private var moveFlushTask: Task<Void, Never>?
    private var sendQueue = MacAssistantInputSendQueue()
    private var sendTask: Task<Void, Never>?

    init(client: BeetCodeRemoteClient?) {
        self.client = client
    }

    func updateClient(_ client: BeetCodeRemoteClient) {
        stop()
        self.client = client
    }

    func setGeometry(_ geometry: BeetCodeDisplayGeometry?) { self.geometry = geometry }
    func updateViewGeometry(size: CGSize, pixelScale: Double) { viewSize = size }
    func updateDisplayMode(_ displayMode: DisplayMappingEngine.DisplayMode) { self.displayMode = displayMode }
    func containsRemoteContent(_ point: CGPoint) -> Bool { contentRect(geometry)?.contains(point) == true }
    func remoteContentRect(in viewSize: CGSize) -> CGRect? { contentRect(geometry) }

    func pointerMoved(to point: CGPoint) {
        guard isEnabled, let mapped = map(point, clamp: true) else { return }
        pendingMove = .move(x: mapped.x, y: mapped.y)
        guard moveFlushTask == nil else { return }
        moveFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            self?.flushMove()
        }
    }

    func pointerButton(_ button: MouseButton, action: ButtonAction, at point: CGPoint) {
        guard isEnabled, let mapped = map(point, clamp: false) else { return }
        flushMove()
        enqueue(.move(x: mapped.x, y: mapped.y))
        switch action {
        case .down: enqueue(.down(button: button.rawValue))
        case .up: enqueue(.up(button: button.rawValue))
        case .click: enqueue(.click(x: mapped.x, y: mapped.y, button: button.rawValue, count: 1))
        case .doubleClick: enqueue(.click(x: mapped.x, y: mapped.y, button: button.rawValue, count: 2))
        }
    }

    func scrolled(deltaX: Double, deltaY: Double, isPrecise: Bool) {
        guard isEnabled else { return }
        enqueue(.scroll(x: nil, y: nil, dx: deltaX, dy: deltaY))
    }

    func keyEvent(_ event: NSEvent, action: KeyAction) {
        guard isEnabled, action == .down else { return }
        // Modifiers travel with the following key. Control-click is translated by
        // RemoteStreamNSView without leaking a separate Control press remotely.
        guard !Self.modifierKeyCodes.contains(event.keyCode) else { return }
        let modifiers = Self.modifierNames(event.modifierFlags)
        if let special = Self.specialKeyName(event.keyCode) {
            enqueue(.key(special, modifiers: modifiers))
            return
        }
        let shortcutModifiers = event.modifierFlags.intersection([.command, .control, .option])
        if shortcutModifiers.isEmpty, let characters = event.characters, !characters.isEmpty {
            enqueue(.type(characters))
        } else if let raw = event.charactersIgnoringModifiers, !raw.isEmpty {
            enqueue(.key(raw.lowercased(), modifiers: modifiers))
        }
    }

    func keyPress(_ key: String, modifiers: [String]) { enqueue(.key(key, modifiers: modifiers)) }

    func stop() {
        moveFlushTask?.cancel()
        moveFlushTask = nil
        sendQueue.removeAll()
        sendTask?.cancel()
        sendTask = nil
        pendingMove = nil
        lastError = nil
        client = nil
    }

    private func flushMove() {
        moveFlushTask?.cancel()
        moveFlushTask = nil
        guard let pendingMove else { return }
        self.pendingMove = nil
        enqueue(pendingMove)
    }

    private func enqueue(_ command: BeetCodeInputCommand) {
        guard isEnabled, client != nil else { return }
        sendQueue.enqueue(command)
        startSenderIfNeeded()
    }

    private func startSenderIfNeeded() {
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            await self?.drainSendQueue()
        }
    }

    private func drainSendQueue() async {
        while !Task.isCancelled,
              let command = sendQueue.popFirst(),
              let client {
            do {
                _ = try await client.sendControlBatch([command])
                lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
            }
        }
        sendTask = nil
        if !sendQueue.isEmpty { startSenderIfNeeded() }
    }

    private func map(_ point: CGPoint, clamp: Bool) -> CGPoint? {
        guard let geometry, let rect = contentRect(geometry), rect.width > 0, rect.height > 0 else { return nil }
        guard clamp || rect.contains(point) else { return nil }
        let point = CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
        return CGPoint(
            x: geometry.displayX + ((point.x - rect.minX) / rect.width) * geometry.displayWidth,
            y: geometry.displayY + ((point.y - rect.minY) / rect.height) * geometry.displayHeight)
    }

    private func contentRect(_ geometry: BeetCodeDisplayGeometry?) -> CGRect? {
        guard let geometry, geometry.imageWidth > 0, geometry.imageHeight > 0,
              viewSize.width > 0, viewSize.height > 0 else { return nil }
        let imageAspect = CGFloat(geometry.imageWidth) / CGFloat(geometry.imageHeight)
        let viewAspect = viewSize.width / viewSize.height
        let size: CGSize
        if displayMode == .fillScreen {
            size = imageAspect > viewAspect
                ? CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
                : CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
        } else {
            size = imageAspect > viewAspect
                ? CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
                : CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
        }
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height)
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 60, 58, 61, 59, 62, 63]

    private static func specialKeyName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36, 76: "Return"
        case 48: "Tab"
        case 51: "Backspace"
        case 53: "Escape"
        case 117: "Delete"
        case 123: "ArrowLeft"
        case 124: "ArrowRight"
        case 125: "ArrowDown"
        case 126: "ArrowUp"
        case 115: "Home"
        case 119: "End"
        case 116: "PageUp"
        case 121: "PageDown"
        default: nil
        }
    }

    private static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.function) { names.append("function") }
        return names
    }
}
