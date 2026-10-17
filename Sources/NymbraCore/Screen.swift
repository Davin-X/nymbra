import Foundation

/// The screen model: a grid of cells, a cursor, the current pen, the scrolling
/// region, tab stops and the modes that affect output.
///
/// This is the single source of truth for what is on screen (invariant 1 in
/// docs/ARCHITECTURE.md). It knows nothing about the PTY, about escape-sequence
/// syntax, or about drawing: the parser drives it, the renderer reads it.
///
/// Everything is mutated on one thread — the main thread in the app — so there
/// is no locking anywhere in this type.
public final class Screen {

    // MARK: - Nested types

    /// DECSCUSR cursor shapes.
    public enum CursorStyle: Equatable {
        case block
        case blockBlink
        case underline
        case underlineBlink
        case bar
        case barBlink

        /// DECSCUSR's parameter space is not one-to-one with the shapes: 0 and 1
        /// both mean a blinking block, and 6 is a steady bar. A `rawValue` enum
        /// cannot express that, which is how the first version got it wrong.
        public init?(decscusr value: Int) {
            switch value {
            case 0, 1: self = .blockBlink
            case 2: self = .block
            case 3: self = .underlineBlink
            case 4: self = .underline
            case 5: self = .barBlink
            case 6: self = .bar
            default: return nil
            }
        }
    }

    public struct Cursor: Equatable {
        public var row = 0
        public var col = 0
        public var visible = true
        public var style: CursorStyle = .block

        /// DECAWM deferred wrap: the cursor is parked on the last column, which
        /// already holds a character. The *next* character wraps first. Getting
        /// this wrong is why naive terminals lose the last column.
        public var pendingWrap = false

        public init() {}
    }

    public enum MouseMode: Equatable { case off, click, drag, motion }
    public enum MouseEncoding: Equatable { case x10, sgr }

    /// The character sets selectable with `ESC ( x` / `ESC ) x`.
    public enum Charset: Equatable {
        case ascii
        case decSpecialGraphics
    }

    // MARK: - Geometry

    public private(set) var rows: Int
    public private(set) var cols: Int
    private var grid: [Cell]

    // MARK: - State

    public private(set) var cursor = Cursor()
    /// The current graphic rendition, copied into every cell written.
    public var pen = Attributes()

    /// Scrolling region, 0-based and inclusive. Line feeds at `scrollBottom`
    /// scroll the region instead of moving the cursor.
    public private(set) var scrollTop = 0
    public private(set) var scrollBottom: Int

    public var autoWrap = true
    public var originMode = false
    public var insertMode = false
    public var applicationCursorKeys = false
    public var applicationKeypad = false
    public var bracketedPaste = false
    public var focusReporting = false
    public var mouseMode: MouseMode = .off
    public var mouseEncoding: MouseEncoding = .x10
    public var reverseVideo = false
    public var title = ""

    public private(set) var altScreenActive = false
    public private(set) var scrollback: [[Cell]] = []
    public var scrollbackLimit = 10_000

    private var savedPrimaryGrid: [Cell] = []
    private var savedState: SavedState?
    private var tabStops: [Bool]
    private var charsetG0: Charset = .ascii
    private var charsetG1: Charset = .ascii
    private var shiftedOut = false

    /// What DECSC stores and DECRC restores.
    private struct SavedState {
        var cursor: Cursor
        var pen: Attributes
        var originMode: Bool
        var autoWrap: Bool
        var charsetG0: Charset
        var charsetG1: Charset
        var shiftedOut: Bool
    }

    public init(rows: Int, cols: Int) {
        let r = max(1, rows)
        let c = max(1, cols)
        self.rows = r
        self.cols = c
        self.grid = Array(repeating: Cell(), count: r * c)
        self.tabStops = Screen.defaultTabStops(cols: c)
        self.scrollBottom = r - 1
    }

    // MARK: - Cell access

    private func offset(_ row: Int, _ col: Int) -> Int { row * cols + col }

    public func cell(row: Int, col: Int) -> Cell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return Cell() }
        return grid[offset(row, col)]
    }

    private func store(_ cell: Cell, _ row: Int, _ col: Int) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        grid[offset(row, col)] = cell
    }

    /// A blank cell carrying the current background. Erasing paints the pen's
    /// background colour (the "background colour erase" rule, BCE), which is
    /// what makes full-screen repaints from `vim` and `htop` correct.
    private func blankCell() -> Cell {
        var attributes = Attributes()
        attributes.background = pen.background
        return Cell(content: .empty, attributes: attributes)
    }

    // MARK: - Writing

    /// Write one scalar at the cursor, advancing it and wrapping as needed.
    public func put(_ scalar: Unicode.Scalar) {
        let width = Screen.displayWidth(of: scalar)
        if width == 0 {
            appendZeroWidth(scalar)
            return
        }

        if cursor.pendingWrap { wrapToNextLine() }
        if width == 2 && cursor.col == cols - 1 {
            // A double-width character cannot straddle the right edge.
            if autoWrap { wrapToNextLine() } else { return }
        }

        if insertMode { insertChars(width) }

        // Overwriting half of an existing wide character must not leave half of
        // it behind.
        clearWidePair(row: cursor.row, col: cursor.col)
        if width == 2 { clearWidePair(row: cursor.row, col: cursor.col + 1) }

        let mapped = translate(scalar)
        store(Cell(content: .scalar(mapped), attributes: pen), cursor.row, cursor.col)
        if width == 2 {
            store(Cell(content: .empty, attributes: pen, isWideContinuation: true),
                  cursor.row, cursor.col + 1)
        }

        let next = cursor.col + width
        if next >= cols {
            cursor.col = cols - 1
            // Without DECAWM the cursor stays on the last column and the next
            // character overwrites it instead of wrapping.
            if autoWrap { cursor.pendingWrap = true }
        } else {
            cursor.col = next
        }
    }

    private func wrapToNextLine() {
        cursor.pendingWrap = false
        cursor.col = 0
        lineFeed()
    }

    /// Attach a zero-width scalar (a combining mark, or a ZWJ) to the cell that
    /// was written last.
    private func appendZeroWidth(_ scalar: Unicode.Scalar) {
        var col = cursor.pendingWrap ? cols - 1 : cursor.col - 1
        guard col >= 0, col < cols else { return }
        if grid[offset(cursor.row, col)].isWideContinuation { col -= 1 }
        guard col >= 0 else { return }

        var cell = grid[offset(cursor.row, col)]
        switch cell.content {
        case .empty: cell.content = .cluster(String(scalar))
        case .scalar(let base): cell.content = .cluster(String(base) + String(scalar))
        case .cluster(let text): cell.content = .cluster(text + String(scalar))
        }
        grid[offset(cursor.row, col)] = cell
    }

    /// Blank both cells of a wide character if `col` is part of one.
    private func clearWidePair(row: Int, col: Int) {
        guard col >= 0, col < cols else { return }
        if grid[offset(row, col)].isWideContinuation {
            store(blankCell(), row, col - 1)
        } else if col + 1 < cols && grid[offset(row, col + 1)].isWideContinuation {
            store(blankCell(), row, col + 1)
        }
    }

    private func translate(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let charset = shiftedOut ? charsetG1 : charsetG0
        guard charset == .decSpecialGraphics,
              scalar.value >= 0x5F, scalar.value <= 0x7E else { return scalar }
        return Screen.decSpecialGraphics[scalar.value] ?? scalar
    }

    // MARK: - Controls

    public func lineFeed() {
        cursor.pendingWrap = false
        if cursor.row == scrollBottom {
            scrollUp(1)
        } else if cursor.row < rows - 1 {
            cursor.row += 1
        }
    }

    public func reverseIndex() {
        cursor.pendingWrap = false
        if cursor.row == scrollTop {
            scrollDown(1)
        } else if cursor.row > 0 {
            cursor.row -= 1
        }
    }

    public func carriageReturn() {
        cursor.col = 0
        cursor.pendingWrap = false
    }

    public func backspace() {
        cursor.pendingWrap = false
        if cursor.col > 0 { cursor.col -= 1 }
    }

    public func tab() {
        cursor.col = nextTabStop(after: cursor.col)
        cursor.pendingWrap = false
    }

    public func backTab() {
        cursor.col = previousTabStop(before: cursor.col)
        cursor.pendingWrap = false
    }

    public func setTabStop() {
        if cursor.col >= 0, cursor.col < cols { tabStops[cursor.col] = true }
    }

    /// TBC: 0 clears the stop at the cursor, 3 clears every stop.
    public func clearTabStop(_ mode: Int) {
        switch mode {
        case 0: tabStops[cursor.col] = false
        case 3: tabStops = Array(repeating: false, count: cols)
        default: break
        }
    }

    private func nextTabStop(after col: Int) -> Int {
        var c = col + 1
        while c < cols {
            if tabStops[c] { return c }
            c += 1
        }
        return cols - 1
    }

    private func previousTabStop(before col: Int) -> Int {
        var c = col - 1
        while c > 0 {
            if tabStops[c] { return c }
            c -= 1
        }
        return 0
    }

    // MARK: - Scrolling

    /// Move the region's contents up by `n`, adding blank lines at the bottom.
    /// Only a scroll of the whole primary screen reaches the scrollback.
    public func scrollUp(_ n: Int) {
        let lines = min(max(1, n), scrollBottom - scrollTop + 1)
        let capture = scrollTop == 0 && scrollBottom == rows - 1 && !altScreenActive
        for _ in 0..<lines {
            if capture {
                scrollback.append(Array(grid[0..<cols]))
                if scrollback.count > scrollbackLimit {
                    scrollback.removeFirst(scrollback.count - scrollbackLimit)
                }
            }
            for row in scrollTop..<scrollBottom {
                let source = (row + 1) * cols
                let destination = row * cols
                for col in 0..<cols { grid[destination + col] = grid[source + col] }
            }
            for col in 0..<cols { grid[scrollBottom * cols + col] = blankCell() }
        }
    }

    public func scrollDown(_ n: Int) {
        let lines = min(max(1, n), scrollBottom - scrollTop + 1)
        for _ in 0..<lines {
            var row = scrollBottom
            while row > scrollTop {
                let source = (row - 1) * cols
                let destination = row * cols
                for col in 0..<cols { grid[destination + col] = grid[source + col] }
                row -= 1
            }
            for col in 0..<cols { grid[scrollTop * cols + col] = blankCell() }
        }
    }

    /// DECSTBM. Parameters are 1-based; a top below the bottom is ignored.
    public func setScrollRegion(top: Int, bottom: Int) {
        let t = max(0, min(top - 1, rows - 1))
        let b = max(0, min(bottom - 1, rows - 1))
        guard t < b else { return }
        scrollTop = t
        scrollBottom = b
        cursor.row = originMode ? scrollTop : 0
        cursor.col = 0
        cursor.pendingWrap = false
    }

    // MARK: - Cursor movement

    public func moveCursor(row: Int, col: Int) {
        cursor.row = min(max(0, row), rows - 1)
        cursor.col = min(max(0, col), cols - 1)
        cursor.pendingWrap = false
    }

    /// CUP/HVP. Parameters are 1-based and relative to the scrolling region when
    /// origin mode (DECOM) is set.
    public func setCursorPosition(row: Int, col: Int) {
        let r = max(0, row - 1)
        cursor.row = originMode ? min(scrollTop + r, scrollBottom) : min(r, rows - 1)
        cursor.col = min(max(0, col - 1), cols - 1)
        cursor.pendingWrap = false
    }

    /// CUU/CUD stop at the scrolling margin when the cursor is inside the region,
    /// and at the screen edge when it is outside — the xterm rule.
    public func cursorUp(_ n: Int) {
        let distance = max(1, n)
        let limit = cursor.row >= scrollTop ? scrollTop : 0
        cursor.row = max(cursor.row - distance, limit)
        cursor.pendingWrap = false
    }

    public func cursorDown(_ n: Int) {
        let distance = max(1, n)
        let limit = cursor.row <= scrollBottom ? scrollBottom : rows - 1
        cursor.row = min(cursor.row + distance, limit)
        cursor.pendingWrap = false
    }

    public func cursorForward(_ n: Int) {
        cursor.col = min(cursor.col + max(1, n), cols - 1)
        cursor.pendingWrap = false
    }

    public func cursorBack(_ n: Int) {
        cursor.col = max(cursor.col - max(1, n), 0)
        cursor.pendingWrap = false
    }

    public func setColumn(_ col: Int) {
        cursor.col = min(max(0, col - 1), cols - 1)
        cursor.pendingWrap = false
    }

    public func setRow(_ row: Int) {
        cursor.row = min(max(0, row - 1), rows - 1)
        cursor.pendingWrap = false
    }

    public func nextLine(_ n: Int) {
        cursorDown(n)
        carriageReturn()
    }

    public func previousLine(_ n: Int) {
        cursorUp(n)
        carriageReturn()
    }

    // MARK: - Erasing

    private func eraseCells(row: Int, from: Int, to: Int) {
        guard row >= 0, row < rows else { return }
        let lo = max(0, from)
        let hi = min(cols - 1, to)
        guard lo <= hi else { return }
        for col in lo...hi { grid[offset(row, col)] = blankCell() }
    }

    /// EL: 0 to end of line, 1 to start, 2 the whole line.
    public func eraseInLine(_ mode: Int) {
        switch mode {
        case 0: eraseCells(row: cursor.row, from: cursor.col, to: cols - 1)
        case 1: eraseCells(row: cursor.row, from: 0, to: cursor.col)
        case 2: eraseCells(row: cursor.row, from: 0, to: cols - 1)
        default: break
        }
        cursor.pendingWrap = false
    }

    /// ED: 0 to end of screen, 1 to start, 2 the whole screen, 3 the scrollback.
    public func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseCells(row: cursor.row, from: cursor.col, to: cols - 1)
            for row in (cursor.row + 1)..<rows { eraseCells(row: row, from: 0, to: cols - 1) }
        case 1:
            if cursor.row > 0 { for row in 0..<cursor.row { eraseCells(row: row, from: 0, to: cols - 1) } }
            eraseCells(row: cursor.row, from: 0, to: cursor.col)
        case 2:
            for row in 0..<rows { eraseCells(row: row, from: 0, to: cols - 1) }
        case 3:
            scrollback.removeAll()
        default:
            break
        }
        cursor.pendingWrap = false
    }

    // MARK: - Insert and delete

    /// IL. Per DEC STD 070 the cursor moves to the left margin.
    public func insertLines(_ n: Int) {
        guard cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
        let count = min(max(1, n), scrollBottom - cursor.row + 1)
        var row = scrollBottom
        while row >= cursor.row + count {
            let source = (row - count) * cols
            let destination = row * cols
            for col in 0..<cols { grid[destination + col] = grid[source + col] }
            row -= 1
        }
        for row in cursor.row..<(cursor.row + count) { eraseCells(row: row, from: 0, to: cols - 1) }
        cursor.col = 0
        cursor.pendingWrap = false
    }

    /// DL.
    public func deleteLines(_ n: Int) {
        guard cursor.row >= scrollTop, cursor.row <= scrollBottom else { return }
        let count = min(max(1, n), scrollBottom - cursor.row + 1)
        var row = cursor.row
        while row + count <= scrollBottom {
            let source = (row + count) * cols
            let destination = row * cols
            for col in 0..<cols { grid[destination + col] = grid[source + col] }
            row += 1
        }
        for row in (scrollBottom - count + 1)...scrollBottom { eraseCells(row: row, from: 0, to: cols - 1) }
        cursor.col = 0
        cursor.pendingWrap = false
    }

    /// ICH.
    public func insertChars(_ n: Int) {
        let count = min(max(1, n), cols - cursor.col)
        guard count > 0 else { return }
        var col = cols - 1
        while col >= cursor.col + count {
            grid[offset(cursor.row, col)] = grid[offset(cursor.row, col - count)]
            col -= 1
        }
        for col in cursor.col..<(cursor.col + count) { grid[offset(cursor.row, col)] = blankCell() }
        cursor.pendingWrap = false
    }

    /// DCH.
    public func deleteChars(_ n: Int) {
        let count = min(max(1, n), cols - cursor.col)
        guard count > 0 else { return }
        var col = cursor.col
        while col + count < cols {
            grid[offset(cursor.row, col)] = grid[offset(cursor.row, col + count)]
            col += 1
        }
        while col < cols {
            grid[offset(cursor.row, col)] = blankCell()
            col += 1
        }
        cursor.pendingWrap = false
    }

    /// ECH.
    public func eraseChars(_ n: Int) {
        let count = min(max(1, n), cols - cursor.col)
        guard count > 0 else { return }
        for col in cursor.col..<(cursor.col + count) { grid[offset(cursor.row, col)] = blankCell() }
        cursor.pendingWrap = false
    }

    // MARK: - Modes

    /// DECSET/DECRST (`CSI ? Pn h/l`).
    public func setMode(_ mode: Int, _ enabled: Bool) {
        switch mode {
        case 1: applicationCursorKeys = enabled
        case 3:
            // DECCOLM: a program resizing the window is a footgun. Recorded
            // nowhere on purpose; see docs/ROADMAP.md ("explicitly out of scope"
            // is not the place either — this is a deliberate divergence).
            break
        case 4: break                        // DECSCLM (smooth scroll)
        case 5: reverseVideo = enabled       // DECSCNM
        case 6:                              // DECOM
            originMode = enabled
            cursor.row = enabled ? scrollTop : 0
            cursor.col = 0
            cursor.pendingWrap = false
        case 7: autoWrap = enabled           // DECAWM
        case 12: break                       // cursor blink (attribute of the cursor)
        case 25: cursor.visible = enabled    // DECTCEM
        case 47, 1047: setAltScreen(enabled)
        case 1048: enabled ? saveCursor() : restoreCursor()
        case 1049:
            if enabled {
                saveCursor()
                setAltScreen(true)
            } else {
                setAltScreen(false)
                restoreCursor()
            }
        case 1000: mouseMode = enabled ? .click : .off
        case 1002: mouseMode = enabled ? .drag : .off
        case 1003: mouseMode = enabled ? .motion : .off
        case 1004: focusReporting = enabled
        case 1006: mouseEncoding = enabled ? .sgr : .x10
        case 1015: break                     // urxvt encoding: accepted, unused
        case 2004: bracketedPaste = enabled
        default: break
        }
    }

    /// SM/RM (`CSI Pn h/l`), the non-private modes.
    public func setStandardMode(_ mode: Int, _ enabled: Bool) {
        switch mode {
        case 4: insertMode = enabled     // IRM
        default: break
        }
    }

    private func setAltScreen(_ enabled: Bool) {
        guard enabled != altScreenActive else { return }
        if enabled {
            savedPrimaryGrid = grid
            grid = Array(repeating: Cell(), count: rows * cols)
            altScreenActive = true
            cursor = Cursor()
            scrollTop = 0
            scrollBottom = rows - 1
        } else {
            grid = savedPrimaryGrid
            savedPrimaryGrid = []
            altScreenActive = false
        }
    }

    // MARK: - Saved cursor (DECSC / DECRC)

    public func saveCursor() {
        savedState = SavedState(
            cursor: cursor,
            pen: pen,
            originMode: originMode,
            autoWrap: autoWrap,
            charsetG0: charsetG0,
            charsetG1: charsetG1,
            shiftedOut: shiftedOut
        )
    }

    public func restoreCursor() {
        guard let state = savedState else { return }
        cursor = state.cursor
        cursor.row = min(cursor.row, rows - 1)
        cursor.col = min(cursor.col, cols - 1)
        cursor.pendingWrap = false
        pen = state.pen
        originMode = state.originMode
        autoWrap = state.autoWrap
        charsetG0 = state.charsetG0
        charsetG1 = state.charsetG1
        shiftedOut = state.shiftedOut
    }

    // MARK: - Character sets

    public func designateCharset(_ g: Int, _ charset: Charset) {
        if g == 0 { charsetG0 = charset } else { charsetG1 = charset }
    }

    public func setShiftOut(_ out: Bool) {
        shiftedOut = out
    }

    /// DECSCUSR.
    public func setCursorStyle(_ style: CursorStyle) {
        cursor.style = style
    }

    // MARK: - SGR

    /// Apply an SGR sequence. `params` is one entry per semicolon-separated
    /// parameter, each holding its colon-separated sub-parameters, so that both
    /// `38;2;r;g;b` and `38:2::r:g:b` are representable.
    public func applySGR(_ params: [[Int?]]) {
        if params.isEmpty {
            pen = Attributes()
            return
        }
        var index = 0
        while index < params.count {
            let group = params[index]
            let code = group.first.flatMap { $0 } ?? 0
            switch code {
            case 0: pen = Attributes()
            case 1: pen.bold = true
            case 2: pen.faint = true
            case 3: pen.italic = true
            case 4:
                if group.count > 1, let style = group[1] {
                    pen.underline = UnderlineStyle(rawValue: style) ?? .single
                } else {
                    pen.underline = .single
                }
            case 5, 6: pen.blink = true
            case 7: pen.inverse = true
            case 8: pen.conceal = true
            case 9: pen.strike = true
            case 21: pen.underline = .double
            case 22: pen.bold = false; pen.faint = false
            case 23: pen.italic = false
            case 24: pen.underline = .none
            case 25: pen.blink = false
            case 27: pen.inverse = false
            case 28: pen.conceal = false
            case 29: pen.strike = false
            case 30...37: pen.foreground = .indexed(UInt8(code - 30))
            case 38:
                if let (colour, consumed) = extendedColour(params, from: index), let colour {
                    pen.foreground = colour
                    index += consumed - 1
                }
            case 39: pen.foreground = .default
            case 40...47: pen.background = .indexed(UInt8(code - 40))
            case 48:
                if let (colour, consumed) = extendedColour(params, from: index), let colour {
                    pen.background = colour
                    index += consumed - 1
                }
            case 49: pen.background = .default
            case 58:
                if let (colour, consumed) = extendedColour(params, from: index), let colour {
                    pen.underlineColour = colour
                    index += consumed - 1
                }
            case 59: pen.underlineColour = .default
            case 90...97: pen.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: pen.background = .indexed(UInt8(code - 100 + 8))
            default: break
            }
            index += 1
        }
    }

    /// Decode `38`/`48`/`58` in either syntax. Returns the colour and how many
    /// parameter groups it consumed.
    private func extendedColour(_ params: [[Int?]], from index: Int) -> (Colour?, Int)? {
        let group = params[index]

        // Colon form: one group holding the sub-parameters.
        if group.count > 1 {
            let kind = group[1] ?? 0
            switch kind {
            case 2:
                var values = Array(group.dropFirst(2))
                // `38:2:<colour space>:r:g:b` — drop the colour-space slot.
                if values.count >= 4 { values.removeFirst() }
                if values.count >= 3, let r = values[0], let g = values[1], let b = values[2] {
                    return (.rgb(r: clamp(r), g: clamp(g), b: clamp(b)), 1)
                }
            case 5:
                if group.count >= 3, let n = group[2] { return (.indexed(clamp(n)), 1) }
            default:
                break
            }
            return (nil, 1)
        }

        // Semicolon form: the sub-parameters are the following groups.
        guard index + 1 < params.count else { return (nil, 1) }
        let kind = params[index + 1].first.flatMap { $0 } ?? 0
        if kind == 5, index + 2 < params.count, let n = params[index + 2].first.flatMap({ $0 }) {
            return (.indexed(clamp(n)), 3)
        }
        if kind == 2, index + 4 < params.count,
           let r = params[index + 2].first.flatMap({ $0 }),
           let g = params[index + 3].first.flatMap({ $0 }),
           let b = params[index + 4].first.flatMap({ $0 }) {
            return (.rgb(r: clamp(r), g: clamp(g), b: clamp(b)), 5)
        }
        return (nil, 1)
    }

    private func clamp(_ value: Int) -> UInt8 {
        UInt8(min(max(0, value), 255))
    }

    // MARK: - Whole-screen operations

    /// RIS: everything back to its power-on state.
    public func reset() {
        pen = Attributes()
        cursor = Cursor()
        scrollTop = 0
        scrollBottom = rows - 1
        autoWrap = true
        originMode = false
        insertMode = false
        applicationCursorKeys = false
        applicationKeypad = false
        bracketedPaste = false
        focusReporting = false
        mouseMode = .off
        mouseEncoding = .x10
        reverseVideo = false
        charsetG0 = .ascii
        charsetG1 = .ascii
        shiftedOut = false
        tabStops = Screen.defaultTabStops(cols: cols)
        altScreenActive = false
        savedPrimaryGrid = []
        savedState = nil
        scrollback.removeAll()
        grid = Array(repeating: Cell(), count: rows * cols)
    }

    /// DECALN (`ESC # 8`): the alignment test pattern.
    public func alignmentTest() {
        let blank = Cell(content: .scalar("E"), attributes: Attributes())
        for row in 0..<rows {
            for col in 0..<cols { grid[offset(row, col)] = blank }
        }
        cursor = Cursor()
    }

    /// Resize, preserving content. Text is not reflowed: a line that is cut off
    /// is lost rather than rewrapped (see docs/ROADMAP.md — reflow is M2).
    public func resize(rows newRows: Int, cols newCols: Int) {
        let r = max(1, newRows)
        let c = max(1, newCols)
        guard r != rows || c != cols else { return }

        var next = [Cell](repeating: Cell(), count: r * c)
        let copyRows = min(rows, r)
        let copyCols = min(cols, c)
        for row in 0..<copyRows {
            for col in 0..<copyCols {
                next[row * c + col] = grid[row * cols + col]
            }
        }

        // Do not leave half a wide character at either edge of the new grid.
        if c > 0 {
            for row in 0..<copyRows {
                if case .scalar(let scalar) = next[row * c + c - 1].content,
                   Screen.displayWidth(of: scalar) == 2 {
                    next[row * c + c - 1] = Cell()
                }
                if next[row * c].isWideContinuation { next[row * c] = Cell() }
            }
        }

        grid = next
        rows = r
        cols = c

        var stops = Array(tabStops.prefix(c))
        if stops.count < c { stops.append(contentsOf: Array(repeating: false, count: c - stops.count)) }
        tabStops = stops

        if scrollBottom >= r {
            scrollTop = 0
            scrollBottom = r - 1
        }
        cursor.row = min(cursor.row, r - 1)
        cursor.col = min(cursor.col, c - 1)
        cursor.pendingWrap = false
    }

    // MARK: - Reading

    /// One row as text. Wide continuations are skipped; trailing blanks are
    /// trimmed by default, which is what conformance cases want to compare.
    public func rowText(_ row: Int, trim: Bool = true) -> String {
        guard row >= 0, row < rows else { return "" }
        var text = ""
        for col in 0..<cols {
            let cell = grid[offset(row, col)]
            if cell.isWideContinuation { continue }
            text += cell.text
        }
        if !trim { return text }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    public func dump(trim: Bool = true) -> String {
        (0..<rows).map { rowText($0, trim: trim) }.joined(separator: "\n")
    }

    /// A dump in which blanks are shown as `·`, so that alignment and erase
    /// bugs are visible instead of vanishing into trailing whitespace.
    public func debugDump() -> String {
        (0..<rows).map { row -> String in
            var text = ""
            for col in 0..<cols {
                let cell = grid[offset(row, col)]
                if cell.isWideContinuation { text += "\u{2192}" } else if cell.isBlank { text += "\u{00B7}" } else { text += cell.text }
            }
            return text
        }.joined(separator: "\n")
    }

    // MARK: - Static tables

    private static func defaultTabStops(cols: Int) -> [Bool] {
        (0..<cols).map { $0 != 0 && $0 % 8 == 0 }
    }

    /// Display width per Unicode's East Asian Width, plus the emoji ranges.
    /// Approximation: this is a table, not a full `wcwidth`, and is documented
    /// as such. Default-ignorable and combining code points are width zero.
    public static func displayWidth(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x20 || (value >= 0x7F && value < 0xA0) { return 0 }
        if scalar.properties.isDefaultIgnorableCodePoint { return 0 }
        if scalar.properties.canonicalCombiningClass != .notReordered { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }
        for range in wideRanges where range.contains(value) { return 2 }
        return 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F,     // Hangul Jamo
        0x2329...0x232A,
        0x2E80...0x303E,     // CJK radicals, Kangxi, CJK symbols
        0x3041...0x33FF,     // kana, CJK compatibility
        0x3400...0x4DBF,     // CJK extension A
        0x4E00...0x9FFF,     // CJK unified ideographs
        0xA000...0xA4CF,     // Yi
        0xA960...0xA97F,     // Hangul Jamo extended A
        0xAC00...0xD7A3,     // Hangul syllables
        0xF900...0xFAFF,     // CJK compatibility ideographs
        0xFE10...0xFE19,
        0xFE30...0xFE6F,
        0xFF00...0xFF60,     // fullwidth forms
        0xFFE0...0xFFE6,
        0x17000...0x18AFF,   // Tangut
        0x1B000...0x1B2FF,
        0x1F300...0x1F64F,   // emoji
        0x1F900...0x1F9FF,
        0x20000...0x2FFFD,   // CJK extensions B-F
        0x30000...0x3FFFD,
    ]

    /// The DEC special graphics set, which curses uses for box drawing.
    private static let decSpecialGraphics: [UInt32: Unicode.Scalar] = [
        0x5F: " ", 0x60: "\u{25C6}", 0x61: "\u{2592}", 0x62: "\u{2409}",
        0x63: "\u{240C}", 0x64: "\u{240D}", 0x65: "\u{240A}", 0x66: "\u{00B0}",
        0x67: "\u{00B1}", 0x68: "\u{2424}", 0x69: "\u{240B}", 0x6A: "\u{2518}",
        0x6B: "\u{2510}", 0x6C: "\u{250C}", 0x6D: "\u{2514}", 0x6E: "\u{253C}",
        0x6F: "\u{23BA}", 0x70: "\u{23BB}", 0x71: "\u{2500}", 0x72: "\u{23BC}",
        0x73: "\u{23BD}", 0x74: "\u{251C}", 0x75: "\u{2524}", 0x76: "\u{2534}",
        0x77: "\u{252C}", 0x78: "\u{2502}", 0x79: "\u{2264}", 0x7A: "\u{2265}",
        0x7B: "\u{03C0}", 0x7C: "\u{2260}", 0x7D: "\u{00A3}", 0x7E: "\u{00B7}",
    ]
}
