import AppKit
import CoreText
import NymbraCore

/// Draws the screen model onto a character grid with CoreText, one drawn run per
/// row, plus a background rectangle wherever the cell background is not the
/// default.
///
/// Cell metrics are measured from CoreText rather than assumed, so every glyph
/// lands exactly on the grid. This renderer is deliberately simple and is the
/// piece Metal replaces in M2 — `ARCHITECTURE.md` invariant 1 keeps it a pure
/// function of the model, which is what makes that swap cheap.
final class TermView: NSView {
    var onInput: (([UInt8]) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    private let screen: Screen
    private let font: CTFont
    private let boldFont: CTFont
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat
    private let ascent: CGFloat
    private let descent: CGFloat
    private let paddingX: CGFloat = 10
    private let paddingY: CGFloat = 8

    private(set) var cols: Int
    private(set) var rows: Int

    init(frame: NSRect, screen: Screen) {
        self.screen = screen
        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        self.font = font
        self.boldFont = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
        self.ascent = CTFontGetAscent(font)
        self.descent = CTFontGetDescent(font)
        self.cellHeight = (ascent + descent + CTFontGetLeading(font)).rounded()

        var character: UniChar = 0x4D  // 'M': the advance every mono glyph shares
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        self.cellWidth = advance.width

        self.cols = max(1, Int((frame.width - paddingX * 2) / advance.width))
        self.rows = max(1, Int((frame.height - paddingY * 2) / cellHeight))
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let newCols = max(1, Int((newSize.width - paddingX * 2) / cellWidth))
        let newRows = max(1, Int((newSize.height - paddingY * 2) / cellHeight))
        if newCols != cols || newRows != rows {
            cols = newCols
            rows = newRows
            onResize?(newCols, newRows)
            needsDisplay = true
        }
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
        ctx.setFillColor(Theme.background)
        ctx.fill(bounds)

        for row in 0..<screen.rows { drawRow(row, ctx) }
        drawCursor(ctx)
    }

    private func drawRow(_ row: Int, _ ctx: CGContext) {
        var col = 0
        while col < screen.cols {
            let attributes = screen.cell(row: row, col: col).attributes
            var end = col
            var text = ""
            while end < screen.cols, screen.cell(row: row, col: end).attributes == attributes {
                let cell = screen.cell(row: row, col: end)
                if !cell.isWideContinuation { text += cell.text }
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
        let (foreground, background) = Theme.resolve(attributes, reversed: screen.reverseVideo)
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

    private func drawCursor(_ ctx: CGContext) {
        guard screen.cursor.visible else { return }
        let cursor = screen.cursor
        let origin = cellOrigin(col: cursor.col, row: cursor.row)

        switch cursor.style {
        case .bar, .barBlink:
            ctx.setFillColor(Theme.cursor)
            ctx.fill(CGRect(x: origin.x, y: origin.y, width: 2, height: cellHeight))
        case .underline, .underlineBlink:
            ctx.setFillColor(Theme.cursor)
            ctx.fill(CGRect(x: origin.x, y: origin.y, width: cellWidth, height: 2))
        default:
            let cell = screen.cell(row: cursor.row, col: cursor.col)
            ctx.setFillColor(Theme.cursor)
            ctx.fill(CGRect(x: origin.x, y: origin.y, width: cellWidth, height: cellHeight))
            guard !cell.isBlank, !cell.isWideContinuation else { return }
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: cell.text,
                attributes: [
                    .init(kCTFontAttributeName as String): font,
                    .init(kCTForegroundColorAttributeName as String): Theme.background,
                ]
            ))
            ctx.textPosition = CGPoint(x: origin.x, y: baseline(row: cursor.row))
            CTLineDraw(line, ctx)
        }
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "v" { paste(nil) }
            return
        }

        var bytes: [UInt8] = []

        switch event.keyCode {
        case 36, 76:  bytes = [0x0D]                          // return, keypad enter
        case 51:      bytes = [0x7F]                          // delete
        case 117:     bytes = Array("\u{1B}[3~".utf8)         // forward delete
        case 48:      bytes = flags.contains(.shift) ? Array("\u{1B}[Z".utf8) : [0x09]
        case 53:      bytes = [0x1B]                          // escape
        case 126:     bytes = cursorKey(0x41)                 // up
        case 125:     bytes = cursorKey(0x42)                 // down
        case 124:     bytes = cursorKey(0x43)                 // right
        case 123:     bytes = cursorKey(0x44)                 // left
        case 115:     bytes = cursorKey(0x48)                 // home
        case 119:     bytes = cursorKey(0x46)                 // end
        case 116:     bytes = Array("\u{1B}[5~".utf8)         // page up
        case 121:     bytes = Array("\u{1B}[6~".utf8)         // page down
        default:
            // Option is the meta key: send ESC before the character, which is
            // what readline expects for M-f, M-b and friends.
            if flags.contains(.option), let characters = event.charactersIgnoringModifiers {
                bytes = [0x1B] + Array(characters.utf8)
            } else if let characters = event.characters {
                bytes = Array(characters.utf8)
            }
        }

        if !bytes.isEmpty { onInput?(bytes) }
    }

    /// DECCKM: in application mode the arrow keys send `ESC O x`, otherwise
    /// `ESC [ x`.
    private func cursorKey(_ final: UInt8) -> [UInt8] {
        screen.applicationCursorKeys ? [0x1B, 0x4F, final] : [0x1B, 0x5B, final]
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

    override func doCommand(by selector: Selector) {
        // Swallow the system beep for keys we do not handle.
        if selector == #selector(NSResponder.insertNewline(_:)) { return }
        super.doCommand(by: selector)
    }
}

/// The colour scheme, in one place so M6's themes have an obvious home.
enum Theme {
    static let background = CGColor(red: 0.043, green: 0.055, blue: 0.094, alpha: 1)
    static let foreground = CGColor(red: 0.85, green: 0.90, blue: 1.0, alpha: 1)
    static let cursor = CGColor(red: 0.85, green: 0.90, blue: 1.0, alpha: 1)

    /// Resolve a pair of attributes to concrete colours. `nil` means "the
    /// default background", which lets a run with no background skip its
    /// rectangle entirely.
    static func resolve(_ attributes: Attributes, reversed: Bool) -> (CGColor, CGColor?) {
        var foreground = attributes.foreground
        var background = attributes.background
        if attributes.inverse != reversed {
            swap(&foreground, &background)
        }
        if attributes.conceal {
            foreground = background
        }
        let fg = resolve(foreground) ?? Self.foreground
        let bg = resolve(background)
        return (fg, bg)
    }

    private static func resolve(_ colour: Colour) -> CGColor? {
        switch colour {
        case .default: return nil
        case .indexed(let index): return palette[Int(index)]
        case .rgb(let r, let g, let b):
            return CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// The xterm 256-colour palette: 16 system colours, a 6×6×6 cube, then a
    /// 24-step greyscale ramp.
    static let palette: [CGColor] = {
        let system: [(Int, Int, Int)] = [
            (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
            (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
            (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]
        var colours = system.map {
            CGColor(red: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: 1)
        }
        let levels: [CGFloat] = [0, 95, 135, 175, 215, 255].map { $0 / 255 }
        for r in levels {
            for g in levels {
                for b in levels {
                    colours.append(CGColor(red: r, green: g, blue: b, alpha: 1))
                }
            }
        }
        for step in 0..<24 {
            let value = CGFloat(8 + step * 10) / 255
            colours.append(CGColor(red: value, green: value, blue: value, alpha: 1))
        }
        return colours
    }()
}
