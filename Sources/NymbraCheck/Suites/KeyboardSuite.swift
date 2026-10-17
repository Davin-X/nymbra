import NymbraInput

/// The keyboard mapping, asserted without a window. This is the table that
/// decides whether arrows, function keys and control combinations work in the
/// programs people actually run, so it is tested directly rather than through
/// the view.
func keyboardSuite(_ h: Harness) {
    h.suite("keyboard")

    // MARK: Characters

    h.equal(key(0, "a"), [0x61], "a plain letter is itself")
    h.equal(key(0, "é"), [0xC3, 0xA9], "a non-ASCII character is UTF-8")
    h.equal(key(0, "日本"), [0xE6, 0x97, 0xA5, 0xE6, 0x9C, 0xAC], "wide characters are UTF-8")
    h.equal(key(0, nil), [], "a key with no character and no mapping sends nothing")

    // MARK: Enter, tab, delete, escape

    h.equal(key(36), [0x0D], "return sends CR")
    h.equal(key(76), [0x0D], "keypad enter sends CR")
    h.equal(key(51), [0x7F], "delete sends DEL")
    h.equal(key(117), esc("[3~"), "forward delete")
    h.equal(key(48), [0x09], "tab sends HT")
    h.equal(key(48, modifiers: .shift), esc("[Z"), "shift-tab is CBT")
    h.equal(key(53), [0x1B], "escape")

    // MARK: Cursor keys, with DECCKM

    h.equal(key(126), esc("[A"), "up")
    h.equal(key(125), esc("[B"), "down")
    h.equal(key(124), esc("[C"), "right")
    h.equal(key(123), esc("[D"), "left")
    h.equal(key(115), esc("[H"), "home")
    h.equal(key(119), esc("[F"), "end")
    h.equal(key(116), esc("[5~"), "page up")
    h.equal(key(121), esc("[6~"), "page down")

    h.equal(key(126, applicationCursorKeys: true), [0x1B, 0x4F, 0x41],
            "up in application mode is SS3")

    // MARK: Modified cursor keys

    // xterm encodes the modifier as a parameter, which is what every editor
    // binds word-wise movement to.
    h.equal(key(123, modifiers: .control), esc("[1;5D"), "ctrl-left is a word left")
    h.equal(key(124, modifiers: .option), esc("[1;3C"), "option-right")
    h.equal(key(126, modifiers: .shift), esc("[1;2A"), "shift-up")
    h.equal(key(115, modifiers: .control), esc("[1;5H"), "ctrl-home")

    // MARK: Function keys

    // htop, midnight commander and friends are unusable without these.
    h.equal(key(122), esc("OP"), "F1")
    h.equal(key(120), esc("OQ"), "F2")
    h.equal(key(99), esc("OR"), "F3")
    h.equal(key(118), esc("OS"), "F4")
    h.equal(key(96), esc("[15~"), "F5")
    h.equal(key(100), esc("[19~"), "F8")
    h.equal(key(101), esc("[20~"), "F9")
    h.equal(key(109), esc("[21~"), "F10")
    h.equal(key(111), esc("[24~"), "F12")
    h.equal(key(105), esc("[25~"), "F13")
    h.equal(key(90), esc("[34~"), "F20")

    h.equal(key(122, modifiers: .shift), esc("[1;2P"), "shift-F1")
    h.equal(key(96, modifiers: .shift), esc("[15;2~"), "shift-F5")

    // Every function key must produce something, so none is silently dead.
    let functionKeys: [Keyboard.Key] = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
        .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
    ]
    for functionKey in functionKeys {
        h.expect(!key(functionKey.rawValue).isEmpty, "\(functionKey) maps to a sequence")
    }

    // MARK: Control combinations

    h.equal(characters("a", modifiers: .control), [0x01], "ctrl-a is 0x01")
    h.equal(characters("c", modifiers: .control), [0x03], "ctrl-c is 0x03")
    h.equal(characters("d", modifiers: .control), [0x04], "ctrl-d is 0x04")
    h.equal(characters("z", modifiers: .control), [0x1A], "ctrl-z is 0x1A")
    h.equal(characters("[", modifiers: .control), [0x1B], "ctrl-[ is ESC")
    h.equal(characters("\\", modifiers: .control), [0x1C], "ctrl-\\ is FS")
    h.equal(characters(" ", modifiers: .control), [0x00], "ctrl-space is NUL")
    h.equal(characters("?", modifiers: .control), [0x7F], "ctrl-? is DEL")

    // MARK: Meta and Command

    h.equal(characters("f", modifiers: .option), esc("f"), "option-f is ESC f, which readline reads as M-f")
    h.equal(characters("c", modifiers: .command), [], "a command chord belongs to the application")
}

// MARK: - Helpers

private func esc(_ text: String) -> [UInt8] { [0x1B] + Array(text.utf8) }

/// A key that produces a character.
private func characters(
    _ text: String,
    modifiers: Keyboard.Modifiers = []
) -> [UInt8] {
    key(0, text, modifiers: modifiers)
}

/// Key codes are hardware positions; the tests name them through `Keyboard.Key`
/// where one exists, and pass 0 for the "some character key" case.
private func key(
    _ keyCode: UInt16,
    _ text: String? = nil,
    modifiers: Keyboard.Modifiers = [],
    applicationCursorKeys: Bool = false
) -> [UInt8] {
    Keyboard.bytes(
        keyCode: keyCode,
        characters: text,
        charactersIgnoringModifiers: text,
        modifiers: modifiers,
        applicationCursorKeys: applicationCursorKeys
    )
}
