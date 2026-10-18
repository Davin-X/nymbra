import NymbraCore

/// A screen with lines on it, driven through the parser the way the application
/// drives it.
private func screen(_ lines: [String], rows: Int = 8, cols: Int = 40) -> Screen {
    let screen = Screen(rows: rows, cols: cols)
    let parser = Parser(screen: screen)
    for line in lines { parser.feed(line + "\r\n") }
    return screen
}

/// Find: the three options, the boundaries, and the units.
///
/// Everything here is a fact about the model, which is the point of the matcher
/// living in `NymbraCore`: a highlight is arithmetic over the cell grid, and
/// arithmetic does not need a window. What the renderer owes in exchange is pixels,
/// and that is `--find-test`.
func findSuite(_ h: Harness) {
    h.suite("Find")

    let text = screen(["warning: one file changed", "WARNING: another"])

    // Lower case query, upper case text. The default has to be case-insensitive:
    // someone searching a terminal remembers the word, not the case it was printed
    // in.
    h.equal(Find.matches(in: text, query: "warning", options: .standard),
            .matches([FindMatch(row: 0, column: 0, columns: 7),
                      FindMatch(row: 1, column: 0, columns: 7)]),
            "case-insensitive by default, on every row it appears")

    h.equal(Find.matches(in: text, query: "warning", options: FindOptions(matchCase: true)),
            .matches([FindMatch(row: 0, column: 0, columns: 7)]),
            "match case refuses the row that is not written that way")

    h.equal(Find.matches(in: text, query: "WARNING", options: FindOptions(matchCase: true)),
            .matches([FindMatch(row: 1, column: 0, columns: 7)]),
            "match case takes the row it is written in")

    h.equal(Find.matches(in: text, query: "changed", options: .standard),
            .matches([FindMatch(row: 0, column: 18, columns: 7)]),
            "a match is reported at the cell it starts on")

    // Whole word. The boundary is a word character — letter, digit or underscore —
    // which is the set a shell means by `\b`, so the `find` inside `find_2` is not
    // a whole word.
    let words = screen(["find finding find_2 xfind"])

    h.equal(Find.matches(in: words, query: "find", options: .standard),
            .matches([FindMatch(row: 0, column: 0, columns: 4),
                      FindMatch(row: 0, column: 5, columns: 4),
                      FindMatch(row: 0, column: 13, columns: 4),
                      FindMatch(row: 0, column: 21, columns: 4)]),
            "a literal query finds every occurrence, inside longer words included")

    h.equal(Find.matches(in: words, query: "find", options: FindOptions(wholeWord: true)),
            .matches([FindMatch(row: 0, column: 0, columns: 4)]),
            "whole word stops at a word character")

    h.equal(Find.matches(in: text, query: "changed", options: FindOptions(wholeWord: true)),
            .matches([FindMatch(row: 0, column: 18, columns: 7)]),
            "the end of the text is a boundary")

    // Regex: what a literal cannot express.
    let numbers = screen(["NYMBRA_FIND42 NYMBRA_FIND48", "nothing here"])

    h.equal(Find.matches(in: numbers, query: "NYMBRA_FIND[0-9]+", options: FindOptions(regex: true)),
            .matches([FindMatch(row: 0, column: 0, columns: 13),
                      FindMatch(row: 0, column: 14, columns: 13)]),
            "a pattern finds what the same text as a literal would not")

    h.equal(Find.matches(in: numbers, query: "NYMBRA_FIND[", options: FindOptions(regex: true)),
            .invalidPattern,
            "a pattern that does not compile is reported, rather than thrown or "
                + "quietly called no matches")

    // `x*` matches the empty string at every offset. Those are not hits: they
    // highlight nothing and would count every row.
    h.equal(Find.matches(in: numbers, query: "x*", options: FindOptions(regex: true)),
            .matches([]),
            "a pattern that can only match nothing matches nothing")

    h.equal(Find.matches(in: numbers, query: "", options: .standard),
            .matches([]),
            "no query is no matches, not every position")

    // Cells, not characters. A double-width character occupies two cells, so a
    // match built from the character count is half as wide as the text it claims
    // to be highlighting — and everything after it is drawn one cell off.
    let wide = screen(["日本語 ok"])

    h.equal(Find.matches(in: wide, query: "本", options: .standard),
            .matches([FindMatch(row: 0, column: 2, columns: 2)]),
            "a wide character is two cells, and starts at its own cell")

    h.equal(Find.matches(in: wide, query: "日本語", options: .standard),
            .matches([FindMatch(row: 0, column: 0, columns: 6)]),
            "three wide characters are six cells")

    h.equal(Find.matches(in: wide, query: "ok", options: .standard),
            .matches([FindMatch(row: 0, column: 7, columns: 2)]),
            "text after a wide character is on the cell it is drawn at")

    // Blanks. The trailing padding of a row is not content, or a search for a space
    // would find one on every line of the screen.
    let padded = screen(["ab"], cols: 10)

    h.equal(Find.matches(in: padded, query: " ", options: .standard),
            .matches([]),
            "trailing blanks are not matches")

    h.equal(Find.matches(in: padded, query: "a", options: .standard),
            .matches([FindMatch(row: 0, column: 0, columns: 1)]),
            "…but the text itself is")

    // Absolute rows. A match that has scrolled off is still found, and says which
    // row it is on rather than pretending history is the live screen.
    let scrolled = screen(["keep ME here"] + (1...30).map { "line \($0)" }, rows: 4, cols: 20)

    h.equal(scrolled.scrollback.isEmpty, false, "there is history to search")

    h.equal(Find.matches(in: scrolled, query: "ME", options: FindOptions(wholeWord: true)),
            .matches([FindMatch(row: 0, column: 5, columns: 2)]),
            "a match in scrollback is found, at its absolute row")
}
