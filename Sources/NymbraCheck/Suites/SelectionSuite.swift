import NymbraCore

/// A screen plus the parser that drives it, wired the way the app wires them.
private struct Term {
    let screen: Screen
    let parser: Parser

    init(rows: Int = 4, cols: Int = 20) {
        let screen = Screen(rows: rows, cols: cols)
        self.screen = screen
        self.parser = Parser(screen: screen)
    }

    func feed(_ text: String) { parser.feed(text) }
}

/// Selection: which cells are highlighted, and what text that becomes.
///
/// Text extraction is the part that matters — a selection you cannot paste is
/// decoration — so it is asserted here rather than by looking at a highlight.
func selectionSuite(_ h: Harness) {
    h.suite("selection")

    // MARK: Order and emptiness

    let backwards = Selection(anchor: .init(row: 2, col: 5), head: .init(row: 0, col: 1))
    h.equal(backwards.ordered.start, .init(row: 0, col: 1), "a drag upwards reads in reading order")
    h.equal(backwards.ordered.end, .init(row: 2, col: 5), "a drag upwards ends where it began")

    let forwards = Selection(anchor: .init(row: 0, col: 1), head: .init(row: 2, col: 5))
    h.equal(forwards.ordered.start, .init(row: 0, col: 1), "a drag downwards reads in reading order")
    h.equal(forwards.ordered.end, .init(row: 2, col: 5), "a drag downwards ends where the pointer is")

    h.expect(Selection(row: 1, col: 1).isEmpty, "a click with no drag is a one-cell selection")
    h.expect(!Selection(anchor: .init(row: 0, col: 0), head: .init(row: 0, col: 1)).isEmpty,
             "a one-cell drag selects something")
    h.equal(Selection(row: 1, col: 1).text(in: Term().screen), "",
            "a one-cell selection of a blank cell copies nothing")

    // MARK: Which cells are highlighted

    let block = Selection(anchor: .init(row: 1, col: 2), head: .init(row: 3, col: 4))
    h.expect(block.contains(row: 2, col: 0), "a middle row is selected from edge to edge")
    h.expect(block.contains(row: 2, col: 19), "a middle row is selected past the text")
    h.expect(!block.contains(row: 1, col: 1), "the first row is not selected before the anchor")
    h.expect(block.contains(row: 1, col: 2), "the first row is selected at the anchor")
    h.expect(!block.contains(row: 3, col: 5), "the last row is not selected past the head")
    h.expect(block.contains(row: 3, col: 4), "the last row is selected at the head")
    h.expect(!block.contains(row: 0, col: 2), "rows before the selection are not selected")
    h.expect(!block.contains(row: 4, col: 2), "rows after the selection are not selected")

    let single = Selection(anchor: .init(row: 0, col: 3), head: .init(row: 0, col: 5))
    h.expect(single.contains(row: 0, col: 3), "a one-row selection includes its first cell")
    h.expect(single.contains(row: 0, col: 5), "a one-row selection includes its last cell")
    h.expect(!single.contains(row: 0, col: 6), "a one-row selection stops at its last cell")
    h.expect(!single.contains(row: 1, col: 4), "a one-row selection does not spill onto the next row")

    // MARK: Text

    do {
        let t = Term()
        t.feed("hello world")
        let word = Selection(anchor: .init(row: 0, col: 0), head: .init(row: 0, col: 4))
        h.equal(word.text(in: t.screen), "hello", "a partial row copies exactly what was selected")

        let rest = Selection(anchor: .init(row: 0, col: 6), head: .init(row: 0, col: 19))
        h.equal(rest.text(in: t.screen), "world",
                "trailing blanks are trimmed, so a line does not drag its padding along")
    }

    do {
        let t = Term()
        t.feed("  indented")
        let all = Selection(anchor: .init(row: 0, col: 0), head: .init(row: 0, col: 19))
        h.equal(all.text(in: t.screen), "  indented", "leading blanks are kept, so indentation survives")
    }

    do {
        let t = Term()
        t.feed("one\r\ntwo\r\nthree")
        let rows = Selection(anchor: .init(row: 0, col: 0), head: .init(row: 2, col: 4))
        h.equal(rows.text(in: t.screen), "one\ntwo\nthree", "a multi-line selection joins with newlines")

        let partial = Selection(anchor: .init(row: 0, col: 2), head: .init(row: 2, col: 2))
        h.equal(partial.text(in: t.screen), "e\ntwo\nthr",
                "a multi-line selection takes the tail, whole rows, then the head")
    }

    do {
        let t = Term()
        t.feed("日本語")  // three wide characters, six columns
        let all = Selection(anchor: .init(row: 0, col: 0), head: .init(row: 0, col: 5))
        h.equal(all.text(in: t.screen), "日本語",
                "the second half of a wide character is not copied twice")
    }

    // MARK: Scrollback

    do {
        let t = Term(rows: 2, cols: 5)
        t.feed("a\r\nb\r\nc")
        let first = Selection(anchor: .init(row: 0, col: 0), head: .init(row: 0, col: 0))
        h.equal(first.text(in: t.screen), "b", "a selection on the live screen reads the live screen")
        h.equal(first.text(in: t.screen, scrollOffset: 1), "a",
                "the same selection reads scrollback when the viewport is scrolled up")
    }

    // MARK: Double-click and triple-click

    do {
        let t = Term()
        t.feed("git commit -m msg")
        let token = Selection.word(in: t.screen, row: 0, col: 5)
        h.equal(token.text(in: t.screen), "commit", "a double-click takes the whole token")

        let edge = Selection.word(in: t.screen, row: 0, col: 0)
        h.equal(edge.text(in: t.screen), "git", "a double-click at the start of a token takes all of it")

        let space = Selection.word(in: t.screen, row: 0, col: 3)
        h.equal(space.text(in: t.screen), "", "a double-click on blank space selects nothing")

        let line = Selection.line(in: t.screen, row: 0)
        h.equal(line.text(in: t.screen), "git commit -m msg", "a triple-click takes the whole line")
    }

    // MARK: Select All

    do {
        let t = Term(rows: 4, cols: 20)
        t.feed("first\r\nsecond")
        let all = Selection.all(of: t.screen)
        h.equal(all.text(in: t.screen), "first\nsecond",
                "Select All copies the content and stops before the blank lines")
        h.equal(all.ordered.end.row, 1, "Select All ends on the last row with content")
    }

    do {
        let t = Term(rows: 3, cols: 10)
        let all = Selection.all(of: t.screen)
        h.equal(all.text(in: t.screen), "", "Select All on an empty screen copies nothing")
    }
}
