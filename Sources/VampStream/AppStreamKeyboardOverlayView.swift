import SwiftUI
import SharedModels
import SharedUtilities

#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// A real keyboard control deck for Vamp Stream. The text field owns the system
/// keyboard while the explicit rows cover Mac keys and one-shot modifiers that
/// cannot be represented reliably by a hidden UITextField.
struct AppStreamKeyboardOverlayView: View {
    enum Mode {
        case standard
        case terminal
    }

    var mode: Mode = .standard
    let onText: (String) -> Void
    let onKey: (UInt16, KeyboardModifierFlags) -> Void
    let onDismiss: () -> Void

    @State private var textInput = ""
    @State private var activeModifiers: KeyboardModifierFlags = []
    @FocusState private var isTextFieldFocused: Bool

    @ViewBuilder var body: some View {
        if mode == .terminal {
            TerminalAppStreamKeyboardDeck(
                onText: onText,
                onKey: onKey,
                onDismiss: onDismiss)
        } else {
            standardDeck
        }
    }

    private var standardDeck: some View {
        VStack(spacing: 10) {
            header
            composer
            quickActions
            shortcutRow
            modifierRow
            keyRow
            helper
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(PR.card.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PR.borderHi, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .onAppear { refocusTextField() }
        .onDisappear { isTextFieldFocused = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(PR.borderHi)
                .frame(width: 28, height: 4)

            Text("keyboard")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg)

            Spacer()

            headerChip("focus") { refocusTextField() }
            headerChip("hide kb") { dismissSystemKeyboard() }

            Button {
                dismissSystemKeyboard()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(PR.fg)
                    .frame(width: 28, height: 28)
                    .background(PR.bg2, in: Circle())
                    .overlay(Circle().strokeBorder(PR.border))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close keyboard")
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("type and send", text: $textInput)
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .focused($isTextFieldFocused)
                .submitLabel(.send)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { sendText() }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(PR.cardHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(PR.border, lineWidth: 0.8)
                )

            Button { sendText() } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(textInput.isEmpty ? PR.dim : PR.bg)
                    .frame(width: 40, height: 40)
                    .background(textInput.isEmpty ? PR.bg2 : PR.accent, in: Circle())
                    .overlay(Circle().strokeBorder(textInput.isEmpty ? PR.border : PR.accent.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .disabled(textInput.isEmpty)
            .accessibilityLabel("Send text to Mac")
        }
    }

    private var quickActions: some View {
        HStack(spacing: 7) {
            rowButton("paste", icon: "doc.on.clipboard") { pasteClipboard() }
            rowButton("backspace", icon: "delete.left") { tapSpecialKey(51) }
            rowButton("return", icon: "return") { tapSpecialKey(36) }
            rowButton("space", icon: "space") { onText(" ") }
        }
    }

    private var shortcutRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                shortcutChip("⌘C copy") { tapCombo(8, [.command]) }
                shortcutChip("⌘V paste") { tapCombo(9, [.command]) }
                shortcutChip("⌘A all") { tapCombo(0, [.command]) }
                shortcutChip("⌘Z undo") { tapCombo(6, [.command]) }
                shortcutChip("⌘⇧3 shot") { tapCombo(20, [.command, .shift]) }
                shortcutChip("⌘⇧4 area") { tapCombo(21, [.command, .shift]) }
                shortcutChip("⌘␣ spotlight") { tapCombo(49, [.command]) }
                shortcutChip("⌘⇥ switch") { tapCombo(48, [.command]) }
            }
        }
    }

    private var modifierRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                modifierKey("cmd", flag: .command)
                modifierKey("shift", flag: .shift)
                modifierKey("opt", flag: .option)
                modifierKey("ctrl", flag: .control)
                modifierKey("fn", flag: .function)
            }
        }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                keyButton("esc", keyCode: 53)
                keyButton("tab", keyCode: 48)
                keyButton("del", keyCode: 51)
                keyButton("←", keyCode: 123)
                keyButton("→", keyCode: 124)
                keyButton("↑", keyCode: 126)
                keyButton("↓", keyCode: 125)
                keyButton("f1", keyCode: 122)
                keyButton("f2", keyCode: 120)
                keyButton("f3", keyCode: 99)
                keyButton("f4", keyCode: 118)
            }
        }
    }

    private var helper: some View {
        Text("modifiers apply to the next key, then release · cmd + typed letter sends the combo")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundColor(PR.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg2)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(PR.bg2, in: Capsule())
                .overlay(Capsule().strokeBorder(PR.border))
        }
        .buttonStyle(.plain)
    }

    private func rowButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(PR.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PR.border))
        }
        .buttonStyle(.plain)
    }

    private func shortcutChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(PR.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PR.border))
        }
        .buttonStyle(.plain)
    }

    private func modifierKey(_ title: String, flag: KeyboardModifierFlags) -> some View {
        let isActive = activeModifiers.contains(flag)
        return Button {
            if isActive { activeModifiers.remove(flag) } else { activeModifiers.insert(flag) }
            refocusTextField()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? PR.bg : PR.fg2)
                .frame(minWidth: 52)
                .padding(.vertical, 9)
                .background(isActive ? PR.accent : PR.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isActive ? PR.accent.opacity(0.45) : PR.border)
                )
        }
        .buttonStyle(.plain)
    }

    private func keyButton(_ title: String, keyCode: UInt16) -> some View {
        Button { tapSpecialKey(keyCode) } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(PR.fg)
                .frame(minWidth: 46)
                .padding(.vertical, 9)
                .background(PR.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PR.border))
        }
        .buttonStyle(.plain)
    }

    private func sendText() {
        guard !textInput.isEmpty else { return }
        if !activeModifiers.isEmpty,
           textInput.count == 1,
           let character = textInput.lowercased().first,
           let keyCode = Self.characterKeyCodes[character] {
            tapSpecialKey(keyCode)
            textInput = ""
            return
        }
        onText(textInput)
        textInput = ""
        refocusTextField()
    }

    private func tapCombo(_ keyCode: UInt16, _ modifiers: KeyboardModifierFlags) {
        onKey(keyCode, modifiers)
        refocusTextField()
    }

    private func tapSpecialKey(_ keyCode: UInt16) {
        onKey(keyCode, activeModifiers)
        activeModifiers = []
        refocusTextField()
    }

    private static let characterKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47
    ]

    private func refocusTextField() {
        DispatchQueue.main.async { isTextFieldFocused = true }
    }

    private func dismissSystemKeyboard() {
        isTextFieldFocused = false
#if canImport(UIKit) && !os(macOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }

    private func pasteClipboard() {
#if canImport(UIKit) && !os(macOS)
        if let clipboardText = UIPasteboard.general.string, !clipboardText.isEmpty {
            onText(clipboardText)
        }
#endif
        refocusTextField()
    }
}

/// A compact command deck for streamed terminal apps. Text submission is deliberately a
/// two-step wire operation (type, then Return), while auxiliary keys remain discrete Mac key
/// presses so shells, TUIs, editors, and multiplexers receive their native control sequences.
private struct TerminalAppStreamKeyboardDeck: View {
    let onText: (String) -> Void
    let onKey: (UInt16, KeyboardModifierFlags) -> Void
    let onDismiss: () -> Void

    @State private var command = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("terminal")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PR.fg)
                Text("type a command or use aux keys")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(PR.dim)
                Spacer()
                Button {
                    isFocused = false
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(PR.bg2, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close terminal controls")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    auxKey("esc", 53)
                    auxKey("tab", 48)
                    auxKey("⌃C", 8, [.control], hint: "Interrupt")
                    auxKey("⌃L", 37, [.control], hint: "Clear terminal")
                    auxKey("←", 123)
                    auxKey("↑", 126)
                    auxKey("↓", 125)
                    auxKey("→", 124)
                    auxKey("home", 115)
                    auxKey("end", 119)
                    auxKey("pg↑", 116)
                    auxKey("pg↓", 121)
                }
            }

            HStack(spacing: 7) {
                Button(action: pasteIntoCommand) {
                    Image(systemName: "doc.on.clipboard")
                        .frame(width: 34, height: 38)
                        .background(PR.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste into command")

                TextField("command", text: $command)
                    .font(.system(size: 15, design: .monospaced))
                    .focused($isFocused)
                    .submitLabel(.send)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(submit)
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(PR.cardHi, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PR.border))

                Button(action: submit) {
                    Image(systemName: "return")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(command.isEmpty ? PR.dim : PR.bg)
                        .frame(width: 42, height: 38)
                        .background(command.isEmpty ? PR.bg2 : PR.accent,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(command.isEmpty)
                .accessibilityLabel("Run command")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(PR.card.opacity(0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(PR.borderHi))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onAppear { refocus() }
    }

    private func auxKey(
        _ title: String,
        _ keyCode: UInt16,
        _ modifiers: KeyboardModifierFlags = [],
        hint: String? = nil
    ) -> some View {
        Button {
            onKey(keyCode, modifiers)
            refocus()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(PR.fg)
                .frame(minWidth: 38)
                .padding(.vertical, 8)
                .background(PR.bg2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PR.border))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hint ?? title)
    }

    private func submit() {
        guard !command.isEmpty else { return }
        onText(command)
        onKey(36, [])
        command = ""
        refocus()
    }

    private func refocus() {
        DispatchQueue.main.async { isFocused = true }
    }

    private func pasteIntoCommand() {
#if canImport(UIKit) && !os(macOS)
        if let text = UIPasteboard.general.string { command += text }
#endif
        refocus()
    }
}
