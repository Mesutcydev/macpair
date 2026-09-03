import AppKit
import SharedModels

/// AppKit no longer consistently promotes Control-primary click to a secondary
/// event. Keeping this mapping pure makes the behavior testable.
enum RemotePrimaryClickTranslation {
    static func button(controlPressed: Bool) -> MouseButton {
        controlPressed ? .right : .left
    }
}

/// Which ⌘-shortcuts Vamp Control keeps for itself instead of forwarding to the
/// host.
///
/// The rule is deliberately narrow and easy to state: **every shortcut this app
/// shows in its own menu bar works locally; everything else goes to the remote
/// Mac.** The previous predicate matched on the character alone and then bailed
/// out whenever Shift was held, so ⇧⌘D — the documented way to leave a session —
/// was forwarded to the host and never disconnected anything. ⌘0/⌘1/⌘2 in the
/// View menu were swallowed the same way.
///
/// Session actions that are *not* in a menu (screenshot, terminal, clipboard,
/// the app picker) deliberately use ⌃⌥ combinations instead of taking more ⌘
/// keys away from the remote Mac.
enum RemoteKeyEquivalentPolicy {
    private static let commandOnly: Set<String> = [
        "q", "m", "h", ",",  // application menu
        "r",                 // Session ▸ Refresh Hosts
        "0", "1", "2"        // View ▸ Fit Display / Fill Window / Actual Size
    ]
    private static let commandShift: Set<String> = [
        "d"                  // Session ▸ Disconnect from Host
    ]

    static func staysLocal(characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.command) else { return false }
        // A ⌃ or ⌥ in the mix is never one of ours, so it belongs to the host.
        guard !modifiers.contains(.control), !modifiers.contains(.option) else { return false }
        let key = characters.lowercased()
        return modifiers.contains(.shift) ? commandShift.contains(key) : commandOnly.contains(key)
    }
}
