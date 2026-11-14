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

    // Where the viewport starts, in absolute rows. Nothing draws from this but
    // the find highlight, which is drawn cell by cell *over* the text — so if
    // this disagrees with `displayRows`, the highlight is painted a screenful
    // away from the match, or not at all. That is a silent failure of exactly
    // the kind the two functions are supposed to share an answer about.
    let combined = screen.scrollback + screen.displayRows(scrollOffset: 0)
    for offset in [-5, 0, 1, 3, 10_000] {
        let drawn = screen.displayRows(scrollOffset: offset)
        let first = screen.viewportFirstRow(scrollOffset: offset)
        h.equal(drawn.map { Screen.text(ofLine: $0) },
                (first..<(first + drawn.count)).map { Screen.text(ofLine: combined[$0]) },
                "the viewport starts where it says it starts (offset \(offset))")
    }

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

    // MARK: A full history is a ring, not a queue

    // Once full, each new line overwrites the oldest one in place. What a
    // reader sees must be exactly what the old shift-everything array showed:
    // the newest `limit` lines, oldest first.
    let ring = Screen(rows: 2, cols: 10)
    ring.scrollbackLimit = 3
    let ringParser = Parser(screen: ring)
    for line in 1...9 { ringParser.feed("r\(line)\r\n") }
    ringParser.feed("r10")
    h.equal(ring.scrollback.count, 3, "a full history holds exactly its limit")
    h.equal(history(ring), ["r6", "r7", "r8"],
            "and holds the newest lines, oldest first, after wrapping round")
    h.equal(ring.scrollback.appendedCount, 8, "every line that ever entered is counted")
    h.equal(lines(ring, offset: 3), ["r6", "r7"], "the viewport reads through the wrap point")
    h.equal(lines(ring, offset: 1), ["r8", "r9"], "and across into the live screen")

    ring.scrollbackLimit = 2
    ringParser.feed("\r\nr11")
    h.equal(history(ring), ["r8", "r9"],
            "lowering the limit trims the oldest lines on the next one in")
    ring.scrollbackLimit = 4
    ringParser.feed("\r\nr12\r\nr13")
    h.equal(history(ring), ["r8", "r9", "r10", "r11"],
            "raising it lets the history grow again, in order")

    ringParser.feed("\u{1B}[3J")
    h.equal(ring.scrollback.count, 0, "ED 3 still clears it")
    ringParser.feed("\r\nr14")
    h.equal(history(ring), ["r12"], "and it fills again afterwards")

    // MARK: A taller window still keeps history

    // The shell starts in whatever grid the view had first, and the window then
    // grows. The scroll region has to grow with it, or the bottom rows sit
    // outside it and no line is ever captured again.
    let grown = Screen(rows: 3, cols: 10)
    let grownParser = Parser(screen: grown)
    grown.resize(rows: 6, cols: 10)
    h.equal(grown.scrollBottom, 5, "growing the screen grows the scroll region with it")
    for line in 1...10 { grownParser.feed("g\(line)\r\n") }
    h.equal(grown.scrollback.count, 5, "and lines still scroll into history afterwards")
    grownParser.feed("\u{1B}[2;4r")
    grown.resize(rows: 4, cols: 10)
    h.equal(grown.scrollTop, 0, "a resize resets a program's region to the whole screen")

    // MARK: Reading history while output arrives

    h.equal(Screen.pinnedScrollOffset(0, linesAppended: 5, historyCount: 100), 0,
            "the live screen follows new output")
    h.equal(Screen.pinnedScrollOffset(10, linesAppended: 5, historyCount: 100), 15,
            "a viewport up in history moves up with it, so the lines under it stay put")
    h.equal(Screen.pinnedScrollOffset(98, linesAppended: 5, historyCount: 100), 100,
            "but never past the oldest line held")
    h.equal(Screen.pinnedScrollOffset(40, linesAppended: 0, historyCount: 0), 0,
            "a history cleared underneath the viewport leaves nothing to look at")

    // The same rule, end to end: the line on screen is the line on screen.
    let reading = Screen(rows: 2, cols: 10)
    reading.scrollbackLimit = 5
    let readingParser = Parser(screen: reading)
    for line in 1...6 { readingParser.feed("p\(line)\r\n") }
    var offset = 2
    let before = lines(reading, offset: offset)
    let seen = reading.scrollback.appendedCount
    for line in 7...9 { readingParser.feed("p\(line)\r\n") }
    offset = Screen.pinnedScrollOffset(offset,
                                       linesAppended: reading.scrollback.appendedCount - seen,
                                       historyCount: reading.scrollback.count)
    h.equal(lines(reading, offset: offset), before,
            "new output does not slide the history being read, even as the oldest drops off")
}

/// The rows to draw at a scroll offset, as text, trailing blanks trimmed.
private func lines(_ screen: Screen, offset: Int) -> [String] {
    screen.displayRows(scrollOffset: offset).map { line in
        var text = Screen.text(ofLine: line)
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}

/// The scrollback, as text, oldest first, trailing blanks trimmed.
private func history(_ screen: Screen) -> [String] {
    screen.scrollback.map { line in
        var text = Screen.text(ofLine: line)
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}
