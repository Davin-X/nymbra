import Foundation

/// A text selection, in **viewport** coordinates: row 0 is the top row of what
/// is currently on screen, not the top of scrollback.
///
/// Viewport coordinates are the right ones because a selection is something a
/// person made by pointing at what they could see. The scroll offset is passed
/// in when the text is extracted, which keeps this type from having to know
/// where the viewport happens to be — and keeps it testable without a window.
public struct Selection: Equatable, Sendable {

    public struct Position: Equatable, Comparable, Sendable {
        public var row: Int
        public var col: Int

        public init(row: Int, col: Int) {
            self.row = row
            self.col = col
        }

        /// Reading order: earlier rows first, then earlier columns.
        public static func < (lhs: Position, rhs: Position) -> Bool {
            lhs.row == rhs.row ? lhs.col < rhs.col : lhs.row < rhs.row
        }
    }

    /// Where the drag started.
    public var anchor: Position
    /// Where the pointer is now.
    public var head: Position

    public init(anchor: Position, head: Position) {
        self.anchor = anchor
        self.head = head
    }

    public init(row: Int, col: Int) {
        self.init(anchor: Position(row: row, col: col), head: Position(row: row, col: col))
    }

    /// The selection in reading order, whichever way round it was dragged.
    public var ordered: (start: Position, end: Position) {
        anchor <= head ? (anchor, head) : (head, anchor)
    }

    /// True when the "selection" is a single cell: a click, not a drag. The view
    /// keeps no selection at all for a click, so this is only about the type
    /// being honest — a one-cell selection still copies that one cell.
    public var isEmpty: Bool { anchor == head }

    /// Whether a cell is highlighted. Intermediate rows are selected edge to
    /// edge, which is what makes a multi-line drag read as one block of text
    /// rather than as a rectangle.
    public func contains(row: Int, col: Int) -> Bool {
        let (start, end) = ordered
        guard row >= start.row, row <= end.row else { return false }
        if start.row == end.row {
            return col >= start.col && col <= end.col
        }
        if row == start.row { return col >= start.col }
        if row == end.row { return col <= end.col }
        return true
    }

    /// The selected text, ready for the pasteboard.
    ///
    /// Trailing blanks are trimmed from each line so copying a line does not drag
    /// its padding along; leading blanks are kept so indentation survives; lines
    /// are joined with a newline. That is what people expect when they paste into
    /// an editor, and it is what every other terminal does.
    public func text(in screen: Screen, scrollOffset: Int = 0) -> String {
        let (start, end) = ordered
        let rows = screen.displayRows(scrollOffset: scrollOffset)

        var lines: [String] = []
        for row in start.row...max(start.row, end.row) {
            guard row >= 0, row < rows.count else { continue }
            let line = rows[row]
            let first = row == start.row ? start.col : 0
            let last = row == end.row ? min(end.col, line.count - 1) : line.count - 1

            guard first <= last, first >= 0, first < line.count else {
                lines.append("")
                continue
            }

            var text = ""
            for col in first...last where col < line.count {
                // The second half of a wide character is a placeholder, not a
                // cell of its own: copying it would duplicate the character.
                if !line[col].isWideContinuation { text += line[col].text }
            }
            while text.hasSuffix(" ") { text.removeLast() }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    /// Everything worth copying: the visible screen, ending at the last row that
    /// actually has content, so Select All does not drag a screenful of blank
    /// lines onto the pasteboard.
    public static func all(of screen: Screen, scrollOffset: Int = 0) -> Selection {
        let rows = screen.displayRows(scrollOffset: scrollOffset)
        guard !rows.isEmpty else { return Selection(row: 0, col: 0) }

        var lastRow = rows.count - 1
        while lastRow > 0, rows[lastRow].allSatisfy({ $0.isBlank }) { lastRow -= 1 }

        var lastCol = max(0, rows[lastRow].count - 1)
        while lastCol > 0, rows[lastRow][lastCol].isBlank || rows[lastRow][lastCol].isWideContinuation {
            lastCol -= 1
        }
        return Selection(anchor: Position(row: 0, col: 0),
                         head: Position(row: lastRow, col: lastCol))
    }

    /// Grow a selection to whole words, for a double-click.
    ///
    /// A "word" is a run of cells that are not blanks, which is the useful
    /// definition for terminal output: paths, hashes and identifiers are single
    /// tokens without needing to guess at a schema.
    public static func word(in screen: Screen, row: Int, col: Int, scrollOffset: Int = 0) -> Selection {
        let rows = screen.displayRows(scrollOffset: scrollOffset)
        guard row >= 0, row < rows.count else { return Selection(row: row, col: col) }
        let line = rows[row]
        guard col >= 0, col < line.count else { return Selection(row: row, col: col) }

        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < line.count else { return false }
            let cell = line[index]
            if cell.isWideContinuation { return true }
            return !cell.text.trimmingCharacters(in: .whitespaces).isEmpty
        }

        guard isWord(col) else { return Selection(row: row, col: col) }
        var start = col
        while isWord(start - 1) { start -= 1 }
        var end = col
        while isWord(end + 1) { end += 1 }
        return Selection(anchor: Position(row: row, col: start),
                         head: Position(row: row, col: end))
    }

    /// The whole line, for a triple-click.
    public static func line(in screen: Screen, row: Int, scrollOffset: Int = 0) -> Selection {
        let rows = screen.displayRows(scrollOffset: scrollOffset)
        guard row >= 0, row < rows.count else { return Selection(row: row, col: 0) }
        return Selection(anchor: Position(row: row, col: 0),
                         head: Position(row: row, col: max(0, rows[row].count - 1)))
    }
}
