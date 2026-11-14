import NymbraCore
import NymbraInput

/// Composing text, and drawing a frame all at once.
///
/// Which keys go through the system's input method is a rule, asserted here;
/// what the input method does with them is the system's. Synchronized output
/// (DEC 2026) is a mode the screen keeps and reports, asserted on the model.
func inputMethodSuite(_ h: Harness) {
    h.suite("input method")

    func routes(_ key: UInt16, _ modifiers: Keyboard.Modifiers = [], composing: Bool = false) -> Bool {
        Keyboard.routesThroughInputMethod(keyCode: key, modifiers: modifiers, isComposing: composing)
    }
    let letterA: UInt16 = 0
    let letterE: UInt16 = 14
    let space: UInt16 = 49

    h.expect(routes(letterA), "a letter goes to the input method, which may compose with it")
    h.expect(routes(letterA, .shift), "so does a shifted one")
    h.expect(routes(space), "and space, which an input method uses to convert")
    h.expect(!routes(letterA, .control), "⌃A is a control code, not text")
    h.expect(!routes(letterE, .option), "Option is Meta, as the key table has always sent it")
    for key in [Keyboard.Key.returnKey, .tab, .delete, .escape, .up, .down, .left, .right, .f1, .home] {
        h.expect(!routes(key.rawValue), "\(key) goes straight to the key table when nothing is composed")
        h.expect(routes(key.rawValue, composing: true),
                 "\(key) goes to the input method while composing — it commits, cancels or chooses")
    }
    h.expect(routes(letterA, .control, composing: true), "while composing, even chords belong to it")

    // MARK: Synchronized output

    let screen = Screen(rows: 3, cols: 20)
    let parser = Parser(screen: screen)
    var replies: [String] = []
    parser.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }

    parser.feed("\u{1B}[?2026$p")
    h.equal(replies.last, "\u{1B}[?2026;2$y", "DECRQM says 2026 is known, and off")
    parser.feed("\u{1B}[?2026h")
    h.expect(screen.synchronizedOutput, "BSU starts a frame")
    parser.feed("\u{1B}[?2026$p")
    h.equal(replies.last, "\u{1B}[?2026;1$y", "and DECRQM reports it as set")
    parser.feed("\u{1B}[?2026l")
    h.expect(!screen.synchronizedOutput, "ESU ends it")
    parser.feed("\u{1B}[?2026h\u{1B}c")
    h.expect(!screen.synchronizedOutput, "a full reset cannot leave the view frozen mid-frame")

    parser.feed("\u{1B}[?2004h\u{1B}[?2004$p")
    h.equal(replies.last, "\u{1B}[?2004;1$y", "DECRQM answers for other modes too")
    parser.feed("\u{1B}[?9999$p")
    h.equal(replies.last, "\u{1B}[?9999;0$y", "and says so honestly for a mode it does not know")
}
