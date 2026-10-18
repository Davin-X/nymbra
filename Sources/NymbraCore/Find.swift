import Foundation

/// How a query is matched against the screen.
///
/// The default is what `⌘F` opens with: case-insensitive, literal, loose. Someone
/// searching a terminal is usually looking for a fragment of output they half
/// remember, and the case it was printed in is not part of what they remember.
/// The three toggles exist for the times that is wrong.
public struct FindOptions: Equatable {
    public var matchCase: Bool
    public var wholeWord: Bool
    public var regex: Bool

    public init(matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.regex = regex
    }

    /// Case-insensitive, literal, not word-bounded: the loose default.
    public static let standard = FindOptions()
}

/// One hit, in the units the renderer draws in: a row, the cell it starts at, and
/// how many cells wide it is.
///
/// Cells, not characters — which is the whole reason this is a type rather than a
/// `(row, col, len)` tuple. A match containing a double-width character covers two
/// cells per character, so a highlight computed from the character count is half
/// the width of the text it claims to be highlighting. Cells are what the grid,
/// the cursor and the renderer already agree on.
public struct FindMatch: Equatable {
    /// Absolute: scrollback rows are counted first, the way the screen model
    /// numbers them, so a viewport can be scrolled without renumbering anything.
    public let row: Int
    public let column: Int
    public let columns: Int

    public init(row: Int, column: Int, columns: Int) {
        self.row = row
        self.column = column
        self.columns = columns
    }
}

/// Matching a query against a screen.
///
/// Here rather than in the renderer because it has one right answer and no AppKit
/// in it: a highlight is arithmetic over the cell grid, and arithmetic is worth
/// asserting in milliseconds. What the renderer owes this file is pixels.
public enum Find {
    public enum Result: Equatable {
        case matches([FindMatch])
        /// The query is a regular expression and it does not compile. Reported
        /// rather than treated as "no matches": someone who mistyped a bracket
        /// should be told, not shown an empty screen and left to wonder.
        case invalidPattern
    }

    /// Every occurrence, oldest row first, in the order a person would walk them.
    ///
    /// A row is searched as the text a person sees — wide continuations are not
    /// characters, and trailing blanks are not content — so the columns reported
    /// are cells of the row as drawn.
    public static func matches(in screen: Screen, query: String, options: FindOptions) -> Result {
        guard !query.isEmpty else { return .matches([]) }

        let findRanges: (String) -> [(location: Int, length: Int)]
        if options.regex {
            let pattern: NSRegularExpression
            do {
                pattern = try NSRegularExpression(
                    pattern: query,
                    options: options.matchCase ? [] : [.caseInsensitive]
                )
            } catch {
                return .invalidPattern
            }
            findRanges = { text in
                pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    // A pattern like `a*` matches the empty string at every
                    // offset. Those are not hits: they highlight nothing and
                    // would fill the count with rows nobody can see.
                    .filter { $0.range.length > 0 }
                    .map { (location: $0.range.location, length: $0.range.length) }
            }
        } else {
            findRanges = { text in
                let body = text as NSString
                var ranges: [(location: Int, length: Int)] = []
                var start = 0
                while start <= body.length {
                    let range = body.range(
                        of: query,
                        options: options.matchCase ? [] : [.caseInsensitive],
                        range: NSRange(location: start, length: body.length - start)
                    )
                    guard range.location != NSNotFound else { break }
                    ranges.append((location: range.location, length: range.length))
                    start = range.location + max(range.length, 1)
                }
                return ranges
            }
        }

        // Build logical lines: consecutive rows where row N+1 is a soft wrap
        // of row N. For each logical line we keep the extended glyphs (with
        // physical row/col) so we can map a hit back to physical segments.
        struct ExtendedGlyph {
            let text: String
            let physRow: Int
            let physCol: Int
            let columns: Int
        }

        var found: [FindMatch] = []
        let allRows = screen.scrollback + screen.displayRows(scrollOffset: 0)

        var lineStart = 0
        while lineStart < allRows.count {
            // Collect consecutive soft-wrapped rows
            var rowsInLine = [lineStart]
            var next = lineStart + 1
            while next < allRows.count, screen.isSoftWrapped(absoluteRow: next) {
                rowsInLine.append(next)
                next += 1
            }

            // Build extended glyphs for this logical line
            var extGlyphs: [ExtendedGlyph] = []
            for physRow in rowsInLine {
                let line = allRows[physRow]
                let glyphs = glyphs(ofLine: line)
                for g in glyphs {
                    extGlyphs.append(ExtendedGlyph(text: g.text,
                                                   physRow: physRow,
                                                   physCol: g.cell,
                                                   columns: g.columns))
                }
            }

            // Search this logical line
            let searchGlyphs = extGlyphs.map { Glyph(text: $0.text, cell: 0, columns: $0.columns) }
            let offsets = utf16Offsets(of: searchGlyphs)
            let text = extGlyphs.map(\.text).joined()

            for range in findRanges(text) {
                guard range.location + range.length < offsets.count else { continue }
                let first = offsets[range.location]
                let end = offsets[range.location + range.length]
                guard end > first else { continue }
                if options.wholeWord, !isWordBounded(searchGlyphs, from: first, to: end) { continue }

                // Split the hit [first, end) by physical row
                var segmentStart = first
                for segEnd in (first + 1)...end {
                    let isLast = segEnd == end
                    let nextPhysRow = isLast ? (extGlyphs[end - 1].physRow + 1) : extGlyphs[segEnd].physRow
                    let currentPhysRow = extGlyphs[segEnd - 1].physRow
                    if isLast || nextPhysRow != currentPhysRow {
                        let segFirst = extGlyphs[segmentStart]
                        let segLast = extGlyphs[segEnd - 1]
                        found.append(FindMatch(row: currentPhysRow,
                                               column: segFirst.physCol,
                                               columns: segLast.physCol + segLast.columns - segFirst.physCol))
                        segmentStart = segEnd
                    }
                }
            }

            lineStart = next
        }
        return .matches(found)    }

    /// One cell as a person reads it: its text, where it sits, and how many cells
    /// it covers. The trailing half of a wide character is not a glyph — it is the
    /// second cell of the one before it.
    struct Glyph: Equatable {
        let text: String
        let cell: Int
        let columns: Int
    }

    /// The glyphs of a row, with trailing blanks dropped.
    ///
    /// Dropping them is what keeps a search for `a` out of the padding: an 80-column
    /// row that holds three characters is not 77 matches.
    static func glyphs(ofLine line: [Cell]) -> [Glyph] {
        var glyphs: [Glyph] = []
        glyphs.reserveCapacity(line.count)
        for (index, cell) in line.enumerated() where !cell.isWideContinuation {
            let wide = index + 1 < line.count && line[index + 1].isWideContinuation
            glyphs.append(Glyph(text: cell.text, cell: index, columns: wide ? 2 : 1))
        }
        while let last = glyphs.last, last.text == " " {
            glyphs.removeLast()
        }
        return glyphs
    }

    /// Where each UTF-16 unit of the row's text came from, and the end.
    ///
    /// Foundation's matchers answer in UTF-16 units while the grid is counted in
    /// characters, and the two are not the same number — not for an emoji, not for
    /// anything outside the basic plane. This is the translation table, one entry
    /// per unit, with the length of the row appended so an end offset has an answer
    /// too.
    static func utf16Offsets(of glyphs: [Glyph]) -> [Int] {
        var offsets: [Int] = []
        for (index, glyph) in glyphs.enumerated() {
            offsets.append(contentsOf: repeatElement(index, count: glyph.text.utf16.count))
        }
        offsets.append(glyphs.count)
        return offsets
    }

    /// Whether a hit starts and ends where a word does.
    static func isWordBounded(_ glyphs: [Glyph], from first: Int, to end: Int) -> Bool {
        let before = first > 0 ? glyphs[first - 1].text : ""
        let after = end < glyphs.count ? glyphs[end].text : ""
        return !isWordCharacter(before) && !isWordCharacter(after)
    }

    /// A word character, for `wholeWord`: a letter, a digit, or an underscore —
    /// the same set a shell means by `\b`, so a match inside `NYMBRA_FIND42` is
    /// not a whole-word match for `NYMBRA_FIND4`.
    static func isWordCharacter(_ text: String) -> Bool {
        guard let character = text.first else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
