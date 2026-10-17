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

    /// Blink only when the shape asks for it, the setting allows it, and the
    /// window is focused: a blinking cursor in an unfocused window is noise.
    private func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true

        guard window != nil, cursorStyle.blinks, configuration.behaviour.cursorBlinks else { return }
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

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Command chords belong to the application, and the menu bar handles
        // them: its key equivalents come from the same command list the settings
        // window shows. There is nothing here to send to the program.
        if flags.contains(.command) { return }

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

    // MARK: - Selection

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
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
        // starts a new selection.
        guard let anchor = dragAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let position = cellPosition(at: point) else { return }
        selection = Selection(anchor: anchor, head: position)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
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

    override func doCommand(by selector: Selector) {
        // Swallow the system beep for keys we do not handle.
        if selector == #selector(NSResponder.insertNewline(_:)) { return }
        super.doCommand(by: selector)
    }
}


