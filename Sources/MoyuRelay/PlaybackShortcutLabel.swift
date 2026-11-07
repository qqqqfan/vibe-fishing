import Foundation

/// Human-readable keyboard labels; never render control characters as text.
enum PlaybackShortcutLabel {
    static func key(_ code: UInt16, characters: String? = nil) -> String {
        let special: [UInt16: String] = [
            48: "Tab", 49: "Space", 36: "Return", 76: "Enter", 53: "Esc",
            51: "Delete", 117: "Forward Delete", 63: "Fn",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let name = special[code] { return name }
        let name = (characters ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(name)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Key \(code)" : text.uppercased()
    }

    static func format(code: UInt16, flags: UInt, characters: String? = nil) -> String {
        let prefix = ((flags & (1 << 18)) != 0 ? "⌃" : "")
            + ((flags & (1 << 19)) != 0 ? "⌥" : "")
            + ((flags & (1 << 17)) != 0 ? "⇧" : "")
            + ((flags & (1 << 20)) != 0 ? "⌘" : "")
        return prefix + key(code, characters: characters)
    }
}
