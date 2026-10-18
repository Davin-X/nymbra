import NymbraCore

/// A screen plus the parser that drives it, wired together the same way the
/// application wires them.
private struct Term {
    let screen: Screen
    let parser: Parser

    init(rows: Int = 24, cols: Int = 80) {
        let screen = Screen(rows: rows, cols: cols)
        self.screen = screen
        self.parser = Parser(screen: screen)
    }

    func feed(_ text: String) { parser.feed(text) }
    func feed(_ bytes: [UInt8]) { parser.feed(bytes) }
    func row(_ index: Int, trim: Bool = true) -> String { screen.rowText(index, trim: trim) }
}

/// A stored line rendered to text, with trailing blanks trimmed. Needed for
/// scrollback rows, which are whole grids rather than something the screen
/// can format for us.
private func lineText(_ cells: [Cell]) -> String {
    var text = Screen.text(ofLine: cells)
    while text.hasSuffix(" ") { text.removeLast() }
    return text
}

/// The screen model: cursor, erasing, editing, margins, modes, attributes.
func screenSuite(_ h: Harness) {
    h.suite("Screen")

    // MARK: Text, wrapping, cursor

    do {
        let t = Term(cols: 5)
        t.feed("abcdef")
        h.equal(t.row(0), "abcde", "text fills to the last column")
        h.equal(t.row(1), "f", "the overflow wraps to the next line")
    }

    do {
        let t = Term(cols: 5)
        t.feed("\u{1B}[?7labcdef")
        h.equal(t.row(0), "abcdf", "with DECAWM off the last column is overwritten")
        h.equal(t.row(1), "", "and nothing wraps")
    }

    do {
        let t = Term()
        t.feed("ab\r\ncd")
        h.equal(t.row(0), "ab", "CR LF starts a new line")
        h.equal(t.row(1), "cd", "and the next line is written")
        h.equal(t.screen.cursor.row, 1, "cursor is on the second row")
    }

    do {
        let t = Term()
        t.feed("abc\rX")
        h.equal(t.row(0), "Xbc", "CR returns to column zero")
    }

    do {
        let t = Term()
        t.feed("abc\u{08}X")
        h.equal(t.row(0), "abX", "backspace moves the cursor back")
    }

    do {
        let t = Term()
        t.feed("abc\u{08}\u{08}\u{08}\u{08}")
        h.equal(t.row(0), "abc", "backspace does not erase")
        h.equal(t.screen.cursor.col, 0, "and stops at the left edge")
    }

    do {
        let t = Term()
        t.feed("a\tb")
        h.equal(t.row(0), "a       b", "tab advances to the next multiple of eight")
    }

    do {
        let t = Term()
        t.feed("abc\u{1B}[2DX")
        h.equal(t.row(0), "aXc", "CUB moves left before writing")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[3;5H")
        h.equal(t.screen.cursor.row, 2, "CUP row is 1-based")
        h.equal(t.screen.cursor.col, 4, "CUP column is 1-based")
        t.feed("X")
        h.equal(t.row(2), "    X", "and the write lands there")
    }

    do {
        // A double-width character cannot straddle the last column.
        let t = Term(cols: 4)
        t.feed("abc\u{65E5}")
        h.equal(t.row(0), "abc", "wide character does not split at the right edge")
        h.equal(t.row(1), "\u{65E5}", "it wraps instead")
    }

    do {
        let t = Term()
        t.feed("\u{65E5}x")
        h.equal(t.row(0), "\u{65E5}x", "wide characters advance two columns")
        h.expect(t.screen.cell(row: 0, col: 1).isWideContinuation, "column 1 is a wide continuation")
        h.equal(t.screen.cursor.col, 3, "cursor advanced by two")
    }

    do {
        let t = Term()
        t.feed("\u{65E5}\u{1B}[1GX")
        h.equal(t.row(0), "X", "overwriting a wide character blanks its other half")
        h.expect(t.screen.cell(row: 0, col: 1).isBlank, "the continuation cell was cleared")
    }

    do {
        let t = Term()
        t.feed("e\u{0301}!")
        h.equal(t.row(0), "\u{00E9}!", "a combining mark joins the previous cell")
        h.equal(t.screen.cursor.col, 2, "and takes no column of its own")
    }

    do {
        // Origin mode makes the region's first line row 1 for CUP.
        let t = Term()
        t.feed("\u{1B}[3;5r\u{1B}[?6h\u{1B}[1;1HX")
        h.equal(t.screen.cursor.row, 2, "origin mode makes CUP relative to the region")
        h.equal(t.row(2), "X", "and CUP 1;1 lands on the region's first line")
    }

    // MARK: Erasing

    do {
        let t = Term()
        t.feed("abcdef\u{1B}[3G\u{1B}[0K")
        h.equal(t.row(0), "ab", "EL 0 erases from the cursor to the end")
    }

    do {
        let t = Term()
        t.feed("abcdef\u{1B}[4G\u{1B}[1K")
        h.equal(t.row(0), "    ef", "EL 1 erases from the start up to and including the cursor")
    }

    do {
        let t = Term()
        t.feed("abcdef\u{1B}[2K")
        h.equal(t.row(0), "", "EL 2 erases the whole line")
    }

    do {
        let t = Term()
        t.feed("one\ntwo\nthree\u{1B}[2J")
        h.equal(t.row(0), "", "ED 2 clears the first line")
        h.equal(t.row(2), "", "ED 2 clears the last line")
    }

    do {
        let t = Term()
        t.feed("one\r\ntwo\u{1B}[1;2H\u{1B}[1J")
        h.equal(t.row(0), "  e", "ED 1 erases from the start up to and including the cursor")
        h.equal(t.row(1), "two", "ED 1 leaves the rows below the cursor alone")
    }

    do {
        let t = Term()
        t.feed("one\r\ntwo\u{1B}[1;2H\u{1B}[0J")
        h.equal(t.row(0), "o", "ED 0 erases from the cursor to the end of the line")
        h.equal(t.row(1), "", "ED 0 clears every row below")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[41mX\u{1B}[2K")
        let cell = t.screen.cell(row: 0, col: 5)
        h.equal(cell.attributes.background, .indexed(1), "erasing paints the pen background (BCE)")
    }

    // MARK: Editing

    do {
        let t = Term()
        t.feed("abcdef\u{1B}[3G\u{1B}[2X")
        h.equal(t.row(0), "ab  ef", "ECH blanks characters without moving them")
    }

    do {
        let t = Term()
        t.feed("abcdef\u{1B}[3G\u{1B}[2P")
        h.equal(t.row(0), "abef", "DCH deletes and shifts the rest left")
    }

    do {
        let t = Term()
        t.feed("abcdef\u{1B}[3G\u{1B}[2@")
        h.equal(t.row(0), "ab  cdef", "ICH inserts blanks and shifts right")
    }

    do {
        let t = Term(rows: 3)
        t.feed("one\r\ntwo\r\nthree\u{1B}[2;1H\u{1B}[1L")
        h.equal(t.row(0), "one", "IL leaves the lines above the cursor alone")
        h.equal(t.row(1), "", "IL opens a blank line at the cursor")
        h.equal(t.row(2), "two", "and pushes the rest down")
    }

    do {
        let t = Term(rows: 3)
        t.feed("one\r\ntwo\r\nthree\u{1B}[2;1H\u{1B}[1M")
        h.equal(t.row(1), "three", "DL pulls the following lines up")
        h.equal(t.row(2), "", "DL blanks the last line of the region")
    }

    do {
        let t = Term()
        t.feed("abc\u{1B}[1G\u{1B}[4hX")
        h.equal(t.row(0), "Xabc", "IRM inserts at the cursor, shifting the rest right")
        t.feed("\u{1B}[4lY")
        h.equal(t.row(0), "XYbc", "RM returns to overwriting")
    }

    // MARK: Scrolling and margins

    do {
        let t = Term(rows: 4)
        t.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive")
        h.equal(t.row(0), "two", "the screen scrolls when the cursor passes the bottom")
        h.equal(t.row(3), "five", "new output appears at the bottom")
    }

    do {
        let t = Term(rows: 4)
        t.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive")
        h.equal(t.screen.scrollback.count, 1, "the line that scrolled off is kept")
        h.equal(lineText(t.screen.scrollback[0]), "one", "and it is the right one")
    }

    do {
        h.equal(Screen(rows: 5, cols: 10).scrollback.count, 0, "the scrollback starts empty")
    }

    do {
        let t = Term(rows: 3, cols: 20)
        t.feed("\u{1B}[3;1HROOT")      // a line deliberately outside the region
        t.feed("\u{1B}[1;2r")          // region = the first two rows only
        t.feed("\u{1B}[1;1Hone\r\n\u{1B}[2;1Htwo\r\nthree")
        h.equal(t.row(0), "two", "LF at the bottom margin scrolls the region")
        h.equal(t.row(1), "three", "and the new line arrives at the bottom margin")
        h.equal(t.row(2), "ROOT", "a line outside the region is untouched")
    }

    do {
        let t = Term(rows: 3)
        t.feed("\u{1B}[1;2r\u{1B}[1;1Hone\u{1B}[2;1Htwo\u{1B}[1;1H\u{1B}[1S")
        h.equal(t.row(0), "two", "SU scrolls the region up inside the margins")
    }

    do {
        let t = Term(rows: 4)
        t.feed("top\u{1B}[2;1Hmid\u{1B}[2;1H\u{1B}[1M")
        h.equal(t.row(1), "", "DL inside a full-screen region blanks the line")
    }

    do {
        let t = Term(rows: 4)
        t.feed("a\r\nb\u{1B}[1;1H\u{1B}[1M")
        h.equal(t.row(0), "b", "DL at the top pulls the next line up")
        h.equal(t.row(3), "", "and blanks the bottom")
    }

    do {
        let t = Term(rows: 3)
        t.feed("one\ntwo\u{1B}[2;1H\u{1B}[1M")
        h.equal(t.row(1), "", "DL at row 1 with two rows used clears row 1")
    }

    do {
        let t = Term(rows: 4)
        t.feed("one\ntwo\u{1B}[1;1H\u{1B}M")
        h.equal(t.row(0), "", "RI at the top margin scrolls down")
        h.equal(t.row(1), "one", "pushing the first line down")
    }

    do {
        let t = Term(rows: 3)
        t.feed("\u{1B}[2;1HX\u{1B}MY")
        h.equal(t.row(0), " Y", "RI moves the cursor up when it is below the top margin")
        h.equal(t.row(1), "X", "leaving the line it came from")
    }

    // MARK: Cursor save and restore

    do {
        let t = Term()
        t.feed("\u{1B}[31mA\u{1B}7\u{1B}[5;5H\u{1B}[32mB\u{1B}8C")
        h.equal(t.row(0), "AC", "DECRC returns to the saved position")
        h.equal(t.screen.cell(row: 0, col: 1).attributes.foreground, .indexed(1),
                "and restores the pen")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[5;5H\u{1B}[s\u{1B}[1;1H\u{1B}[uX")
        h.equal(t.screen.cursor.row, 4, "SCOSC/SCORC save and restore")
    }

    // MARK: Attributes

    do {
        let t = Term()
        t.feed("\u{1B}[1;3;4;9;7mX")
        let attributes = t.screen.cell(row: 0, col: 0).attributes
        h.expect(attributes.bold, "SGR 1 sets bold")
        h.expect(attributes.italic, "SGR 3 sets italic")
        h.equal(attributes.underline, .single, "SGR 4 sets underline")
        h.expect(attributes.strike, "SGR 9 sets strike")
        h.expect(attributes.inverse, "SGR 7 sets inverse")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[31;42;1mX\u{1B}[0mY")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.foreground, .indexed(1), "SGR 31 is red")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.background, .indexed(2), "SGR 42 is green")
        h.equal(t.screen.cell(row: 0, col: 1).attributes, Attributes(), "SGR 0 resets everything")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[38;5;200mX")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.foreground, .indexed(200),
                "38;5 selects a palette entry")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[38;2;10;20;30mX")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.foreground, .rgb(r: 10, g: 20, b: 30),
                "38;2 selects truecolour")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[48:2::255:0:128mX")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.background, .rgb(r: 255, g: 0, b: 128),
                "38/48 accept the colon form with a colour-space slot")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[4:3mX")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.underline, .curly,
                "SGR 4:x selects an underline style")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[1;2;3;4;5;7;8;9;21m\u{1B}[22;23;24;25;27;28;29mX")
        h.equal(t.screen.cell(row: 0, col: 0).attributes, Attributes(),
                "the SGR reset codes clear every attribute")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[91;102mX")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.foreground, .indexed(9),
                "bright foreground colours start at index 8")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.background, .indexed(10),
                "bright background colours start at index 8")
    }

    // MARK: Modes and screens

    do {
        let t = Term()
        t.feed("primary\u{1B}[?1049h\u{1B}[1;1Halt")
        h.equal(t.row(0), "alt", "the alternate screen starts blank")
        h.expect(t.screen.altScreenActive, "and is active")
        t.feed("\u{1B}[?1049l")
        h.equal(t.row(0), "primary", "leaving restores the primary screen")
        h.expect(!t.screen.altScreenActive, "and the mode is off again")
        h.equal(t.screen.cursor.col, 7, "the cursor is restored too")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[?25l")
        h.expect(!t.screen.cursor.visible, "DECTCEM hides the cursor")
        t.feed("\u{1B}[?25h")
        h.expect(t.screen.cursor.visible, "and shows it again")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[?1000h")
        h.equal(t.screen.mouseMode, .click, "1000 enables click reporting")
        t.feed("\u{1B}[?1002h")
        h.equal(t.screen.mouseMode, .drag, "1002 enables drag reporting")
        t.feed("\u{1B}[?1000l")
        h.equal(t.screen.mouseMode, .off, "and disabling turns it off")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[?2004h")
        h.expect(t.screen.bracketedPaste, "2004 enables bracketed paste")
        t.feed("\u{1B}[?1004h")
        h.expect(t.screen.focusReporting, "1004 enables focus reporting")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[?5h")
        h.expect(t.screen.reverseVideo, "DECSCNM is recorded")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[?6h\u{1B}[2;1H")
        h.equal(t.screen.cursor.row, 1, "origin mode makes CUP relative to the region")
        t.feed("\u{1B}[?6l")
        h.equal(t.screen.cursor.row, 0, "and leaving origin mode homes the cursor")
    }

    // MARK: Character sets

    do {
        let t = Term()
        t.feed("\u{1B}(0q\u{1B}(Bq")
        h.equal(t.row(0), "\u{2500}q", "DEC special graphics maps box drawing, and back")
    }

    do {
        let t = Term()
        t.feed("\u{1B})0\u{0E}q\u{0F}q")
        h.equal(t.row(0), "\u{2500}q", "SO selects G1 and SI returns to G0")
    }

    // MARK: Tab stops

    do {
        let t = Term()
        t.feed("\u{1B}[3g\u{1B}[5G\u{1B}H\u{1B}[1G")
        h.equal(t.screen.cursor.col, 0, "CHA 1 is column zero")
        t.feed("\t")
        h.equal(t.screen.cursor.col, 4, "tab reaches the stop set by HTS")
        t.feed("\t")
        h.equal(t.screen.cursor.col, 79, "past the last stop, tab goes to the last column")
    }

    do {
        let t = Term()
        t.feed("\u{1B}[3gq")
        t.feed("\t")
        h.equal(t.screen.cursor.col, 79, "TBC 3 clears every stop, so tab runs to the last column")
    }

    // MARK: Whole-screen

    do {
        let t = Term(rows: 2, cols: 3)
        t.feed("\u{1B}#8")
        h.equal(t.row(0), "EEE", "DECALN fills the screen with E")
        h.equal(t.row(1), "EEE", "on every row")
    }

    do {
        let t = Term()
        t.feed("text\u{1B}c")
        h.equal(t.row(0), "", "RIS clears the screen")
        h.equal(t.screen.cursor.row, 0, "and homes the cursor")
        h.equal(t.screen.scrollback.count, 0, "and drops the scrollback")
    }

    // MARK: Resize

    do {
        let t = Term(rows: 3, cols: 10)
        t.feed("abcdef")
        t.screen.resize(rows: 5, cols: 4)
        h.equal(t.screen.rows, 5, "resize changes the row count")
        h.equal(t.screen.cols, 4, "resize changes the column count")
        h.equal(t.row(0), "abcd", "content that fits is preserved")
        h.equal(t.screen.cursor.col, 3, "the cursor is clamped into the new grid")
    }

    do {
        let t = Term(rows: 5, cols: 10)
        t.feed("one\ntwo\nthree")
        t.screen.resize(rows: 2, cols: 10)
        h.equal(t.screen.rows, 2, "shrinking reduces the grid")
        h.equal(t.row(0), "one", "and keeps the top lines")
        h.equal(t.screen.scrollBottom, 1, "the scrolling region is clamped to fit")
    }

    do {
        let t = Term(rows: 2, cols: 4)
        t.feed("abc\u{65E5}")
        t.screen.resize(rows: 2, cols: 4)
        h.equal(t.row(0), "abc", "a wide character at the right edge is not split by resize")
    }

    do {
        let t = Term(rows: 2, cols: 3)
        t.feed("abcd")
        t.screen.resize(rows: 2, cols: 3)
        h.equal(t.row(0), "abc", "resize is a no-op when the size is unchanged")
    }

    do {
        let t = Term(rows: 2, cols: 5)
        t.feed("abcdefghij")
        h.equal(t.row(0), "abcde", "text fills to the last column")
        h.equal(t.row(1), "fghij", "the overflow wraps to the next line")
        t.screen.resize(rows: 2, cols: 10)
        h.equal(t.row(0), "abcdefghij", "widening joins the lines the terminal wrapped")
        h.equal(t.row(1), "", "and leaves the following row blank")
    }

    do {
        let t = Term(rows: 2, cols: 10)
        t.feed("abcdefghij")
        t.screen.resize(rows: 2, cols: 5)
        h.equal(t.row(0), "abcde", "narrowing re-wraps at the new width")
        h.equal(t.row(1), "fghij", "and keeps the overflow")
    }

    do {
        let t = Term(rows: 2, cols: 10)
        t.feed("abc\r\ndef")
        t.screen.resize(rows: 2, cols: 5)
        h.equal(t.row(0), "abc", "a hard newline is not joined by reflow")
        h.equal(t.row(1), "def", "it stays where it was")
    }

    // MARK: - Find

    do {
        let t = Term(rows: 5, cols: 20)
        t.feed("Hello world\nHello universe\nHello find me\n")
        // Push some lines to scrollback
        for _ in 0..<3 { t.screen.scrollUp(1) }

        // Search in scrollback
        var foundInScrollback = false
        for row in t.screen.scrollback {
            let text = Screen.text(ofLine: row).lowercased()
            if text.contains("hello") {
                foundInScrollback = true
            }
        }
        h.expect(foundInScrollback, "find locates 'hello' in scrollback")

        // Search in live screen
        var foundInLive = false
        for row in 0..<t.screen.rows {
            let text = t.screen.rowText(row).lowercased()
            if text.contains("find me") {
                foundInLive = true
            }
        }
        h.expect(foundInLive, "find locates 'find me' in live screen")
    }
}
