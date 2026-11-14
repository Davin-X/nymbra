import AppKit
import CoreText
import Foundation
import NymbraCore
import NymbraInput

// MARK: - Preview

/// A live sample of the terminal: the chosen font, at the chosen size, in the
/// chosen colours — and, because the gallery above it offers a choice, the
/// chosen **prompt style**.
///
/// It draws with the same `Theme` and palette the real view uses, so what it
/// shows is what the terminal will do rather than a drawing of an idea of it. The
/// prompt is the exception, and deliberately: a shell owns its own prompt, so the
/// style is a preview of how a prompt looks, which is what the note beside the
/// gallery says.
final class PreviewView: NSView {
    var configuration = Configuration() {
        didSet {
            theme = Theme(configuration)
            font = Fonts.resolve(configuration)
            boldFont = Fonts.bold(font)
            // The prompt may have grown a line, and the text may have grown with
            // the font, so the view has to be allowed to ask for a new height.
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The identity the sample prompt shows. One place, so a gallery card and the
    /// preview cannot describe two different prompts.
    static let sampleUser = NSUserName()
    static let sampleHost = ProcessInfo.processInfo.hostName
        .split(separator: ".").first.map(String.init) ?? "localhost"
    static let samplePath = "~/src/nymbra"
    static let sampleBranch = "main"

    /// The prompt a style draws in a palette. The gallery cards call this too, so
    /// a card cannot show one prompt while the preview shows another.
    static func promptLines(_ style: PromptStyle, palette: Palette) -> [[PromptRun]] {
        style.lines(user: sampleUser, host: sampleHost, path: samplePath,
                    branch: sampleBranch, palette: palette)
    }

    private var theme = Theme(Configuration())
    private var font = Fonts.resolve(Configuration())
    private var boldFont = Fonts.bold(Fonts.resolve(Configuration()))

    /// The prompt the preview is drawing right now, line by line.
    var promptText: [String] { promptRuns.map { $0.map(\.text).joined() } }

    private var promptStyle: PromptStyle {
        PromptStyle(stored: configuration.appearance.promptStyle)
    }

    private var promptRuns: [[PromptRun]] {
        Self.promptLines(promptStyle, palette: theme.palette)
    }

    private func read(_ run: PromptRun) -> (String, Attributes) {
        var attributes = Attributes()
        attributes.foreground = .rgb(r: run.ink.red, g: run.ink.green, b: run.ink.blue)
        if let paper = run.paper {
            attributes.background = .rgb(r: paper.red, g: paper.green, b: paper.blue)
        }
        attributes.bold = run.bold
        return (run.text, attributes)
    }

    /// The document under the prompt. Fixed, because it is there to show the
    /// palette and the font: a document that moved with the prompt would make two
    /// things change at once, and the prompt is the thing being chosen.
    private var document: [[(String, Attributes)]] {
        [
            [("On branch ", sample()), ("main", sample(.indexed(2), bold: true))],
            [("  modified:   ", sample()), ("Sources/Nymbra/SettingsWindow.swift", sample(.indexed(3)))],
            [("warning: ", sample(.indexed(1), bold: true)),
             ("1 file changed, 日本語 ok", sample(.indexed(1)))],
            [("README.md ", sample(.indexed(6), underline: .single)),
             ("docs/ ", sample(.indexed(4))),
             ("highlighted", sample(.default, background: .indexed(3)))],
            [("bold ", sample(bold: true)), ("faint ", sample(faint: true)),
             ("reverse ", sample(reverse: true))]
        ]
    }

    /// Every line the preview draws: the prompt, the document, then the cursor's
    /// own line.
    private var lines: [[(String, Attributes)]] {
        promptRuns.map { $0.map(read) } + document
    }

    private var lineHeight: CGFloat { (configuration.appearance.fontSize * 1.5).rounded() }
    private static let inset: CGFloat = 12

    /// The preview is exactly as tall as what it draws. A fixed height clipped the
    /// document once the font grew, and would have cropped the second line of a
    /// two-line prompt.
    override var intrinsicContentSize: NSSize {
        let height = Self.inset * 2 + CGFloat(lines.count + 1) * lineHeight
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // swiftlint:disable:next function_body_length
    // The preview draws a small document; the limit is for logic, not for this.
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(theme.background)
        ctx.fill(bounds)

        let inset = Self.inset
        let descent = CTFontGetDescent(font)
        let samples = lines

        for (index, runs) in samples.enumerated() {
            let baseline = bounds.height - inset - CGFloat(index + 1) * lineHeight + descent
            var x = inset
            for (text, attributes) in runs {
                let (foreground, background) = theme.resolve(attributes, reversed: false)
                let runFont = attributes.bold ? boldFont : self.font
                let attributed = NSAttributedString(string: text, attributes: [
                    .init(kCTFontAttributeName as String): runFont,
                    .init(kCTForegroundColorAttributeName as String): foreground,
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

                if let background {
                    ctx.setFillColor(background)
                    ctx.fill(CGRect(x: x, y: bounds.height - inset - CGFloat(index + 1) * lineHeight,
                                    width: width, height: lineHeight))
                }
                if attributes.underline != .none {
                    ctx.setFillColor(foreground)
                    ctx.fill(CGRect(x: x, y: bounds.height - inset - CGFloat(index + 1) * lineHeight + 1,
                                    width: width, height: 1))
                }

                ctx.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, ctx)
                x += width
            }
        }

        // The cursor, so its colour is part of the preview too.
        let cursorWidth = Fonts.advanceWidth(of: font)
        ctx.setFillColor(theme.cursor)
        ctx.fill(CGRect(x: inset,
                        y: bounds.height - inset - CGFloat(samples.count + 1) * lineHeight,
                        width: cursorWidth,
                        height: lineHeight))
    }

    private func sample(_ colour: Colour = .default,
                        bold: Bool = false,
                        faint: Bool = false,
                        reverse: Bool = false,
                        underline: UnderlineStyle = .none,
                        background: Colour = .default) -> Attributes {
        var attributes = Attributes()
        attributes.foreground = colour
        attributes.background = background
        attributes.bold = bold
        attributes.faint = faint
        attributes.inverse = reverse
        attributes.underline = underline
        return attributes
    }
}
