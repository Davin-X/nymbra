import AppKit
import CoreText
import NymbraCore
import NymbraInput

/// Draws the screen model onto a character grid with CoreText, one drawn run per
/// row, plus a background rectangle wherever the cell background is not the
/// default.
///
/// Cell metrics are measured from CoreText rather than assumed, so every glyph
/// lands exactly on the grid. This renderer is deliberately simple and is the
/// piece Metal replaces in M3 — `ARCHITECTURE.md` invariant 1 keeps it a pure
/// function of the model, which is what makes that swap cheap.
final class TermView: NSView {
    var onInput: (([UInt8]) -> Void)?
    var onResize: ((GridSize) -> Void)?
    var onFindCancel: (() -> Void)?
    /// A click landed here, so this pane should take the keyboard. Altitude rather
    /// than a decision: which pane is focused is the window's to say.
    var onFocus: (() -> Void)?

    private let screen: Screen

    /// The settings in force. Held rather than read from a global, so the view
    /// stays a pure function of what it was given — which is what makes the
    /// settings window's live preview a matter of calling `apply`.
    private var configuration: Configuration
    private var theme: Theme

    private var font: CTFont
    private var boldFont: CTFont
    private var cellWidth: CGFloat
    private var cellHeight: CGFloat
    private var ascent: CGFloat
    private var descent: CGFloat
    private let paddingX: CGFloat = 10
    private let paddingY: CGFloat = 8

    private(set) var cols: Int
    private(set) var rows: Int

    /// The grid this view currently shows, as one value. The same value the
    /// shell is told about, so the two can only ever agree.
    var grid: GridSize { GridSize(rows: rows, cols: cols) }

    /// Lines the viewport is scrolled up into scrollback. Zero is the live
    /// screen.
    private var scrollOffset = 0
    /// Trackpad scroll deltas are fractional. Carry the remainder between events
    /// so a slow scroll is not rounded away to nothing.
    private var scrollRemainder: CGFloat = 0

    /// Cursor blink phase, and the timer that advances it.
    private var blinkOn = true
    private var blinkTimer: Timer?

    /// Whether this pane has the keyboard. Drawn, because with more than one pane
    /// on screen "where does my typing go?" has to be answerable at a glance: an
    /// unfocused pane shows its cursor as an outline.
    var isFocused = true {
        didSet {
            guard isFocused != oldValue else { return }
            updateBlinkTimer()
            needsDisplay = true
        }
    }

    /// The current selection, if any. An optional rather than an empty selection,
    /// so a plain click clears the highlight instead of leaving one cell lit.
    private var selection: Selection?
    /// Where a drag started. Kept apart from the selection so that the highlight
    /// only appears once the pointer has actually moved.
    private var dragAnchor: Selection.Position?

    init(frame: NSRect, screen: Screen, configuration: Configuration) {
        self.screen = screen
        self.configuration = configuration
        self.theme = Theme(configuration)

        let metrics = TermView.metrics(for: configuration)
        self.font = metrics.font
        self.boldFont = metrics.boldFont
        self.ascent = metrics.ascent
        self.descent = metrics.descent
        self.cellHeight = metrics.cellHeight
        self.cellWidth = metrics.cellWidth

        let size = GridSize(
            fittingWidth: frame.width,
            height: frame.height,
            paddingX: paddingX,
            paddingY: paddingY,
            cellWidth: metrics.cellWidth,
            cellHeight: metrics.cellHeight
        )
        self.cols = size.cols
        self.rows = size.rows

        super.init(frame: frame)
        screen.scrollbackLimit = configuration.behaviour.scrollbackLines
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBlinkTimer()
    }

    /// Apply new settings. Live: the metrics are re-measured and the grid
    /// resized with no restart, which is what makes the settings window's
    /// preview work.
    func apply(_ newConfiguration: Configuration) {
        configuration = newConfiguration
        theme = Theme(newConfiguration)

        let metrics = TermView.metrics(for: newConfiguration)
        font = metrics.font
        boldFont = metrics.boldFont
        ascent = metrics.ascent
        descent = metrics.descent
        cellHeight = metrics.cellHeight
        cellWidth = metrics.cellWidth

        screen.scrollbackLimit = newConfiguration.behaviour.scrollbackLines
        updateGridSize()
        updateBlinkTimer()
        needsDisplay = true
    }

    private func updateGridSize() {
        let size = GridSize(
            fittingWidth: bounds.width,
            height: bounds.height,
            paddingX: paddingX,
            paddingY: paddingY,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
        guard size != grid else { return }
        cols = size.cols
        rows = size.rows
        // A resize invalidates the viewport: the grid moved under it.
        scrollOffset = 0
        scrollRemainder = 0
        onResize?(size)
        needsDisplay = true
    }

    // MARK: - Metrics

    private struct Metrics {
        let font: CTFont
        let boldFont: CTFont
        let ascent: CGFloat
        let descent: CGFloat
        let cellWidth: CGFloat
        let cellHeight: CGFloat
    }

    /// Measure the cell grid from the font rather than assuming it, so every
    /// glyph lands exactly on the grid.
    private static func metrics(for configuration: Configuration) -> Metrics {
        let family = configuration.appearance.fontFamily
        let size = CGFloat(configuration.appearance.fontSize)

        // A family that does not exist would otherwise be substituted silently
        // and, worse, possibly with something that is not monospaced, which
        // breaks the grid. Verify the substitution, and fall back to a font
        // whose metrics we know.
        let requested = CTFontCreateWithName(family as CFString, size, nil)
        let resolved = CTFontCopyFamilyName(requested) as String

        let font: CTFont
        if resolved.caseInsensitiveCompare(family) == .orderedSame {
            font = requested
        } else {
            FileHandle.standardError.write(
                Data("nymbra: no font family \"\(family)\"; using Menlo\n".utf8)
            )
            font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        }

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)

        var character: UniChar = 0x4D  // 'M': the advance every mono glyph shares
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

        return Metrics(
            font: font,
            boldFont: CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font,
            ascent: ascent,
            descent: descent,
            cellWidth: advance.width,
            cellHeight: (ascent + descent + CTFontGetLeading(font)).rounded()
        )
    }

    // MARK: - Cursor

    private var cursorStyle: Screen.CursorStyle {
        screen.effectiveCursorStyle(preference: configuration.behaviour.cursorShape,
                                    blinks: configuration.behaviour.cursorBlinks)
    }

    /// Blink only when the shape asks for it, the setting allows it, and this pane
    /// has the keyboard: a blinking cursor in a pane nobody is typing into is noise.
    private func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true

        guard isFocused, window != nil, cursorStyle.blinks, configuration.behaviour.cursorBlinks else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.blinkOn.toggle()
            self.needsDisplay = true
        }
    }

    /// Typing shows the cursor immediately rather than waiting for the next
    /// tick, so a keystroke never feels unacknowledged.
    private func restartBlink() {
        guard blinkTimer != nil else { return }
        blinkOn = true
    }

    // MARK: - Drawing

    private func cellOrigin(col: Int, row: Int) -> CGPoint {
        CGPoint(x: paddingX + CGFloat(col) * cellWidth,
                y: bounds.height - paddingY - CGFloat(row + 1) * cellHeight)
    }

    private func baseline(row: Int) -> CGFloat {
        bounds.height - paddingY - CGFloat(row + 1) * cellHeight + descent
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(theme.background)
        ctx.fill(bounds)

        // One path for history and live output: ask the model for the rows at
        // the current scroll position, and draw them.
        let lines = screen.displayRows(scrollOffset: scrollOffset)

        // The selection goes under the text, so the text keeps its own colours.
        drawSelection(ctx)
        if let state = findState, !state.query.isEmpty {
            drawFindMatches(state, ctx: ctx)
        }
        for (row, line) in lines.enumerated() { drawRow(line, row: row, ctx: ctx) }

        // The cursor belongs to the live screen, so it is not drawn while the
        // viewport sits up in scrollback.
        if scrollOffset == 0 { drawCursor(ctx) }

    }

    private func drawRow(_ line: [Cell], row: Int, ctx: CGContext) {
        var col = 0
        while col < line.count {
            let attributes = line[col].attributes
            var end = col
            var text = ""
            while end < line.count, line[end].attributes == attributes {
                if !line[end].isWideContinuation { text += line[end].text }
                end += 1
            }
            drawRun(text, col: col, width: end - col, row: row, attributes: attributes, ctx: ctx)
            col = end
        }
    }

    private func drawRun(
        _ text: String,
        col: Int,
        width: Int,
        row: Int,
        attributes: Attributes,
        ctx: CGContext
    ) {
        let (foreground, background) = theme.resolve(attributes, reversed: screen.reverseVideo)
        let hasInk = text.contains { $0 != " " }
        if !hasInk && background == nil { return }

        let origin = cellOrigin(col: col, row: row)
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: origin.x, y: origin.y,
                            width: CGFloat(width) * cellWidth, height: cellHeight))
        }
        guard hasInk else { return }

        if attributes.underline != .none {
            ctx.setFillColor(foreground)
            ctx.fill(CGRect(x: origin.x, y: origin.y + 1,
                            width: CGFloat(width) * cellWidth, height: 1))
        }

        let font = attributes.bold ? boldFont : self.font
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): foreground,
            ]
        ))
        ctx.textPosition = CGPoint(x: origin.x, y: baseline(row: row))
        CTLineDraw(line, ctx)
    }

    /// One rectangle per selected run of cells, rather than one per cell: a
    /// screenful of selections is otherwise hundreds of fills.
    private func drawSelection(_ ctx: CGContext) {
        guard let selection, !selection.isEmpty else { return }
        let (start, end) = selection.ordered
        ctx.setFillColor(theme.selection)

        for row in start.row...max(start.row, end.row) {
            guard row >= 0, row < rows else { continue }
            let first = row == start.row ? start.col : 0
            let last = row == end.row ? end.col : cols - 1
            guard first <= last else { continue }
            let origin = cellOrigin(col: first, row: row)
            ctx.fill(CGRect(x: origin.x, y: origin.y,
                            width: CGFloat(last - first + 1) * cellWidth,
                            height: cellHeight))
        }
    }

    private func drawCursor(_ ctx: CGContext) {
        guard screen.cursor.visible else { return }

        // The user's preference applies until a program asks for a shape of its
        // own with DECSCUSR; after that the program wins, which is what `vim`
        // and `fish` expect.
        let style = cursorStyle
        if style.blinks, !blinkOn { return }

        guard isFocused else {
            drawUnfocusedCursor(ctx, style: style)
            return
        }

        let cursor = screen.cursor
        let origin = cellOrigin(col: cursor.col, row: cursor.row)

        switch style {
        case .bar, .barBlink:
            ctx.setFillColor(theme.cursor)
            ctx.fill(CGRect(x: origin.x, y: origin.y, width: 2, height: cellHeight))
        case .underline, .underlineBlink:
            ctx.setFillColor(theme.cursor)
            ctx.fill(CGRect(x: origin.x, y: origin.y, width: cellWidth, height: 2))
        case .block, .blockBlink:
            let cell = screen.cell(row: cursor.row, col: cursor.col)
            ctx.setFillColor(theme.cursor)
            ctx.fill(CGRect(x: origin.x, y: origin.y, width: cellWidth, height: cellHeight))
            guard !cell.isBlank, !cell.isWideContinuation else { return }
            // The glyph under a block cursor is drawn in the background colour,
            // so it stays readable rather than becoming a silhouette.
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: cell.text,
                attributes: [
                    .init(kCTFontAttributeName as String): font,
                    .init(kCTForegroundColorAttributeName as String): theme.background,
                ]
            ))
            ctx.textPosition = CGPoint(x: origin.x, y: baseline(row: cursor.row))
            CTLineDraw(line, ctx)
        }
    }

    /// The cursor of a pane that does not have the keyboard: the same shape, drawn
    /// as an outline. Visible enough to say "there is a cursor here", not filled
    /// enough to claim that typing lands here.
    private func drawUnfocusedCursor(_ ctx: CGContext, style: Screen.CursorStyle) {
        let cursor = screen.cursor
        let origin = cellOrigin(col: cursor.col, row: cursor.row)
        ctx.setStrokeColor(theme.cursor)
        ctx.setLineWidth(1)

        let rect: CGRect
        switch style {
        case .bar, .barBlink:
            rect = CGRect(x: origin.x + 0.5, y: origin.y, width: 1, height: cellHeight - 1)
        case .underline, .underlineBlink:
            rect = CGRect(x: origin.x, y: origin.y + cellHeight - 1.5, width: cellWidth - 1, height: 1)
        case .block, .blockBlink:
            rect = CGRect(x: origin.x + 0.5, y: origin.y + 0.5,
                          width: cellWidth - 1, height: cellHeight - 1)
        }
        ctx.stroke(rect)
    }


    /// Highlight search results in the visible terminal text.
    private func drawFindMatches(_ state: FindState, ctx: CGContext) {
        guard !state.matches.isEmpty else { return }
        func colorWithAlpha(_ color: CGColor, alpha: CGFloat) -> CGColor {
            guard let components = color.components, components.count >= 3 else { return color }
            return CGColor(red: components[0], green: components[1], blue: components[2], alpha: alpha)
        }

        for (index, match) in state.matches.enumerated() {
            // A match is recorded as an absolute row — scrollback included — and
            // has to be moved into the viewport the same way the text is, or the
            // highlight lands a screenful away from what it is highlighting.
            let viewportRow = match.row - screen.viewportFirstRow(scrollOffset: scrollOffset)
            guard viewportRow >= 0, viewportRow < screen.rows else { continue }

            let origin = cellOrigin(col: match.column, row: viewportRow)
            let matchWidth = CGFloat(match.columns) * cellWidth

            // Current match gets a different color
            if index == state.currentIndex {
                ctx.setFillColor(colorWithAlpha(theme.cursor, alpha: 0.4))
            } else {
                ctx.setFillColor(theme.foreground.copy(alpha: 0.15)!)
            }
            ctx.fill(CGRect(x: origin.x, y: origin.y,
                            width: matchWidth, height: cellHeight))
        }
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Command chords belong to the application, and the menu bar handles
        // them: its key equivalents come from the same command list the settings
        // window shows. There is nothing here to send to the program.
        if flags.contains(.command) { return }

        // Escape closes the find overlay.
        if findState != nil, event.keyCode == 53 { // Escape
            if let onFindCancel {
                onFindCancel()
            } else {
                endFind()
            }
            return
        }

        // Typing returns to the live screen, the way every terminal behaves: you
        // cannot type into history.
        returnToLiveScreen()
        restartBlink()

        // The mapping itself lives in NymbraInput, where it is asserted without
        // a window. This method is only the AppKit boundary.
        let bytes = Keyboard.bytes(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: Self.modifiers(from: flags),
            applicationCursorKeys: screen.applicationCursorKeys
        )
        if !bytes.isEmpty { onInput?(bytes) }
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> Keyboard.Modifiers {
        var modifiers: Keyboard.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    // MARK: - Scrollback

    /// Wheel and trackpad scrolling moves the viewport through scrollback rather
    /// than going to the program, which is what a user expects. Mouse reporting
    /// takes precedence over this once it lands.
    override func scrollWheel(with event: NSEvent) {
        // Mouse reporting takes precedence over scrollback scrolling: a program
        // that asked for mouse events gets scroll-up/down buttons instead.
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
        guard !screen.scrollback.isEmpty else { return }
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += event.scrollingDeltaY
            let lines = (scrollRemainder / cellHeight).rounded(.towardZero)
            scrollRemainder -= lines * cellHeight
            scroll(by: Int(lines))
        } else {
            scroll(by: Int(event.scrollingDeltaY))
        }
    }

    /// Positive moves the viewport up into history, the direction a scroll-up
    /// gesture produces. Clamped by the model, so the oldest line is the floor.
    private func scroll(by lines: Int) {
        guard lines != 0 else { return }
        let updated = min(max(0, scrollOffset + lines), screen.scrollback.count)
        guard updated != scrollOffset else { return }
        scrollOffset = updated
        needsDisplay = true
    }

    private func returnToLiveScreen() {
        guard scrollOffset != 0 else { return }
        scrollOffset = 0
        scrollRemainder = 0
        needsDisplay = true
    }

    /// Cmd+V. Wrapped in the bracketed-paste guards when the program asked for
    /// them, so a paste is not read as typing.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        var bytes = Array(text.utf8)
        if screen.bracketedPaste {
            bytes = Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8)
        }
        let newlinesRemoved = bytes.map { $0 == 0x0A ? 0x0D : $0 }
        onInput?(newlinesRemoved)
    }

    // MARK: - Mouse reporting

    /// Convert an NSEvent into xterm mouse-protocol bytes, or nil when the
    /// event is not a mouse report (or mouse reporting is off).
    ///
    /// X10:   ESC [ M Cb Cx Cy        (press only; no release, no motion)
    /// SGR:   ESC [ < Cb ; Cx ; Cy M  (M = press, m = release)
    ///
    /// Coordinates are 0-based grid cells; xterm adds 33 to each byte.
    /// Button byte: low 3 bits = button (0=left,1=middle,2=right,3=release),
    /// bit 3 = shift, bit 4 = option, bit 5 = control.
    private func mouseReportBytes(for event: NSEvent) -> [UInt8]? {
        guard screen.mouseMode != .off else { return nil }

        let location = convert(event.locationInWindow, from: nil)
        guard let position = cellPosition(at: location) else { return nil }
        let cx = position.col + 33
        let cy = position.row + 33

        var button: Int
        var isRelease = false
        var isMotion = false
        switch event.type {
        case .leftMouseDown:   button = 0; isRelease = false; isMotion = false
        case .leftMouseUp:     button = 0; isRelease = true;  isMotion = false
        case .rightMouseDown:  button = 2; isRelease = false; isMotion = false
        case .rightMouseUp:    button = 2; isRelease = true;  isMotion = false
        case .otherMouseDown:  button = 1; isRelease = false; isMotion = false
        case .otherMouseUp:    button = 1; isRelease = true;  isMotion = false
        case .leftMouseDragged:   button = 0; isRelease = false; isMotion = true
        case .rightMouseDragged:  button = 2; isRelease = false; isMotion = true
        case .otherMouseDragged:  button = 1; isRelease = false; isMotion = true
        case .mouseMoved:         button = 3; isRelease = false; isMotion = true
        case .scrollWheel:
            button = event.scrollingDeltaY < 0 ? 4 : 5; isRelease = false; isMotion = false
        default: return nil
        }

        // Mode gating: click mode has no motion; drag mode has motion only with a
        // button held (a bare move is not reported).
        if isMotion {
            if screen.mouseMode == .click { return nil }
            if screen.mouseMode == .drag && button == 3 { return nil }
        }

        var cb = button
        if isMotion { cb |= 0x40 }
        if event.modifierFlags.contains(.shift)   { cb |= 0x08 }
        if event.modifierFlags.contains(.option)  { cb |= 0x10 }
        if event.modifierFlags.contains(.control) { cb |= 0x20 }

        // Scroll wheel: buttons 4 (up) and 5 (down).
        if event.type == .scrollWheel {
            cb = event.scrollingDeltaY < 0 ? 4 : 5
        }

        switch screen.mouseEncoding {
        case .x10:
            // X10 only reports presses (no motion, no release).
            guard !isRelease, !isMotion else { return nil }
            return [0x1B, 0x5B, 0x4D, UInt8(cb + 32), UInt8(cx), UInt8(cy)]
        case .sgr:
            let marker: UInt8 = isRelease ? 0x6D : 0x4D  // 'm' or 'M'
            return [0x1B, 0x5B, 0x3C] + Array("\(cb);\(cx);\(cy)".utf8) + [marker]
        }
    }

    /// Send a mouse report to the PTY if mouse reporting is enabled.
    /// `isMotion` suppresses the report in `.click` mode, which has no motion.
    private func sendMouseReport(for event: NSEvent) {
        guard let bytes = mouseReportBytes(for: event) else { return }
        onInput?(bytes)
    }

    override func mouseMoved(with event: NSEvent) {
        // Mode 1003 (any-event tracking) reports motion without a button. The
        // other modes ignore a bare move, and mouseReportBytes says so.
        guard screen.mouseMode == .motion else { return }
        sendMouseReport(for: event)
    }

    // MARK: - Selection

    override func mouseDown(with event: NSEvent) {
        // Mouse reporting takes precedence over selection: when a program has
        // asked for mouse events, they go to the PTY, not to the highlight.
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
        window?.makeFirstResponder(self)
        // Told, not asked: the window decides which pane has the keyboard, and it
        // is the one that has to draw the change.
        onFocus?()
        let point = convert(event.locationInWindow, from: nil)
        guard let position = cellPosition(at: point) else { return }

        if event.clickCount == 2 {
            selection = Selection.word(in: screen, row: position.row, col: position.col,
                                       scrollOffset: scrollOffset)
            dragAnchor = nil
        } else if event.clickCount >= 3 {
            selection = Selection.line(in: screen, row: position.row, scrollOffset: scrollOffset)
            dragAnchor = nil
        } else if event.modifierFlags.contains(.shift), let existing = selection {
            // Shift-click extends what is already selected rather than starting
            // again.
            selection = Selection(anchor: existing.anchor, head: position)
            dragAnchor = nil
        } else {
            selection = nil
            dragAnchor = position
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        // A drag after a double-click keeps the word selected; only a plain drag
        // starts a new selection. Mouse reporting takes precedence.
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
        guard let anchor = dragAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let position = cellPosition(at: point) else { return }
        selection = Selection(anchor: anchor, head: position)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Mouse reporting takes precedence over selection.
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
        dragAnchor = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
        // Right-click without mouse reporting does nothing by default.
    }

    override func rightMouseUp(with event: NSEvent) {
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if screen.mouseMode != .off {
            sendMouseReport(for: event)
            return
        }
    }

    /// The cell under a point, in viewport coordinates. Points outside the grid
    /// clamp to the nearest cell, so dragging off the edge selects to the edge
    /// rather than stopping dead.
    private func cellPosition(at point: CGPoint) -> Selection.Position? {
        let relative = bounds.height - paddingY - point.y
        let row = Int((relative / cellHeight).rounded(.up)) - 1
        let col = Int((point.x - paddingX) / cellWidth)
        return Selection.Position(row: min(max(row, 0), max(0, rows - 1)),
                                  col: min(max(col, 0), max(0, cols - 1)))
    }

    // MARK: - Clipboard

    /// Copy the selection. Returns whether anything was copied, so the caller can
    /// tell "nothing selected" from "copied".
    @discardableResult
    func copySelectionToPasteboard() -> Bool {
        guard let selection else { return false }
        let text = selection.text(in: screen, scrollOffset: scrollOffset)
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// Paste, wrapped in the bracketed-paste guards when the program asked for
    /// them, so a paste is not read as typing. Newlines become carriage returns,
    /// which is what a line editor expects from a paste.
    func pasteFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        var bytes = Array(text.utf8)
        if screen.bracketedPaste {
            bytes = Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8)
        }
        onInput?(bytes.map { $0 == 0x0A ? 0x0D : $0 })
    }

    func selectEverything() {
        guard scrollOffset == 0 else {
            // Selecting while scrolled back would select history the user cannot
            // see the end of, so return to the live screen first.
            returnToLiveScreen()
            return
        }
        selection = Selection.all(of: screen)
        needsDisplay = true
    }

    /// Clear the screen and the saved lines. `ED 3` is exactly "erase saved
    /// lines", which is the same thing xterm's Clear Scrollback does.
    func clearBuffer() {
        selection = nil
        screen.eraseInDisplay(3)
        returnToLiveScreen()
        needsDisplay = true
    }

    // MARK: - Find

    /// State for the find overlay.
    private struct FindState {
        var query: String = ""
        var options = FindOptions.standard
        var matches: [FindMatch] = []
        var currentIndex: Int = -1
        /// The query was a regular expression that did not compile. Kept apart
        /// from "no matches", because they are two different things to be told.
        var invalidPattern = false
    }

    private var findState: FindState?
    var findHasMatches: Bool { findState?.matches.isEmpty == false }
    var findStatus: String {
        guard let state = findState, !state.query.isEmpty else { return "0 matches" }
        if state.invalidPattern { return "Invalid regex" }
        guard !state.matches.isEmpty else { return "No matches" }
        return "\(state.currentIndex + 1) of \(state.matches.count)"
    }

    /// Open the find overlay with the given query (empty to start fresh).
    func startFind(query: String = "", options: FindOptions = .standard) {
        findState = FindState(query: query, options: options)
        findAll()
        needsDisplay = true
    }

    func updateFind(query: String, options: FindOptions) {
        startFind(query: query, options: options)
    }

    func endFind() {
        findState = nil
        needsDisplay = true
    }

    func findNext() {
        guard var state = findState, !state.matches.isEmpty else { return }
        state.currentIndex = (state.currentIndex + 1) % state.matches.count
        findState = state
        scrollToMatch(state.matches[state.currentIndex])
    }

    func findPrevious() {
        guard var state = findState, !state.matches.isEmpty else { return }
        state.currentIndex = (state.currentIndex - 1 + state.matches.count) % state.matches.count
        findState = state
        scrollToMatch(state.matches[state.currentIndex])
    }

    private func findAll() {
        guard var state = findState else { return }
        // The matching itself is the model's, so it is asserted there: what this
        // method owns is turning a result into what the overlay draws and which
        // match is current.
        switch Find.matches(in: screen, query: state.query, options: state.options) {
        case .invalidPattern:
            state.matches = []
            state.invalidPattern = true
            state.currentIndex = -1
        case .matches(let matches):
            state.matches = matches
            state.invalidPattern = false
            state.currentIndex = matches.isEmpty ? -1 : 0
        }
        findState = state
        if state.currentIndex >= 0 {
            scrollToMatch(state.matches[state.currentIndex])
        }
    }

    private func scrollToMatch(_ match: FindMatch) {
        let targetRow = match.row
        // Scroll so the match is in the middle of the viewport if possible.
        let offset = max(0, targetRow - screen.rows / 2)
        scrollOffset = max(0, min(offset, screen.scrollback.count))
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        // Swallow the system beep for keys we do not handle.
        if selector == #selector(NSResponder.insertNewline(_:)) { return }
        super.doCommand(by: selector)
    }
}
