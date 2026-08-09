#if canImport(UIKit)
import SwiftUI
import UIKit
import SwiftTerm
import Diagnostics
import SharedProtocol
import TransportWebRTC

/// Full-screen Terminal Mode: a SwiftTerm-backed view that streams bytes to
/// and from the host's PTY shell.
///
/// Owned by `ClientTerminalSessionManager` for state + send/receive. This view
/// wraps SwiftTerm's `TerminalView` (xterm emulator) in a UIViewRepresentable
/// and stitches together emulator → manager.sendInput and
/// manager.output → emulator.feed via the coordinator.
struct TerminalModeView: View {

    @ObservedObject var session: ClientTerminalSessionManager

    /// Commands the underlying `TerminalView` (show/hide the software keyboard,
    /// sticky Ctrl) and mirrors its live keyboard state back into SwiftUI so the
    /// toggle button always reflects reality — even when the user dismisses the
    /// keyboard with a swipe or attaches a hardware keyboard.
    @StateObject private var input = TerminalInputController()

    @Environment(\.dismiss) private var dismiss

    @State private var aiResult: String?
    @State private var aiThinking = false
    @State private var showAI = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            SwiftTermContainer(session: session, controller: input)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .background(Color.black)
        }
        // The quick-key row is a safe-area inset, not a sibling competing for
        // the terminal's height. This prevents the native keyboard and the
        // accessory row from overlapping during interactive dismissal.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            specialKeysBar
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationBarHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            input.isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            input.isKeyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset)) { _ in
            input.ctrlActive = false
        }
        .onAppear {
            // Initial open uses a conservative 80x24; the SwiftTerm view will
            // recompute on first layout and call requestResize.
            session.open(cols: 80, rows: 24)
        }
        .onDisappear {
            session.close(reason: "view-dismissed")
        }
        .sheet(isPresented: $showAI) {
            NavigationStack {
                ScrollView {
                    if aiThinking {
                        ProgressView("Thinking…").padding()
                    } else if let aiResult {
                        Text(aiResult)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .navigationTitle("Terminal AI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAI = false } } }
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            roundButton(system: "chevron.down", label: "Close terminal") {
                dismiss()
            }
            Spacer(minLength: 8)
            Text(statusText)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            roundButton(
                system: input.isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                label: input.isKeyboardVisible ? "Hide keyboard" : "Show keyboard"
            ) {
                input.toggleKeyboard()
            }
            roundButton(system: "sparkles", label: "Explain output") {
                terminalExplain()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.05))
    }

    private func terminalExplain() {
        let text = session.output.suffix(80)
            .compactMap { String(data: $0.data, encoding: .utf8) }
            .joined()
        guard !text.isEmpty else {
            aiResult = "No terminal output yet — run a command first."
            showAI = true
            return
        }
        aiThinking = true
        aiResult = nil
        showAI = true
        Task {
            let result = await TerminalAssistant.explain(output: text)
            await MainActor.run {
                aiResult = result ?? "On-device AI isn’t available (turn on Apple Intelligence in Settings)."
                aiThinking = false
            }
        }
    }

    private func roundButton(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.1), in: Circle())
        }
        .accessibilityLabel(label)
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "idle"
        case .opening: return "opening shell…"
        case .open: return "● connected"
        case .closed(let exit, let signal, let reason):
            // The host gates terminal access behind a user toggle and uses
            // this reason string when it refuses to spawn a shell.
            if reason == "terminal-disabled" {
                return "✕ Terminal Mode is off on this Mac"
            }
            if let signal { return "✕ signal \(signal)" }
            if let exit { return "✕ exit \(exit)" }
            return "✕ closed\(reason.map { " · \($0)" } ?? "")"
        }
    }

    // MARK: Special keys

    private var specialKeysBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Sticky Ctrl: arms `controlModifier` so the *next* typed key (or
                // tapped letter) becomes a control sequence — covers every ctrl-x
                // combo without a dedicated button each.
                specialKey("ctrl", isOn: input.ctrlActive) { input.toggleCtrl() }
                specialKey("esc") { send(bytes: [0x1B]) }
                specialKey("tab") { send(bytes: [0x09]) }

                divider

                specialKey("⌃C") { send(bytes: [0x03]) }
                specialKey("⌃D") { send(bytes: [0x04]) }
                specialKey("⌃Z") { send(bytes: [0x1A]) }
                specialKey("⌃L") { send(bytes: [0x0C]) }

                divider

                specialKey("↑") { send(bytes: [0x1B, 0x5B, 0x41]) }
                specialKey("↓") { send(bytes: [0x1B, 0x5B, 0x42]) }
                specialKey("←") { send(bytes: [0x1B, 0x5B, 0x44]) }
                specialKey("→") { send(bytes: [0x1B, 0x5B, 0x43]) }

                divider

                specialKey("home") { send(bytes: [0x1B, 0x5B, 0x48]) }
                specialKey("end") { send(bytes: [0x1B, 0x5B, 0x46]) }
                specialKey("pgup") { send(bytes: [0x1B, 0x5B, 0x35, 0x7E]) }
                specialKey("pgdn") { send(bytes: [0x1B, 0x5B, 0x36, 0x7E]) }

                divider

                specialKey("paste", system: "doc.on.clipboard") { paste() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.08))
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
                if let system { Image(systemName: system).font(.system(size: 11, weight: .semibold)) }
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isOn ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .frame(minWidth: 36, minHeight: 32)
            .background(
                isOn ? Color.white : Color.white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
    }

    private func send(bytes: [UInt8]) {
        session.sendInput(Data(bytes))
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        session.sendInput(Data(text.utf8))
    }
}

// MARK: - Terminal input controller

/// Bridges SwiftUI controls to the imperative `TerminalView` keyboard API.
/// Holds a weak reference to the live terminal view so the toolbar can show or
/// hide the software keyboard and arm the sticky Ctrl modifier.
@MainActor
final class TerminalInputController: ObservableObject {
    /// Whether the software keyboard is currently on screen. Driven by keyboard
    /// notifications so it stays accurate regardless of how it was dismissed.
    @Published var isKeyboardVisible = true
    /// Whether the sticky Ctrl modifier is armed for the next keypress.
    @Published var ctrlActive = false

    fileprivate weak var terminalView: TerminalView?

    fileprivate func attach(_ view: TerminalView) {
        terminalView = view
    }

    func toggleKeyboard() {
        guard let terminalView else { return }
        if isKeyboardVisible {
            _ = terminalView.resignFirstResponder()
            isKeyboardVisible = false
        } else {
            _ = terminalView.becomeFirstResponder()
            isKeyboardVisible = true
        }
    }

    func toggleCtrl() {
        let next = !ctrlActive
        ctrlActive = next
        terminalView?.controlModifier = next
        // Arming Ctrl only matters while typing, so make sure the keyboard is up.
        if next, !isKeyboardVisible {
            _ = terminalView?.becomeFirstResponder()
            isKeyboardVisible = true
        }
    }
}

// MARK: - SwiftTerm bridge

private struct SwiftTermContainer {
    @ObservedObject var session: ClientTerminalSessionManager
    let controller: TerminalInputController
}

extension SwiftTermContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        context.coordinator.attach(view: view)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.deliverPendingOutput(to: uiView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: ClientTerminalSessionManager
        /// Track delivery by the host's monotonic per-chunk `sequence`, NOT by array position.
        /// `session.output` is front-trimmed to a backlog cap (256), so an absolute index points at
        /// the wrong (or already-dropped) element after trimming and permanently stalls once the
        /// cap is hit — which froze terminal output after 256 chunks.
        private var lastDeliveredSequence: UInt64 = 0
        private weak var view: TerminalView?
        private var resizeTask: Task<Void, Never>?

        init(session: ClientTerminalSessionManager) {
            self.session = session
        }

        @MainActor
        func attach(view: TerminalView) {
            self.view = view
            lastDeliveredSequence = 0
        }

        @MainActor
        func deliverPendingOutput(to view: TerminalView) {
            for message in session.output where message.sequence > lastDeliveredSequence {
                let bytes = [UInt8](message.data)
                view.feed(byteArray: bytes[...])
                lastDeliveredSequence = message.sequence
            }
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let input = Data(data)
            Task { @MainActor [session] in
                session.sendInput(input)
            }
        }

        func scrolled(source: TerminalView, position: Double) { /* no-op */ }

        func setTerminalTitle(source: TerminalView, title: String) { /* no-op */ }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let cols = UInt16(clamping: newCols)
            let rows = UInt16(clamping: newRows)
            resizeTask?.cancel()
            resizeTask = Task { @MainActor [session] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                session.requestResize(cols: cols, rows: rows)
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { /* no-op */ }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            Task { @MainActor in
                UIPasteboard.general.string = text
            }
        }

        func itermContent(source: TerminalView, content: ArraySlice<UInt8>) { /* no-op */ }

        func bell(source: TerminalView) { /* no-op */ }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { /* no-op */ }
    }
}
#else
import SwiftUI

struct TerminalModeView: View {
    @ObservedObject var session: ClientTerminalSessionManager
    var body: some View {
        EmptyView()
    }
}
#endif
