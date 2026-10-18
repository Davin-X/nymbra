import AppKit
import NymbraCore

/// The colour scheme in use, built from the user's configuration.
///
/// The tables live in `NymbraCore/Palette.swift`, where presets, overrides and
/// readability are asserted without a window. This type is only the conversion
/// to `CGColor` plus the rule for how SGR attributes become cell colours — which
/// is exactly the part that needs a graphics context to be meaningful.
struct Theme {
    let palette: Palette

    init(_ configuration: Configuration) {
        palette = Palette(preset: configuration.colours.preset,
                          overrides: configuration.colours.overrides)
    }

    var background: CGColor { Self.colour(palette.background) }
    var foreground: CGColor { Self.colour(palette.foreground) }
    var cursor: CGColor { Self.colour(palette.cursor) }
    var selection: CGColor { Self.colour(palette.selection) }

    /// A find highlight: the block drawn behind a matched run, and the ink the
    /// matched text is redrawn in on top of it.
    struct Highlight {
        let fill: CGColor
        let ink: CGColor
    }

    /// How an ordinary match is drawn, and how the match the person is on is drawn.
    ///
    /// The block is the theme's yellow held back toward that theme's own background:
    /// a solid colour rather than a wash, because a wash takes contrast away from the
    /// text and gives back a tint. Both are the same yellow at two strengths, and the
    /// match the count is talking about is the stronger one — `TermView` also rings
    /// it, so telling them apart is a shape as well as a shade.
    ///
    /// The ink is the theme's own text colour, held to 3:1 against that block rather
    /// than to the 4.5:1 the palette promises for body text. A find highlight is
    /// chrome: the text under it is redrawn on the block, which is a background the
    /// theme never chose, and holding a bright block to 4.5:1 answers by inking it
    /// black — correct for an article, and wrong for the one lit thing on the screen.
    /// 3:1 is the bar for graphics, and it is enough that no preset and no override
    /// can produce a highlight that cannot be read.
    var findMatch: Highlight { highlight(0.35) }
    var findCurrent: Highlight { highlight(0.20) }

    private func highlight(_ amount: Double) -> Highlight {
        let (block, ink) = palette.findHighlight(amount: amount)
        return Highlight(fill: Self.colour(block), ink: Self.colour(ink))
    }

    /// The line between panes: the background nudged toward the foreground, so it
    /// reads as a seam in every preset — including the light ones, where a fixed
    /// grey would read as a border — and never competes with the text.
    var divider: CGColor {
        Self.colour(Palette.blend(palette.background, with: palette.foreground, amount: 0.18))
    }

    /// Resolve a pair of attributes to concrete colours. `nil` means "the
    /// default background", which lets a run with no background skip its
    /// rectangle entirely.
    ///
    /// Everything happens in `Palette.RGB` and is converted once at the end, so
    /// the readability rule is a property of the core's colour type rather than
    /// of a graphics context.
    func resolve(_ attributes: Attributes, reversed: Bool) -> (CGColor, CGColor?) {
        var foreground = attributes.foreground
        var background = attributes.background
        if attributes.inverse != reversed { swap(&foreground, &background) }
        if attributes.conceal { foreground = background }

        var ink = palette.resolve(foreground) ?? palette.foreground
        let paper = palette.resolve(background)
        if attributes.faint {
            // SGR 2: the text is mixed halfway toward whatever is behind it.
            ink = Palette.blend(ink, with: paper ?? palette.background, amount: 0.5)
        }

        // Nothing a program can ask for is allowed to be invisible. `conceal`
        // and `faint` are the two exceptions, because hiding the text and dimming
        // it are exactly what those codes are *for*.
        if !attributes.conceal, !attributes.faint {
            ink = Palette.readable(ink, on: paper ?? palette.background)
        }
        return (Self.colour(ink), paper.map(Self.colour))
    }

    private static func colour(_ rgb: Palette.RGB) -> CGColor {
        CGColor(red: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1)
    }
}
