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

        /// Whether the shape blinks, so callers that only care about that do not
        /// have to pattern-match on all six cases.
        public var blinks: Bool {
            switch self {
            case .blockBlink, .underlineBlink, .barBlink: return true
            case .block, .underline, .bar: return false
            }
        }

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

    /// Encode a mouse event into xterm mouse-protocol bytes, or nil when the
    /// current mode and encoding produce no report for it.
    ///
    /// This is the only part of mouse reporting that can be asserted without a
    /// window: an NSEvent is AppKit, but the bytes it becomes are not. Keeping the
    /// encoding here means `--mouse-test` can check every mode and encoding with
    /// nothing but integers.
    ///
    /// X10:   ESC [ M Cb Cx Cy        (press only; no release, no motion)
    /// SGR:   ESC [ < Cb ; Cx ; Cy M  (M = press/motion, m = release)
    ///
    /// Coordinates are 0-based grid cells; xterm adds 33 to each byte.
    public static func mouseReport(mode: MouseMode, encoding: MouseEncoding,
                                  button: Int, col: Int, row: Int,
                                  shift: Bool = false, option: Bool = false,
                                  control: Bool = false,
                                  isMotion: Bool = false, isRelease: Bool = false,
                                  isScrollWheel: Bool = false, scrollDeltaY: Double = 0) -> [UInt8]? {
        guard mode != .off else { return nil }
        if isMotion {
            if mode == .click { return nil }
            if mode == .drag && button == 3 { return nil }
        }

        let cx = col + 33
        let cy = row + 33
        var cb = button
        var pressed = !isRelease
        if isMotion { cb |= 0x40 }
        if shift { cb |= 0x08 }
        if option { cb |= 0x10 }
        if control { cb |= 0x20 }
        if isScrollWheel {
            cb = scrollDeltaY < 0 ? 4 : 5
            pressed = true
        }

        switch encoding {
        case .x10:
            guard !isRelease, !isMotion else { return nil }
            return [0x1B, 0x5B, 0x4D, UInt8(cb + 32), UInt8(cx), UInt8(cy)]
        case .sgr:
            let marker: UInt8 = isRelease ? 0x6D : 0x4D  // 'm' or 'M'
            return [0x1B, 0x5B, 0x3C] + Array("\(cb);\(cx);\(cy)".utf8) + [marker]
        }
    }

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
    /// Whether each row was broken by the terminal itself (a soft wrap) rather
    /// than by a line feed. A soft-wrapped row is a continuation of the one
    /// above it, which is what makes reflow on resize possible: the rows
    /// that were joined by the terminal can be joined again, and only those.
    private var softWrapped: [Bool] = []
    public var scrollbackLimit = 10_000

    private var savedPrimaryGrid: [Cell] = []
    private var savedPrimarySoftWrapped: [Bool] = []
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
        self.softWrapped = Array(repeating: false, count: r)
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
        let before = cursor.row
        lineFeed()
        // The row we landed on is a continuation of the one above: that is what
        // makes it a soft wrap, and it is the only thing that lets reflow know
        // which rows were broken by the terminal rather than by a newline.
        if cursor.row >= 0 && cursor.row < rows && cursor.row != before {
            softWrapped[cursor.row] = true
        }
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
                softWrapped[row] = softWrapped[row + 1]
            }
            for col in 0..<cols { grid[scrollBottom * cols + col] = blankCell() }
            softWrapped[scrollBottom] = false
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
                softWrapped[row] = softWrapped[row - 1]
                row -= 1
            }
            for col in 0..<cols { grid[scrollTop * cols + col] = blankCell() }
            softWrapped[scrollTop] = false
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
            savedPrimarySoftWrapped = softWrapped
            grid = Array(repeating: Cell(), count: rows * cols)
            softWrapped = Array(repeating: false, count: rows)
            altScreenActive = true
            cursor = Cursor()
            scrollTop = 0
            scrollBottom = rows - 1
        } else {
            grid = savedPrimaryGrid
            softWrapped = savedPrimarySoftWrapped
            savedPrimaryGrid = []
            savedPrimarySoftWrapped = []
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
        cursorStyleChosen = true
    }

    /// True once the running program has chosen a cursor shape. Until it has,
    /// the user's preference applies; after that the program's request wins,
    /// which is what `vim` and `fish` expect.
    public private(set) var cursorStyleChosen = false

    /// The shape to draw.
    public func effectiveCursorStyle(
        preference: Configuration.Behaviour.CursorShape,
        blinks: Bool
    ) -> CursorStyle {
        if cursorStyleChosen { return cursor.style }
        switch preference {
        case .block: return blinks ? .blockBlink : .block
        case .bar: return blinks ? .barBlink : .bar
        case .underline: return blinks ? .underlineBlink : .underline
        }
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
        softWrapped = Array(repeating: false, count: rows)
    }

    /// DECALN (`ESC # 8`): the alignment test pattern.
    public func alignmentTest() {
        let blank = Cell(content: .scalar("E"), attributes: Attributes())
        for row in 0..<rows {
            for col in 0..<cols { grid[offset(row, col)] = blank }
        }
        cursor = Cursor()
    }

    /// Resize, preserving content. Soft-wrapped lines are reflowed into the new
    /// width; a line that was broken by the terminal itself is joined or split as
    /// the width demands, and a line that came from an explicit newline is not.
    public func resize(rows newRows: Int, cols newCols: Int) {
        let r = max(1, newRows)
        let c = max(1, newCols)
        guard r != rows || c != cols else { return }

        if altScreenActive {
            // An application owns the alt screen and reacts to SIGWINCH itself;
            // preserving its content verbatim is what it expects.
            resizeSimple(rows: r, cols: c)
            return
        }

        // Collect the primary screen as logical lines. A row whose
        // `softWrapped` is set is a continuation of the line above it, so the
        // logical line runs through it; a row that is not soft-wrapped starts a
        // new one. Trailing blanks are trimmed only from the last row of each
        // logical line, since the earlier rows were filled by the terminal.
        var logicalLines: [[Cell]] = []
        var current: [Cell] = []
        for row in 0..<rows {
            if row > 0 && !softWrapped[row] && !current.isEmpty {
                while !current.isEmpty, current.last!.content == .empty,
                      !current.last!.isWideContinuation {
                    current.removeLast()
                }
                logicalLines.append(current)
                current = []
            }
            current.append(contentsOf: Array(grid[(row * cols)..<((row + 1) * cols)]))
        }
        if !current.isEmpty {
            while !current.isEmpty, current.last!.content == .empty,
                  !current.last!.isWideContinuation {
                current.removeLast()
            }
            logicalLines.append(current)
        }
        if logicalLines.isEmpty { logicalLines.append([]) }
        // Reflow each logical line into the new width.
        var newGrid = [Cell](repeating: Cell(), count: r * c)
        var newSoft = Array(repeating: false, count: r)
        var row = 0
        for line in logicalLines {
            if row >= r { break }
            let (rows, soft) = reflow(line, into: c)
            for (i, cells) in rows.enumerated() {
                if row + i >= r { break }
                for (col, cell) in cells.enumerated() {
                    if col < c { newGrid[(row + i) * c + col] = cell }
                }
                newSoft[row + i] = (i > 0) && soft[i]
            }
            row += rows.count
        }

        grid = newGrid
        softWrapped = newSoft
        rows = r
        cols = c

        // Cursor: preserve the logical line and offset as best we can. A full
        // mapping is owed; for now, clamp, which matches the previous behaviour.
        cursor.row = min(cursor.row, r - 1)
        cursor.col = min(cursor.col, c - 1)
        cursor.pendingWrap = false

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

        // Reflow the scrollback too: each entry is one hard line, so it is
        // padded or trimmed to the new width rather than joined.
        for i in scrollback.indices {
            var line = scrollback[i]
            if line.count < c {
                line.append(contentsOf: Array(repeating: Cell(), count: c - line.count))
            } else if line.count > c {
                line = Array(line.prefix(c))
            }
            scrollback[i] = line
        }
    }

    /// The old resize: preserve what fits, trim the rest. Used for the alt screen,
    /// where the application reacts to SIGWINCH itself.
    private func resizeSimple(rows r: Int, cols c: Int) {
        guard r != rows || c != cols else { return }
        var next = [Cell](repeating: Cell(), count: r * c)
        let copyRows = min(rows, r)
        let copyCols = min(cols, c)
        for row in 0..<copyRows {
            for col in 0..<copyCols {
                next[row * c + col] = grid[row * cols + col]
            }
        }
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
        softWrapped = Array(repeating: false, count: r)
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

    /// Reflow one logical line's cells into `width` columns.
    private func reflow(_ cells: [Cell], into width: Int) -> (rows: [[Cell]], soft: [Bool]) {
        let w = max(1, width)
        var rows: [[Cell]] = [[]]
        var soft: [Bool] = [false]
        var col = 0
        for cell in cells where !cell.isWideContinuation {
            let cw = max(1, Screen.displayWidth(of: cell.scalarOrBlank))
            if col + cw > w {
                while rows[rows.count - 1].count < w { rows[rows.count - 1].append(Cell()) }
                rows.append([])
                soft.append(true)
                col = 0
            }
            if cw > w {
                // A cell wider than the whole line: drop it rather than corrupt the grid.
                continue
            }
            rows[rows.count - 1].append(cell)
            if cw == 2 {
                rows[rows.count - 1].append(Cell(content: .empty, attributes: cell.attributes, isWideContinuation: true))
            }
            col += cw
            if col == w {
                // Exact fit: the next cell wraps. Leave col == w so the next
                // iteration wraps; do not append a blank row yet.
            }
        }
        while rows[rows.count - 1].count < w { rows[rows.count - 1].append(Cell()) }
        return (rows, soft)
    }

    // MARK: - Reading

    /// One row as text. Wide continuations are skipped; trailing blanks are
    /// trimmed by default, which is what conformance cases want to compare.
    public func rowText(_ row: Int, trim: Bool = true) -> String {
        guard row >= 0, row < rows else { return "" }
        var text = Screen.text(ofLine: Array(grid[(row * cols)..<((row + 1) * cols)]))
        if !trim { return text }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    /// One row of cells as text, skipping the trailing half of wide characters.
    /// Used to read the screen model back out — for the clipboard, and for tests
    /// that want the text a user sees rather than the cell grid.
    public static func text(ofLine line: [Cell]) -> String {
        var text = ""
        for cell in line where !cell.isWideContinuation { text += cell.text }
        return text
    }

    /// The rows to draw, oldest first, with `scrollOffset` lines of scrollback
    /// shown above the live screen.
    ///
    /// The renderer does not know scrollback exists: it draws whatever this
    /// returns, which is what keeps history and live output on one code path and
    /// one set of tests. `scrollOffset` is clamped, so a viewport cannot be
    /// scrolled past the oldest line held.
    ///
    /// This allocates per call, which is fine for the CoreText renderer of this
    /// milestone and is one of the things Metal replaces.
    public func displayRows(scrollOffset: Int) -> [[Cell]] {
        let live = (0..<rows).map { row in
            Array(grid[(row * cols)..<((row + 1) * cols)])
        }
        guard scrollOffset > 0, !scrollback.isEmpty else { return live }

        let combined = scrollback + live
        let first = viewportFirstRow(scrollOffset: scrollOffset)
        return Array(combined[first..<Swift.min(first + rows, combined.count)])
    }

    /// The absolute row of the scrollback-plus-live screen that the viewport's
    /// first line is showing.
    ///
    /// Anything that has to line up with what a view draws — the find highlight
    /// most of all, which is painted cell by cell over the text — has to agree
    /// with this one number rather than work it out again. Getting it wrong by
    /// `rows` is invisible in the model and unmissable once rendered: the
    /// highlight is drawn a screenful away from the match, or dropped entirely.
    public func viewportFirstRow(scrollOffset: Int) -> Int {
        scrollback.count - Swift.min(Swift.max(scrollOffset, 0), scrollback.count)
    }

    /// Whether the given absolute row (in the scrollback + live space) is a
    /// soft-wrapped continuation of the row above it. Only live rows can be
    /// soft-wrapped; scrollback rows are always false because the wrap
    /// relationship is not preserved once a row leaves the live screen.
    ///
    /// This is what lets the find matcher join rows that were broken by the
    /// terminal's auto-wrap, so a search can find text that spans the wrap.
    public func isSoftWrapped(absoluteRow: Int) -> Bool {
        // The live screen starts at absolute row `scrollback.count`
        let liveRow = absoluteRow - scrollback.count
        guard liveRow >= 0, liveRow < rows else { return false }
        return softWrapped[liveRow]
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
