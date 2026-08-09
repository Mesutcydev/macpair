#if canImport(UIKit)
import SwiftUI
import UIKit
import SwiftTerm
import SharedProtocol

/// One permanently mounted terminal pane. The workspace changes opacity and
/// hit testing when switching tabs; it never removes a live pane just because
/// another tab became selected.
struct VampTerminalPaneView: View {
    @ObservedObject var session: ClientTerminalSessionManager
    let isActive: Bool
    var provider: VampAgentProvider?
    var onSendClipboardToHost: () -> Void = {}
    var onRequestClipboardFromHost: () -> Void = {}
    var onTerminalClipboard: (String) -> Void = { _ in }

    @StateObject private var input = VampTerminalInputController()

    var body: some View {
        VStack(spacing: 0) {
            paneStatusBar
            VampSwiftTermContainer(
                session: session,
                controller: input,
                provider: provider,
                onTerminalClipboard: onTerminalClipboard
            )
                .background(provider?.terminalBackground ?? Color.black)
            specialKeysBar
        }
        .background(provider?.terminalBackground ?? Color.black)
        .opacity(isActive ? 1 : 0.001)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
        .onAppear {
            if isActive { input.focus() }
        }
        .onChange(of: isActive) { _, active in
            if active {
                input.focus()
            } else {
                input.blur()
            }
        }
        .onDisappear {
            input.resetModifiers()
        }
    }

    private var paneStatusBar: some View {
        ViewThatFits(in: .horizontal) {
            fullStatusBar
            compactStatusBar
        }
        .padding(.horizontal, VampTerminalDesign.space3)
        .padding(.vertical, VampTerminalDesign.space2)
        .background(provider?.terminalBackground ?? Color(red: 0.075, green: 0.08, blue: 0.1))
    }

    private var fullStatusBar: some View {
        HStack(spacing: VampTerminalDesign.space2) {
            statusSummary
            Spacer(minLength: VampTerminalDesign.space1)
            terminalActionButton(systemImage: "doc.on.doc", label: "Copy selection") {
                _ = input.copySelectionToDevice()
            }
            terminalActionButton(systemImage: "arrow.up.doc", label: "Send phone clipboard to Mac") {
                onSendClipboardToHost()
            }
            terminalActionButton(systemImage: "arrow.down.doc", label: "Get Mac clipboard") {
                onRequestClipboardFromHost()
            }
            keyboardButton
        }
    }

    private var compactStatusBar: some View {
        HStack(spacing: VampTerminalDesign.space2) {
            statusSummary
            Spacer(minLength: VampTerminalDesign.space1)
            Menu {
                Button {
                    _ = input.copySelectionToDevice()
                } label: {
                    Label("Copy selection", systemImage: "doc.on.doc")
                }
                Button {
                    onSendClipboardToHost()
                } label: {
                    Label("Send phone clipboard to Mac", systemImage: "arrow.up.doc")
                }
                Button {
                    onRequestClipboardFromHost()
                } label: {
                    Label("Get Mac clipboard", systemImage: "arrow.down.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(provider?.terminalText.opacity(0.82) ?? .white.opacity(0.82))
                    .frame(minWidth: VampTerminalDesign.minTapTarget, minHeight: VampTerminalDesign.minTapTarget)
                    .background((provider?.terminalText ?? .white).opacity(0.08), in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius))
            }
            .accessibilityLabel("Terminal actions")
            keyboardButton
        }
    }

    private var statusSummary: some View {
        HStack(spacing: VampTerminalDesign.space2) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(provider?.terminalText.opacity(0.72) ?? .white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusText)
    }

    private var keyboardButton: some View {
        Button {
            input.toggleKeyboard()
        } label: {
            Image(systemName: input.isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(provider?.terminalText.opacity(0.82) ?? .white.opacity(0.82))
                .frame(minWidth: VampTerminalDesign.minTapTarget, minHeight: VampTerminalDesign.minTapTarget)
                .background((provider?.terminalText ?? .white).opacity(0.08), in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(input.isKeyboardVisible ? "Hide keyboard" : "Show keyboard")
    }

    private func terminalActionButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(provider?.terminalText.opacity(0.82) ?? .white.opacity(0.82))
                .frame(minWidth: VampTerminalDesign.minTapTarget, minHeight: VampTerminalDesign.minTapTarget)
                .background((provider?.terminalText ?? .white).opacity(0.08), in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Waiting for connection"
        case .opening: return "Opening shell…"
        case .open: return "Connected"
        case .closed(let exitCode, let signal, let reason):
            if reason == "terminal-disabled" { return "Terminal Mode is off" }
            if reason == "terminal-capacity" { return "Terminal capacity reached" }
            if let signal { return "Closed · signal \(signal)" }
            if let exitCode { return "Closed · exit \(exitCode)" }
            return "Closed"
        }
    }

    private var statusColor: SwiftUI.Color {
        switch session.state {
        case .open: return provider?.accent ?? Color.green
        case .opening: return Color.orange
        case .idle: return Color.white.opacity(0.35)
        case .closed: return Color.red.opacity(0.9)
        }
    }

    private var specialKeysBar: some View {
        HStack(spacing: VampTerminalDesign.space2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VampTerminalDesign.space2) {
                    // Keep the everyday row intentionally small. SwiftTerm's
                    // stock alternate keyboard is replaced below, so this
                    // row remains the only persistent accessory above the
                    // native iOS keyboard.
                    specialKey("ctrl", isOn: input.ctrlActive) { input.toggleCtrl() }
                    specialKey("esc") { send([0x1B]) }
                    specialKey("tab") { send([0x09]) }
                    specialKey("⌃C") { send([0x03]) }
                    specialKey("↑") { send([0x1B, 0x5B, 0x41]) }
                    specialKey("↓") { send([0x1B, 0x5B, 0x42]) }
                    specialKey("paste", system: "doc.on.clipboard") { paste() }
                }
                .padding(.leading, VampTerminalDesign.space2)
                .padding(.trailing, VampTerminalDesign.space1)
            }

            Menu {
                Section("Modifiers") {
                    Button {
                        input.toggleMeta()
                    } label: {
                        Label(input.metaActive ? "Alt (on)" : "Alt", systemImage: "option")
                    }
                    Button {
                        input.toggleCtrl()
                    } label: {
                        Label(input.ctrlActive ? "Ctrl (on)" : "Ctrl", systemImage: "control")
                    }
                }

                Section("Control") {
                    Button("Delete") { send([0x7F]) }
                    Button("Ctrl-D") { send([0x04]) }
                    Button("Ctrl-Z") { send([0x1A]) }
                    Button("Ctrl-L") { send([0x0C]) }
                    Button("Ctrl-W") { send([0x17]) }
                }

                Section("Navigation") {
                    Button { send([0x1B, 0x5B, 0x44]) } label: {
                        Label("Left", systemImage: "arrow.left")
                    }
                    Button { send([0x1B, 0x5B, 0x43]) } label: {
                        Label("Right", systemImage: "arrow.right")
                    }
                    Button { send([0x1B, 0x5B, 0x48]) } label: {
                        Label("Home", systemImage: "arrow.left.to.line")
                    }
                    Button { send([0x1B, 0x5B, 0x46]) } label: {
                        Label("End", systemImage: "arrow.right.to.line")
                    }
                    Button { send([0x1B, 0x5B, 0x35, 0x7E]) } label: {
                        Label("Page up", systemImage: "arrow.up")
                    }
                    Button { send([0x1B, 0x5B, 0x36, 0x7E]) } label: {
                        Label("Page down", systemImage: "arrow.down")
                    }
                }

                Section("Characters") {
                    Button("~") { send(Array("~".utf8)) }
                    Button("|") { send(Array("|".utf8)) }
                    Button("/") { send(Array("/".utf8)) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.bold))
                .foregroundStyle(provider?.terminalText.opacity(0.88) ?? .white.opacity(0.88))
                    .frame(width: VampTerminalDesign.minTapTarget, height: VampTerminalDesign.minTapTarget)
                    .background((provider?.terminalText ?? .white).opacity(0.11), in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More terminal keys")
            .padding(.trailing, VampTerminalDesign.space2)
        }
        .frame(minHeight: VampTerminalDesign.controlHeight + VampTerminalDesign.space2)
        .background(provider?.terminalBackground ?? Color(red: 0.09, green: 0.095, blue: 0.11))
    }

    private func specialKey(
        _ title: String,
        system: String? = nil,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: VampTerminalDesign.space1) {
                if let system {
                    Image(systemName: system)
                        .font(.caption2.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(.semibold).monospaced())
            }
            .foregroundStyle(isOn ? (provider?.terminalBackground ?? .black) : (provider?.terminalText.opacity(0.9) ?? .white.opacity(0.9)))
            .padding(.horizontal, VampTerminalDesign.space2)
            .frame(minWidth: VampTerminalDesign.minTapTarget, minHeight: VampTerminalDesign.controlHeight)
            .background(
                isOn ? (provider?.accent ?? .white) : (provider?.terminalText.opacity(0.11) ?? .white.opacity(0.11)),
                in: RoundedRectangle(cornerRadius: VampTerminalDesign.controlRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func send(_ bytes: [UInt8]) {
        session.sendInput(Data(bytes))
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        session.sendInput(Data(text.utf8))
    }
}

@MainActor
private final class VampTerminalInputController: ObservableObject {
    @Published var isKeyboardVisible = true
    @Published var ctrlActive = false
    @Published var metaActive = false

    fileprivate weak var terminalView: TerminalView?

    fileprivate func attach(_ view: TerminalView) {
        terminalView = view
    }

    func toggleKeyboard() {
        if isKeyboardVisible {
            blur()
        } else {
            focus()
        }
    }

    func focus() {
        guard let terminalView else { return }
        _ = terminalView.becomeFirstResponder()
        isKeyboardVisible = true
    }

    func blur() {
        resetModifiers()
        guard let terminalView else { return }
        _ = terminalView.resignFirstResponder()
        isKeyboardVisible = false
    }

    func resetModifiers() {
        ctrlActive = false
        metaActive = false
        terminalView?.controlModifier = false
        terminalView?.metaModifier = false
    }

    func toggleCtrl() {
        ctrlActive.toggle()
        terminalView?.controlModifier = ctrlActive
        if ctrlActive, !isKeyboardVisible {
            _ = terminalView?.becomeFirstResponder()
            isKeyboardVisible = true
        }
    }

    func toggleMeta() {
        metaActive.toggle()
        terminalView?.metaModifier = metaActive
        if metaActive, !isKeyboardVisible {
            _ = terminalView?.becomeFirstResponder()
            isKeyboardVisible = true
        }
    }

    @discardableResult
    func copySelectionToDevice() -> Bool {
        guard let text = terminalView?.getSelection(), !text.isEmpty else { return false }
        UIPasteboard.general.string = text
        terminalView?.selectNone()
        return true
    }
}

private struct VampSwiftTermContainer: UIViewRepresentable {
    @ObservedObject var session: ClientTerminalSessionManager
    let controller: VampTerminalInputController
    let provider: VampAgentProvider?
    let onTerminalClipboard: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onTerminalClipboard: onTerminalClipboard)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: Self.readableFont())
        view.terminalDelegate = context.coordinator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = provider?.terminalBackgroundUIColor ?? .black
        view.nativeForegroundColor = provider?.terminalTextUIColor ?? .white
        view.nativeBackgroundColor = provider?.terminalBackgroundUIColor ?? .black
        view.lineSpacing = 1.08
        view.showsVerticalScrollIndicator = true
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.delaysContentTouches = false
        view.linkReporting = .implicit
        // SwiftTerm's default alternate keyboard is a large three-row grid
        // that consumes most of an iPhone screen. Vamp Terminal owns the
        // compact accessory row above and keeps the native keyboard for text
        // entry, so there is no accidental full-screen keyboard mode.
        view.inputAccessoryView = nil
        view.inputView = nil
        try? view.setUseMetal(true)
        view.addGestureRecognizer(
            UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        )
        context.coordinator.attach(view: view)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        let font = Self.readableFont()
        if abs(uiView.font.pointSize - font.pointSize) > 0.1 {
            uiView.font = font
        }
        uiView.backgroundColor = provider?.terminalBackgroundUIColor ?? .black
        uiView.nativeForegroundColor = provider?.terminalTextUIColor ?? .white
        uiView.nativeBackgroundColor = provider?.terminalBackgroundUIColor ?? .black
        context.coordinator.deliverPendingOutput(to: uiView)
    }

    private static func readableFont() -> UIFont {
        // Keep terminal cells comfortably legible on a phone while still
        // respecting the user's Dynamic Type preference. The clamp prevents
        // an accessibility size from making every mobile shell unusably wide.
        let preferredBody = UIFont.preferredFont(forTextStyle: .body).pointSize
        let scaled = preferredBody * (15.0 / 17.0)
        let pointSize = min(max(scaled, 13), 22)
        return UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: ClientTerminalSessionManager
        private let onTerminalClipboard: (String) -> Void
        private var lastDeliveredSequence: UInt64 = 0
        private weak var view: TerminalView?
        private var pinchStartFontSize: CGFloat = 14

        init(session: ClientTerminalSessionManager, onTerminalClipboard: @escaping (String) -> Void) {
            self.session = session
            self.onTerminalClipboard = onTerminalClipboard
        }

        @MainActor
        func attach(view: TerminalView) {
            self.view = view
            lastDeliveredSequence = 0
        }

        @MainActor
        func deliverPendingOutput(to view: TerminalView) {
            for message in session.output where message.sequence > lastDeliveredSequence {
                view.feed(byteArray: [UInt8](message.data)[...])
                lastDeliveredSequence = message.sequence
            }
        }

        @objc
        func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                pinchStartFontSize = view.font.pointSize
            case .changed, .ended:
                let size = min(max(pinchStartFontSize * gesture.scale, 12), 21)
                view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            default:
                break
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let input = Data(data)
            Task { @MainActor [session] in session.sendInput(input) }
        }

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let cols = UInt16(clamping: newCols)
            let rows = UInt16(clamping: newRows)
            Task { @MainActor [session] in session.requestResize(cols: cols, rows: rows) }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            Task { @MainActor [onTerminalClipboard] in
                UIPasteboard.general.string = text
                onTerminalClipboard(text)
            }
        }

        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.string?.data(using: .utf8)
        }

        func itermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func bell(source: TerminalView) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            Task { @MainActor in UIApplication.shared.open(url) }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
#else
import SwiftUI

struct VampTerminalPaneView: View {
    @ObservedObject var session: ClientTerminalSessionManager
    let isActive: Bool

    var body: some View { EmptyView() }
}
#endif
