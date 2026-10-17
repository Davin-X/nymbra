import Foundation

/// An application shortcut, parsed from the short string a config file uses:
/// `cmd+c`, `cmd+shift+t`, `ctrl+left`.
///
/// Parsing is strict on purpose. A shortcut that cannot be parsed is refused,
/// and reported, rather than stored and quietly ignored — "I set my shortcut and
/// nothing happened" is the worst possible answer a settings screen can give.
public struct Shortcut: Equatable, Hashable, Sendable {

    public let modifiers: Keyboard.Modifiers
    public let key: Key

    public init(modifiers: Keyboard.Modifiers, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// A key, either a character or one of the keys that has no character.
    public enum Key: Equatable, Hashable, Sendable {
        case character(Character)
        case named(Named)

        public enum Named: Equatable, Hashable, Sendable {
            case returnKey
            case keypadEnter
            case tab
            case space
            case escape
            case delete
            case forwardDelete
            case left, right, up, down
            case home, end
            case pageUp, pageDown
            /// F1…F20, by number.
            case function(Int)
        }
    }

    // MARK: - Parsing

    /// Parse `cmd+shift+t`, or return nothing.
    ///
    /// Modifier words come first, joined by `+`; the key is last. Where a key has
    /// two common names, both are accepted and one is canonical going back out.
    /// A character key is written as itself, so `cmd+=` is Cmd and the `=`
    /// key — the keys whose names would be ambiguous use words, as in
    /// `cmd+plus` or `cmd+minus`.
    public init?(parsing text: String) {
        // Empty parts are not dropped: `cmd+` and `+c` are typos, and a typo
        // should be reported rather than quietly read as a different shortcut.
        let parts = text
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let keyPart = parts.last, !keyPart.isEmpty else { return nil }

        var modifiers: Keyboard.Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘", "super": modifiers.insert(.command)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            default: return nil
            }
        }

        let key: Key
        if let named = Shortcut.namedKeys[keyPart] {
            key = .named(named)
        } else if keyPart.count == 1, let character = keyPart.first {
            key = .character(character)
        } else if let character = Shortcut.symbolKeys[keyPart] {
            key = .character(character)
        } else {
            return nil
        }

        self.init(modifiers: modifiers, key: key)
    }

    /// The names a config file may use for keys without characters of their own.
    private static let namedKeys: [String: Key.Named] = {
        var keys: [String: Key.Named] = [
            "return": .returnKey, "returnkey": .returnKey, "enter": .returnKey,
            "keypadenter": .keypadEnter,
            "tab": .tab,
            "space": .space, "spacebar": .space,
            "escape": .escape, "esc": .escape,
            "delete": .delete, "backspace": .delete,
            "forwarddelete": .forwardDelete,
            "left": .left, "right": .right, "up": .up, "down": .down,
            "home": .home, "end": .end,
            "pageup": .pageUp, "pagedown": .pageDown,
        ]
        for number in 1...20 { keys["f\(number)"] = .function(number) }
        return keys
    }()

    /// Keys whose written form is a word, because the character itself would be
    /// ambiguous in a `+`-separated list.
    private static let symbolKeys: [String: Character] = [
        "plus": "+", "minus": "-", "equal": "=",
        "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "backtick": "`",
        "leftbracket": "[", "rightbracket": "]",
    ]

    // MARK: - Matching

    /// Whether a key event is this shortcut.
    ///
    /// The modifiers must match exactly: Cmd+T and Cmd+Shift+T are different
    /// shortcuts, and treating them as the same is how a terminal swallows a key
    /// the program wanted.
    public func matches(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: Keyboard.Modifiers
    ) -> Bool {
        guard modifiers == self.modifiers else { return false }
        switch key {
        case .character(let character):
            // `charactersIgnoringModifiers` still reflects Shift, so compare in
            // one case and let the modifier set carry the shift.
            guard let text = charactersIgnoringModifiers, text.count == 1 else { return false }
            return text.lowercased() == String(character).lowercased()
        case .named(let named):
            return named.keyCode == keyCode
        }
    }

    // MARK: - Names

    /// The config-file form, in the order people write these: the key last, and
    /// Command first.
    public var text: String {        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key.text)
        return parts.joined(separator: "+")
    }

    /// How a menu would write it: `⇧⌘T`. The modifier order is the platform's
    /// — Control, Option, Shift, Command — not the order they appear in a config
    /// file.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.displayText
    }

    /// The key as a menu key equivalent: one character, or one of the code points
    /// the platform defines for keys that have no character of their own — the
    /// arrows and function keys live in a private-use area.
    ///
    /// This is data rather than AppKit, so that the mapping is a property the
    /// tests can assert instead of something only a running menu can reveal.
    public var menuKey: String {
        switch key {
        case .character(let character): return String(character)
        case .named(let named): return named.menuKey
        }
    }
}

extension Shortcut.Key {
    fileprivate var text: String {
        switch self {
        case .character(let character): return String(character)
        case .named(let named): return named.text
        }
    }

    /// The key as a person sees it in a menu: `←`, `F5`, `C`.
    public var displayText: String {
        switch self {
        case .character(let character): return String(character).uppercased()
        case .named(let named): return named.displayText
        }
    }
}

extension Shortcut.Key.Named {
    fileprivate var text: String {
        switch self {
        case .returnKey: return "return"
        case .keypadEnter: return "keypadenter"
        case .tab: return "tab"
        case .space: return "space"
        case .escape: return "escape"
        case .delete: return "delete"
        case .forwardDelete: return "forwarddelete"
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageup"
        case .pageDown: return "pagedown"
        case .function(let number): return "f\(number)"
        }
    }

    fileprivate var displayText: String {
        switch self {
        case .returnKey: return "↩"
        case .keypadEnter: return "⌤"
        case .tab: return "⇥"
        case .space: return "Space"
        case .escape: return "⎋"
        case .delete: return "⌫"
        case .forwardDelete: return "⌦"
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        case .function(let number): return "F\(number)"
        }
    }

    /// The key code a menu uses for a key with no character, following the
    /// platform's function-key code points.
    fileprivate var menuKey: String {
        switch self {
        case .returnKey: return "\r"
        case .keypadEnter: return "\u{3}"
        case .tab: return "\t"
        case .space: return " "
        case .escape: return "\u{1B}"
        case .delete: return "\u{8}"
        case .forwardDelete: return "\u{F728}"
        case .left: return "\u{F702}"
        case .right: return "\u{F703}"
        case .up: return "\u{F700}"
        case .down: return "\u{F701}"
        case .home: return "\u{F729}"
        case .end: return "\u{F72B}"
        case .pageUp: return "\u{F72C}"
        case .pageDown: return "\u{F72D}"
        case .function(let number):
            guard let scalar = UnicodeScalar(0xF704 + number - 1) else { return "" }
            return String(Character(scalar))
        }
    }

    /// The virtual key code, so a shortcut can be matched against an event that
    /// has a code but no useful characters.
    fileprivate var keyCode: UInt16? {
        switch self {
        case .returnKey: return Keyboard.Key.returnKey.rawValue
        case .keypadEnter: return Keyboard.Key.keypadEnter.rawValue
        case .tab: return Keyboard.Key.tab.rawValue
        case .space: return 49
        case .escape: return Keyboard.Key.escape.rawValue
        case .delete: return Keyboard.Key.delete.rawValue
        case .forwardDelete: return Keyboard.Key.forwardDelete.rawValue
        case .left: return Keyboard.Key.left.rawValue
        case .right: return Keyboard.Key.right.rawValue
        case .up: return Keyboard.Key.up.rawValue
        case .down: return Keyboard.Key.down.rawValue
        case .home: return Keyboard.Key.home.rawValue
        case .end: return Keyboard.Key.end.rawValue
        case .pageUp: return Keyboard.Key.pageUp.rawValue
        case .pageDown: return Keyboard.Key.pageDown.rawValue
        case .function(let number):
            let keys: [Keyboard.Key] = [
                .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
                .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
            ]
            guard keys.indices.contains(number - 1) else { return nil }
            return keys[number - 1].rawValue
        }
    }
}
