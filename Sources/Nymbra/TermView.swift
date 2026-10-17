import AppKit
import CoreText
import NymbraCore

/// Draws the screen buffer onto a character grid, one CoreText line per row.
///
/// Cell metrics come from CoreText rather than being guessed, so every glyph
/// lands exactly on the grid. This is the piece Metal will replace later; the
/// grid maths is what carries over.
final class TermView: NSView {
    let buffer: TermBuffer
    var onInput: (([UInt8]) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    private let font: CTFont
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat
    private let ascent: CGFloat
    private let descent: CGFloat
    private let paddingX: CGFloat = 10
    private let paddingY: CGFloat = 8

    private(set) var cols: Int
    private(set) var rows: Int

    init(frame: NSRect, buffer: TermBuffer) {
        self.buffer = buffer
        let f = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        self.font = f
        self.ascent = CTFontGetAscent(f)
        self.descent = CTFontGetDescent(f)
        self.cellHeight = (ascent + descent + CTFontGetLeading(f)).rounded()

        var character: UniChar = 0x4D  // 'M'
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(f, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(f, .horizontal, &glyph, &advance, 1)
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(CGColor(red: 0.043, green: 0.055, blue: 0.094, alpha: 1))
        ctx.fill(bounds)

        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.85, green: 0.90, blue: 1.0, alpha: 1),
        ]

        for (row, bytes) in buffer.visible(rows).enumerated() where !bytes.isEmpty {
            let string = TermBuffer.decode(bytes)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: string, attributes: attributes)
            )
            let baseline = bounds.height - paddingY - CGFloat(row + 1) * cellHeight + descent
            ctx.textPosition = CGPoint(x: paddingX, y: baseline)
            CTLineDraw(line, ctx)
        }
    }

    override func keyDown(with event: NSEvent) {
        var out: [UInt8] = []
        switch event.keyCode {
        case 36, 76:  out = [0x0D]                     // return / keypad enter
        case 51, 117: out = [0x7F]                     // delete
        case 126:     out = [0x1B, 0x5B, 0x41]         // up
        case 125:     out = [0x1B, 0x5B, 0x42]         // down
        case 124:     out = [0x1B, 0x5B, 0x43]         // right
        case 123:     out = [0x1B, 0x5B, 0x44]         // left
        default:
            if let characters = event.charactersIgnoringModifiers { out = Array(characters.utf8) }
        }
        if !out.isEmpty { onInput?(out) }
    }
}
