import Foundation

/// Vamp Assistant `/api/control/input` special-key names.
///
/// Matches `MacAssistantKeyMapping` for the keys the Mac client names explicitly. Space and
/// F1–F4 are not in that map (the Mac client types a space character, and does not send those
/// function keys from its hardware path). The Stream terminal deck still exposes them, so they
/// use the same lower-snake-case shape as the rest of the contract (`space`, `f1`…`f4`).
enum AssistantInputKeyName {
    static func name(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 36, 76: return "return"
        case 48: return "tab"
        case 51: return "backspace"
        case 53: return "escape"
        case 117: return "forward_delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 115: return "home"
        case 119: return "end"
        case 116: return "page_up"
        case 121: return "page_down"
        case 49: return "space"
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        default: return nil
        }
    }
}
