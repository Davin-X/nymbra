// Keyboard mapping: a key press in, the bytes a terminal sends out.
//
// This deliberately lives outside the app target. "Arrows and function keys
// work" is a property of this table, not of a window, so it has to be
// assertable headlessly — see `NymbraCheck/Suites/KeyboardSuite.swift`.
//
// No AppKit type appears here. The view converts `NSEvent` into these plain
// values at the boundary, which is the only place that knows about AppKit.
//
// The encodings are xterm's, which is what `TERM=xterm-256color` promises the
// program on the other end.

public enum Keyboard {

    /// Modifier keys, mirroring what the platform reports.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift   = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// Virtual key codes for the keys that do not produce a character.
    ///
    /// These are hardware positions rather than characters, which is why they
    /// are spelled out once, here, instead of by hand at each use site.
    public enum Key: UInt16, CaseIterable, Sendable {
        case returnKey = 36
        case keypadEnter = 76
        case tab = 48
        case delete = 51
        case forwardDelete = 117
        case escape = 53

        case up = 126
        case down = 125
        case left = 123
        case right = 124
        case home = 115
        case end = 119
        case pageUp = 116
        case pageDown = 121

        case f1 = 122
        case f2 = 120
        case f3 = 99
        case f4 = 118
        case f5 = 96
        case f6 = 97
        case f7 = 98
        case f8 = 100
        case f9 = 101
        case f10 = 109
        case f11 = 103
        case f12 = 111
        case f13 = 105
        case f14 = 107
        case f15 = 113
        case f16 = 106
        case f17 = 64
        case f18 = 79
        case f19 = 80
        case f20 = 90
    }

    /// The bytes to send for a key press.
    ///
    /// Returns nothing for a Command chord, which belongs to the application
    /// (Cmd+C copies, Cmd+V pastes), and for a key that produces nothing.
    public static func bytes(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: Modifiers = [],
        applicationCursorKeys: Bool = false
    ) -> [UInt8] {
        if modifiers.contains(.command) { return [] }

        if let key = Key(rawValue: keyCode),
           let sequence = bytes(for: key, modifiers: modifiers, applicationCursorKeys: applicationCursorKeys) {
            return sequence
        }

        // Control characters are computed from the character rather than read
        // out of `characters`, so behaviour does not depend on what the toolkit
        // happens to place there for a given layout.
        if modifiers.contains(.control),
           let scalar = charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
           let control = controlByte(for: scalar) {
            return [control]
        }

        guard let characters, !characters.isEmpty else { return [] }
        let utf8 = Array(characters.utf8)
        // Option is the meta key: ESC first, which is what readline expects for
        // M-f, M-b and friends.
        return modifiers.contains(.option) ? [0x1B] + utf8 : utf8
    }

    // MARK: - Special keys

    private static func bytes(
        for key: Key,
        modifiers: Modifiers,
        applicationCursorKeys: Bool
    ) -> [UInt8]? {
        switch key {
        case .returnKey, .keypadEnter: return [0x0D]
        case .tab:
            // Shift-Tab is CBT, not Tab with a modifier.
            return modifiers.contains(.shift) ? escape("[Z") : [0x09]
        case .delete:        return [0x7F]
        case .forwardDelete: return escape("[3~")
        case .escape:        return [0x1B]

        case .up:       return cursorKey(0x41, modifiers, applicationCursorKeys)
        case .down:     return cursorKey(0x42, modifiers, applicationCursorKeys)
        case .right:    return cursorKey(0x43, modifiers, applicationCursorKeys)
        case .left:     return cursorKey(0x44, modifiers, applicationCursorKeys)
        case .home:     return cursorKey(0x48, modifiers, applicationCursorKeys)
        case .end:      return cursorKey(0x46, modifiers, applicationCursorKeys)
        case .pageUp:   return pageKey(5, modifiers)
        case .pageDown: return pageKey(6, modifiers)

        default:
            guard let function = functionKeys[key] else { return nil }
            return functionKey(function.number, finalByte: function.finalByte,
                               usesSS3: function.usesSS3, modifiers: modifiers)
        }
    }

    /// Cursor keys. Unmodified they are `ESC O x` in application mode (DECCKM)
    /// and `ESC [ x` otherwise. With a modifier, xterm adds the modifier as a
    /// parameter instead, so Ctrl+Left is `ESC [ 1 ; 5 D` — which is what
    /// readline and every editor bind word-movement to.
    private static func cursorKey(
        _ finalByte: UInt8,
        _ modifiers: Modifiers,
        _ applicationCursorKeys: Bool
    ) -> [UInt8] {
        let parameter = modifierParameter(modifiers)
        if parameter == 1 {
            return applicationCursorKeys
                ? [0x1B, 0x4F, finalByte]
                : [0x1B, 0x5B, finalByte]
        }
        return escape("[1;\(parameter)") + [finalByte]
    }

    private static func pageKey(_ number: Int, _ modifiers: Modifiers) -> [UInt8] {
        let parameter = modifierParameter(modifiers)
        if parameter == 1 { return escape("[\(number)~") }
        return escape("[\(number);\(parameter)~")
    }

    /// F1–F4 are `ESC O x` unmodified and `ESC [ 1 ; m x` modified. F5 onwards
    /// are `ESC [ n ~` and `ESC [ n ; m ~`.
    private static func functionKey(
        _ number: Int,
        finalByte: UInt8,
        usesSS3: Bool,
        modifiers: Modifiers
    ) -> [UInt8] {
        let parameter = modifierParameter(modifiers)
        if parameter == 1 {
            return usesSS3
                ? [0x1B, 0x4F, finalByte]
                : escape("[\(number)") + [finalByte]
        }
        let prefix = usesSS3 ? 1 : number
        return escape("[\(prefix);\(parameter)") + [finalByte]
    }

    /// xterm's modifier parameter: one plus shift(1), option(2) and control(4).
    private static func modifierParameter(_ modifiers: Modifiers) -> Int {
        var parameter = 1
        if modifiers.contains(.shift) { parameter += 1 }
        if modifiers.contains(.option) { parameter += 2 }
        if modifiers.contains(.control) { parameter += 4 }
        return parameter
    }

    // MARK: - Tables

    private struct FunctionKey {
        let number: Int
        let finalByte: UInt8
        /// F1–F4 use the SS3 form, `ESC O P` rather than `ESC [ 11 ~`.
        let usesSS3: Bool
    }

    private static let functionKeys: [Key: FunctionKey] = [
        .f1:  FunctionKey(number: 1,  finalByte: UInt8(ascii: "P"), usesSS3: true),
        .f2:  FunctionKey(number: 2,  finalByte: UInt8(ascii: "Q"), usesSS3: true),
        .f3:  FunctionKey(number: 3,  finalByte: UInt8(ascii: "R"), usesSS3: true),
        .f4:  FunctionKey(number: 4,  finalByte: UInt8(ascii: "S"), usesSS3: true),
        .f5:  FunctionKey(number: 15, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f6:  FunctionKey(number: 17, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f7:  FunctionKey(number: 18, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f8:  FunctionKey(number: 19, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f9:  FunctionKey(number: 20, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f10: FunctionKey(number: 21, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f11: FunctionKey(number: 23, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f12: FunctionKey(number: 24, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f13: FunctionKey(number: 25, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f14: FunctionKey(number: 26, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f15: FunctionKey(number: 28, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f16: FunctionKey(number: 29, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f17: FunctionKey(number: 31, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f18: FunctionKey(number: 32, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f19: FunctionKey(number: 33, finalByte: UInt8(ascii: "~"), usesSS3: false),
        .f20: FunctionKey(number: 34, finalByte: UInt8(ascii: "~"), usesSS3: false),
    ]

    // MARK: - Helpers

    private static func escape(_ text: String) -> [UInt8] { [0x1B] + Array(text.utf8) }

    /// `Ctrl+A` is `0x01` because the control key clears the top three bits of
    /// the character. `Ctrl+Space` and `Ctrl+?` are the two exceptions.
    private static func controlByte(for scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case " ": return 0x00
        case "?": return 0x7F
        default:
            // '@' through '_' and 'a' through 'z': clear the top three bits.
            switch scalar.value {
            case 0x40...0x5F, 0x60...0x7A: return UInt8(scalar.value & 0x1F)
            default: return nil
            }
        }
    }
}
