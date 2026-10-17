import NymbraCore

/// The viewport: reading the screen model back out, including scrollback.
///
/// The renderer draws whatever `displayRows` returns, so this is where "can the
/// user scroll up and see their history" is actually decided. It is asserted on
/// the model rather than in the window for exactly that reason.
func viewportSuite(_ h: Harness) {
    h.suite("viewport")

    let screen = Screen(rows: 4, cols: 10)
    let parser = Parser(screen: screen)
    // CRLF, because that is what a program's `\n` arrives as: the tty
    // translates it. Bare LF moves down without returning to column zero. The
    // last line has no newline, so the cursor stays on it instead of scrolling
    // a blank row in.
    for line in 1...7 { parser.feed("line\(line)\r\n") }
    parser.feed("line8")

    h.equal(screen.scrollback.count, 4, "lines that left the screen are kept")

    h.equal(lines(screen, offset: 0), ["line5", "line6", "line7", "line8"],
            "offset zero is the live screen")

    h.equal(lines(screen, offset: 1), ["line4", "line5", "line6", "line7"],
            "one line up reveals one line of history")

    h.equal(lines(screen, offset: 3), ["line2", "line3", "line4", "line5"],
            "three lines up")

    h.equal(lines(screen, offset: 10_000), ["line1", "line2", "line3", "line4"],
            "scrolling past the oldest line clamps instead of running off the end")

    h.equal(lines(screen, offset: -5), ["line5", "line6", "line7", "line8"],
            "a negative offset is the live screen")

    h.equal(screen.displayRows(scrollOffset: 3).count, 4,
            "the viewport is always exactly the height of the screen")

    // An empty scrollback cannot be scrolled into.
    let fresh = Screen(rows: 3, cols: 10)
    fresh.put("x")
    h.equal(lines(fresh, offset: 5), ["x", "", ""],
            "with no history the live screen is what is drawn")

    // History belongs to the primary screen. A full-screen program uses the
    // alternate screen, and its output must not end up in scrollback.
    let alt = Screen(rows: 3, cols: 10)
    let altParser = Parser(screen: alt)
    altParser.feed("primary\r\n")
    altParser.feed("\u{1B}[?1049h")
    for line in 1...6 { altParser.feed("alt\(line)\r\n") }
    h.equal(alt.scrollback.count, 0, "the alternate screen does not fill scrollback")
    altParser.feed("\u{1B}[?1049l")
    h.equal(alt.rowText(0), "primary", "leaving the alternate screen restores history")
}

/// The rows to draw at a scroll offset, as text, trailing blanks trimmed.
private func lines(_ screen: Screen, offset: Int) -> [String] {
    screen.displayRows(scrollOffset: offset).map { line in
        var text = Screen.text(ofLine: line)
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}
