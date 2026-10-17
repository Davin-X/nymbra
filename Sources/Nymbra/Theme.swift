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
