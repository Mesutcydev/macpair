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
                onTerminalClipboard: onTerminalClipboard
            )
                .background(Color.black)
            specialKeysBar
        }
        .background(Color.black)
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
    }

    private var paneStatusBar: some View {
        ViewThatFits(in: .horizontal) {
            fullStatusBar
            compactStatusBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(red: 0.075, green: 0.08, blue: 0.1))
    }

    private var fullStatusBar: some View {
        HStack(spacing: 8) {
            statusSummary
            Spacer(minLength: 4)
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
        HStack(spacing: 8) {
            statusSummary
            Spacer(minLength: 3)
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
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(minWidth: 44, minHeight: 40)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("Terminal actions")
            keyboardButton
        }
    }

    private var statusSummary: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
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
                .foregroundStyle(.white.opacity(0.82))
                .frame(minWidth: 44, minHeight: 40)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
                .foregroundStyle(.white.opacity(0.82))
                .frame(minWidth: 40, minHeight: 40)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
        case .open: return Color.green
        case .opening: return Color.orange
        case .idle: return Color.white.opacity(0.35)
        case .closed: return Color.red.opacity(0.9)
        }
    }

    private var specialKeysBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                specialKey("ctrl", isOn: input.ctrlActive) { input.toggleCtrl() }
                specialKey("alt", isOn: input.metaActive) { input.toggleMeta() }
                specialKey("esc") { send([0x1B]) }
                specialKey("tab") { send([0x09]) }
                specialKey("⌫") { send([0x7F]) }
                divider
                specialKey("⌃C") { send([0x03]) }
                specialKey("⌃D") { send([0x04]) }
                specialKey("⌃Z") { send([0x1A]) }
                specialKey("⌃L") { send([0x0C]) }
                specialKey("⌃W") { send([0x17]) }
                divider
                specialKey("↑") { send([0x1B, 0x5B, 0x41]) }
                specialKey("↓") { send([0x1B, 0x5B, 0x42]) }
                specialKey("←") { send([0x1B, 0x5B, 0x44]) }
                specialKey("→") { send([0x1B, 0x5B, 0x43]) }
                divider
                specialKey("home") { send([0x1B, 0x5B, 0x48]) }
                specialKey("end") { send([0x1B, 0x5B, 0x46]) }
                specialKey("pgup") { send([0x1B, 0x5B, 0x35, 0x7E]) }
                specialKey("pgdn") { send([0x1B, 0x5B, 0x36, 0x7E]) }
                divider
                specialKey("~") { send(Array("~".utf8)) }
                specialKey("|") { send(Array("|".utf8)) }
                specialKey("/") { send(Array("/".utf8)) }
                specialKey("paste", system: "doc.on.clipboard") { paste() }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
        }
        .background(Color(red: 0.09, green: 0.095, blue: 0.11))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
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
            HStack(spacing: 4) {
                if let system {
                    Image(systemName: system)
                        .font(.caption2.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(.semibold).monospaced())
            }
            .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.9))
            .padding(.horizontal, 9)
            .frame(minWidth: 44, minHeight: 40)
            .background(
                isOn ? Color.white : Color.white.opacity(0.11),
                in: RoundedRectangle(cornerRadius: 7)
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
        guard let terminalView else { return }
        _ = terminalView.resignFirstResponder()
        isKeyboardVisible = false
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
    let onTerminalClipboard: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onTerminalClipboard: onTerminalClipboard)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: Self.readableFont())
        view.terminalDelegate = context.coordinator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        view.lineSpacing = 1.08
        view.showsVerticalScrollIndicator = true
        view.alwaysBounceVertical = true
        view.delaysContentTouches = false
        view.linkReporting = .implicit
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
        context.coordinator.deliverPendingOutput(to: uiView)
    }

    private static func readableFont() -> UIFont {
        // Keep terminal cells comfortably legible on a phone while still
        // respecting the user's Dynamic Type preference. The clamp prevents
        // an accessibility size from making every mobile shell unusably wide.
        let preferredBody = UIFont.preferredFont(forTextStyle: .body).pointSize
        let scaled = preferredBody * (14.0 / 17.0)
        let pointSize = min(max(scaled, 12), 21)
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
