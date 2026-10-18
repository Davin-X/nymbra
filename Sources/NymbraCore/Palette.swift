import Foundation

/// A concrete set of terminal colours: the 16 ANSI colours, plus the few
/// interface colours a terminal needs.
///
/// This is data, and it deliberately lives in the UI-free core. Which colours a
/// preset defines, whether an override is applied, and whether the result is
/// readable are all things that should be asserted without opening a window —
/// so the tables live here and only the conversion to `CGColor` lives in the
/// app.
public struct Palette: Equatable, Sendable {

    /// One colour, 8 bits per channel.
    public struct RGB: Equatable, Hashable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `#rrggbb`, the form the config file uses.
        public init?(hex text: String) {
            guard text.count == 7, text.hasPrefix("#") else { return nil }
            let digits = text.dropFirst()
            guard digits.allSatisfy({ $0.isHexDigit }), let value = UInt32(digits, radix: 16) else {
                return nil
            }
            self.init(red: UInt8((value >> 16) & 0xFF),
                      green: UInt8((value >> 8) & 0xFF),
                      blue: UInt8(value & 0xFF))
        }

        public var hex: String {
            String(format: "#%02x%02x%02x", red, green, blue)
        }

        /// WCAG relative luminance, 0 for black and 1 for white.
        public var luminance: Double {
            func channel(_ value: UInt8) -> Double {
                let fraction = Double(value) / 255
                return fraction <= 0.03928
                    ? fraction / 12.92
                    : pow((fraction + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }

        /// WCAG contrast ratio, from 1 (identical) to 21 (black on white).
        /// Presets are checked against it, and the settings window warns when an
        /// override makes text unreadable.
        public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
            let brighter = max(a.luminance, b.luminance)
            let darker = min(a.luminance, b.luminance)
            return (brighter + 0.05) / (darker + 0.05)
        }
    }

    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    public var selection: RGB

    /// The 16 ANSI colours: normal first, then bright. Always exactly 16.
    public var ansi: [RGB]

    /// The names the config file uses for the 16 ANSI colours, in storage order.
    public static let ansiNames = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "bright-black", "bright-red", "bright-green", "bright-yellow",
        "bright-blue", "bright-magenta", "bright-cyan", "bright-white",
    ]

    /// The names the config file uses for the interface colours.
    public static let interfaceNames = ["foreground", "background", "cursor", "selection"]

    /// Every colour a user may override.
    public static let names: Set<String> = Set(ansiNames + interfaceNames)

    // MARK: - Building

    /// A preset, with the user's overrides applied. Overrides are already
    /// validated when the configuration loads; one that arrives unvalidated is
    /// ignored rather than fatal.
    public init(preset: Configuration.Colours.Preset, overrides: [String: String] = [:]) {
        switch preset {
        case .dark: self = .dark
        case .ember: self = .ember
        case .fern: self = .fern
        case .violet: self = .violet
        case .light: self = .light
        case .paper: self = .paper
        case .dawn: self = .dawn
        case .highContrast: self = .highContrast
        }
        for (name, hex) in overrides {
            guard let colour = RGB(hex: hex) else { continue }
            apply(colour, named: name)
        }
    }

    private init(foreground: RGB, background: RGB, cursor: RGB, selection: RGB, ansi: [RGB]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
    }

    private mutating func apply(_ colour: RGB, named name: String) {
        switch name {
        case "foreground": foreground = colour
        case "background": background = colour
        case "cursor": cursor = colour
        case "selection": selection = colour
        default:
            if let index = Palette.ansiNames.firstIndex(of: name) { ansi[index] = colour }
        }
    }

    // MARK: - Presets

    public static let dark = Palette(
        foreground: rgb(0xD9, 0xE6, 0xFF),
        background: rgb(0x0B, 0x0E, 0x18),
        cursor: rgb(0xD9, 0xE6, 0xFF),
        selection: rgb(0x2B, 0x3A, 0x5C),
        ansi: [
            // These are chosen for a dark background first and for history
            // second. The traditional xterm table puts blue at RGB(0,0,238),
            // which is 2:1 against a dark background — `ls` colours directories
            // that blue, so the traditional table hides exactly the thing the
            // user asked to see. Every colour here clears 4.5:1 (WCAG AA) on
            // `background`; `readable(_:on:)` keeps that promise for colours
            // programs choose for themselves.
            rgb(0x76, 0x7B, 0x86), rgb(0xE0, 0x5C, 0x5C), rgb(0x46, 0xBE, 0x5E), rgb(0xC0, 0xA0, 0x2E),
            rgb(0x6E, 0x8C, 0xF0), rgb(0xD4, 0x68, 0xD4), rgb(0x37, 0xBF, 0xBF), rgb(0xD8, 0xDE, 0xE9),
            rgb(0x98, 0xA2, 0xB3), rgb(0xFF, 0x6B, 0x6B), rgb(0x6B, 0xE0, 0x6B), rgb(0xE8, 0xD4, 0x4D),
            rgb(0x7C, 0x8C, 0xFF), rgb(0xF0, 0x8C, 0xF0), rgb(0x6B, 0xE0, 0xE0), rgb(0xFF, 0xFF, 0xFF),
        ]
    )

    /// Warm and dim: a dark page with an amber cast, for a room lit by a lamp
    /// rather than the sun. The hues are pulled toward orange, which is why green
    /// reads as olive — that is the point of the preset, not an accident.
    public static let ember = Palette(
        foreground: rgb(0xF5, 0xE7, 0xDA),
        background: rgb(0x19, 0x12, 0x10),
        cursor: rgb(0xF5, 0xE7, 0xDA),
        selection: rgb(0x29, 0x33, 0x48),
        ansi: [
            rgb(0x7E, 0x81, 0x87), rgb(0xCF, 0x5B, 0x4E), rgb(0x4C, 0x8F, 0x36), rgb(0x99, 0x7D, 0x3A),
            rgb(0x4D, 0x81, 0xC9), rgb(0xCF, 0x4E, 0xA4), rgb(0x35, 0x8C, 0x89), rgb(0xDF, 0xE3, 0xEB),
            rgb(0x7B, 0x81, 0x8F), rgb(0xE3, 0x89, 0x7F), rgb(0x6D, 0xA3, 0x5B), rgb(0xAD, 0x97, 0x61),
            rgb(0x7C, 0xA5, 0xDE), rgb(0xE3, 0x7F, 0xC2), rgb(0x5A, 0xA1, 0x9E), rgb(0xFA, 0xFC, 0xFF),
        ]
    )

    /// Green-leaning, for code that is mostly trees: a very dark green page with
    /// saturated greens and yellows and cooler everything else.
    public static let fern = Palette(
        foreground: rgb(0xDD, 0xF3, 0xE1),
        background: rgb(0x0B, 0x14, 0x0F),
        cursor: rgb(0xDD, 0xF3, 0xE1),
        selection: rgb(0x1A, 0x36, 0x42),
        ansi: [
            rgb(0x7E, 0x81, 0x87), rgb(0xDB, 0x4E, 0x46), rgb(0x2F, 0x91, 0x41), rgb(0x82, 0x85, 0x2A),
            rgb(0x3C, 0x85, 0xBA), rgb(0xD4, 0x44, 0xB0), rgb(0x2E, 0x8F, 0x7F), rgb(0xDF, 0xE3, 0xEB),
            rgb(0x79, 0x7F, 0x8C), rgb(0xF0, 0x7E, 0x78), rgb(0x53, 0xA6, 0x62), rgb(0x96, 0x99, 0x4C),
            rgb(0x67, 0xA4, 0xCF), rgb(0xE8, 0x74, 0xCB), rgb(0x52, 0xA3, 0x96), rgb(0xFA, 0xFC, 0xFF),
        ]
    )

    /// Purple-shifted: the dark preset with its blues pushed toward violet, which
    /// is the colour of most of the syntax highlighting this one will show.
    public static let violet = Palette(
        foreground: rgb(0xED, 0xE6, 0xFA),
        background: rgb(0x13, 0x0F, 0x1D),
        cursor: rgb(0xED, 0xE6, 0xFA),
        selection: rgb(0x3A, 0x26, 0x5E),
        ansi: [
            rgb(0x7B, 0x7E, 0x85), rgb(0xD6, 0x51, 0x68), rgb(0x36, 0x8F, 0x51), rgb(0x8C, 0x7E, 0x35),
            rgb(0x95, 0x5D, 0xF5), rgb(0xBD, 0x4E, 0xCF), rgb(0x40, 0x86, 0xA8), rgb(0xDF, 0xE3, 0xEB),
            rgb(0x79, 0x7F, 0x8C), rgb(0xEB, 0x7A, 0x8D), rgb(0x55, 0xA3, 0x6C), rgb(0xA1, 0x94, 0x54),
            rgb(0xB0, 0x83, 0xFC), rgb(0xD4, 0x76, 0xE3), rgb(0x62, 0x9F, 0xBD), rgb(0xFA, 0xFC, 0xFF),
        ]
    )

    public static let light = Palette(
        foreground: rgb(0x1C, 0x1C, 0x1E),
        background: rgb(0xFF, 0xFF, 0xFF),
        cursor: rgb(0x1C, 0x1C, 0x1E),
        selection: rgb(0xCF, 0xE1, 0xFF),
        ansi: [
            // Darkened from the usual values so that every one of them is still
            // readable against white, and the bright half is nudged *toward* the
            // background rather than away from it — on a white page "brighter"
            // and "fainter" point the same way.
            rgb(0x3C, 0x3C, 0x43), rgb(0xC0, 0x27, 0x1B), rgb(0x17, 0x74, 0x3A), rgb(0x8A, 0x61, 0x00),
            rgb(0x1B, 0x4E, 0xBF), rgb(0xA3, 0x22, 0x8F), rgb(0x0F, 0x6E, 0x77), rgb(0x5F, 0x5F, 0x66),
            rgb(0x6C, 0x6C, 0x70), rgb(0xD6, 0x3A, 0x28), rgb(0x18, 0x7F, 0x3F), rgb(0x9A, 0x6D, 0x00),
            rgb(0x2A, 0x66, 0xE8), rgb(0xB8, 0x36, 0xA4), rgb(0x11, 0x75, 0x7E), rgb(0x1C, 0x1C, 0x1E),
        ]
    )

    /// A warm page rather than a white one, with the hues leaned toward amber.
    /// For the same room `ember` is for, at noon.
    public static let paper = Palette(
        foreground: rgb(0x24, 0x24, 0x2A),
        background: rgb(0xFA, 0xF8, 0xF3),
        cursor: rgb(0x24, 0x24, 0x2A),
        selection: rgb(0xC1, 0xCD, 0xEA),
        ansi: [
            rgb(0x24, 0x25, 0x26), rgb(0xBF, 0x48, 0x36), rgb(0x24, 0x80, 0x36), rgb(0x82, 0x6F, 0x24),
            rgb(0x3C, 0x6A, 0xD6), rgb(0xB8, 0x33, 0xB8), rgb(0x25, 0x7B, 0x85), rgb(0x57, 0x59, 0x5C),
            rgb(0x49, 0x4C, 0x52), rgb(0xAD, 0x56, 0x49), rgb(0x2F, 0x70, 0x3C), rgb(0x73, 0x65, 0x30),
            rgb(0x4D, 0x6D, 0xB8), rgb(0xA6, 0x46, 0xA6), rgb(0x31, 0x6E, 0x75), rgb(0x1D, 0x1D, 0x1F),
        ]
    )

    /// A warm off-white page, easier on the eyes than pure white in a bright
    /// room, and the light counterpart of `ember`.
    public static let dawn = Palette(
        foreground: rgb(0x2A, 0x21, 0x17),
        background: rgb(0xFD, 0xF4, 0xE8),
        cursor: rgb(0x2A, 0x21, 0x17),
        selection: rgb(0xC4, 0xCC, 0xD7),
        ansi: [
            rgb(0x24, 0x25, 0x26), rgb(0xAD, 0x53, 0x3D), rgb(0x2E, 0x7D, 0x2C), rgb(0x87, 0x6A, 0x2F),
            rgb(0x3E, 0x6F, 0xB0), rgb(0xB8, 0x40, 0x8C), rgb(0x2D, 0x77, 0x80), rgb(0x55, 0x56, 0x59),
            rgb(0x49, 0x4C, 0x52), rgb(0x9E, 0x59, 0x47), rgb(0x33, 0x6E, 0x31), rgb(0x78, 0x62, 0x36),
            rgb(0x47, 0x6D, 0x9E), rgb(0xA6, 0x4B, 0x84), rgb(0x32, 0x6A, 0x70), rgb(0x1D, 0x1D, 0x1F),
        ]
    )

    /// For low vision, and for people who work in bad light. Maximum contrast on
    /// the interface colours, and ANSI colours light enough to stay readable
    /// rather than being toned down.
    public static let highContrast = Palette(
        foreground: rgb(0xFF, 0xFF, 0xFF),
        background: rgb(0x00, 0x00, 0x00),
        cursor: rgb(0xFF, 0xFF, 0xFF),
        selection: rgb(0x00, 0x52, 0x7F),
        ansi: [
            rgb(0x80, 0x80, 0x80), rgb(0xFF, 0x6B, 0x6B), rgb(0x6B, 0xFF, 0x6B), rgb(0xFF, 0xFF, 0x6B),
            rgb(0x6B, 0x9B, 0xFF), rgb(0xFF, 0x6B, 0xFF), rgb(0x6B, 0xFF, 0xFF), rgb(0xFF, 0xFF, 0xFF),
            rgb(0x8A, 0x8A, 0x8A), rgb(0xFF, 0x9B, 0x9B), rgb(0x9B, 0xFF, 0x9B), rgb(0xFF, 0xFF, 0x9B),
            rgb(0x9B, 0xBB, 0xFF), rgb(0xFF, 0x9B, 0xFF), rgb(0x9B, 0xFF, 0xFF), rgb(0xFF, 0xFF, 0xFF),
        ]
    )

    // MARK: - Named access

    /// The colour a name from `names` refers to, or `nil` for a name this
    /// palette does not have. The settings window shows one well per name, so
    /// the vocabulary is shared rather than re-listed there.
    public func colour(named name: String) -> RGB? {
        switch name {
        case "foreground": return foreground
        case "background": return background
        case "cursor": return cursor
        case "selection": return selection
        default:
            guard let index = Palette.ansiNames.firstIndex(of: name) else { return nil }
            return ansi[index]
        }
    }

    // MARK: - Readability

    /// The nearest colour to `colour` that can actually be read on
    /// `background`, at `minimum` contrast — the colour itself when it already
    /// can be.
    ///
    /// A preset can be checked once, but a *program* picks colours at runtime:
    /// `LS_COLORS`, `git`, and every TUI in between send whatever they like, and
    /// a true colour chosen against a white page is invisible on a dark one. A
    /// terminal that faithfully draws an invisible colour has answered the
    /// question "what colour did the program ask for?" and not the question the
    /// person asked, which is "what does it say?". So the foreground is nudged
    /// away from the background until it clears the bar, and no further.
    ///
    /// Both directions are tried and the smaller change wins: against a mid grey
    /// either direction can clear the bar, and the colour that moves least is the
    /// one closest to what was asked for. (At least one direction always
    /// succeeds: the contrast ratios of white and black against any background
    /// multiply to 21, so if one is below 4.5 the other is above it.)
    public static func readable(_ colour: RGB, on background: RGB, minimum: Double = 4.5) -> RGB {
        if RGB.contrastRatio(colour, background) >= minimum { return colour }

        let white = RGB(red: 255, green: 255, blue: 255)
        let black = RGB(red: 0, green: 0, blue: 0)

        var best = colour
        var bestAmount = 1.0
        var found = false
        for target in [white, black] {
            let steps = 64
            for step in 1...steps {
                let amount = Double(step) / Double(steps)
                let mixed = blend(colour, with: target, amount: amount)
                if RGB.contrastRatio(mixed, background) >= minimum {
                    // Ties go to the first direction tried, so the result is
                    // stable rather than dependent on floating-point dust.
                    if !found || amount < bestAmount {
                        best = mixed
                        bestAmount = amount
                        found = true
                    }
                    break
                }
            }
        }
        return best
    }

    /// `amount` of `other` mixed into `colour`; 0 leaves it alone, 1 replaces it.
    /// Used to dim faint text toward what is behind it, and by `readable`.
    public static func blend(_ colour: RGB, with other: RGB, amount: Double) -> RGB {
        func mix(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8((Double(x) + (Double(y) - Double(x)) * amount).rounded())
        }
        return RGB(red: mix(colour.red, other.red),
                   green: mix(colour.green, other.green),
                   blue: mix(colour.blue, other.blue))
    }

    /// The highlight a find match is drawn in for this palette: a yellow block and
    /// the ink to draw its text in.
    ///
    /// Both are derived from the palette's ANSI yellow and its own background. The
    /// block is the yellow held back toward the background by `amount` (0.35 for
    /// an ordinary match, 0.20 for the match the person is on). The ink is the
    /// palette's own text colour held to 3:1 against that block — 3:1 is the
    /// graphics bar, and it is the one that keeps every preset's highlight legible
    /// rather than nudging the ink to black when the block is bright and the
    /// foreground is light (as happens at 4.5:1 on light presets).
    ///
    /// The amounts are chosen so the two blocks are visibly different in all eight
    /// presets (their luminance differs by ≥ 0.04), and neither block is the same
    /// as the background (ratio ≥ 2.5:1) or the same as the foreground
    /// (ratio ≥ 2:1). `PaletteSuite` asserts this for all presets.
    public func findHighlight(amount: Double) -> (block: RGB, ink: RGB) {
        let block = Self.blend(ansi[3], with: background, amount: amount)
        let ink = Self.readable(foreground, on: block, minimum: 3)
        return (block, ink)
    }

    // MARK: - Resolving

    /// The colour an SGR colour refers to, or `nil` for "the default", which
    /// lets a run with no background skip its rectangle entirely.
    public func resolve(_ colour: Colour) -> RGB? {
        switch colour {
        case .default: return nil
        case .indexed(let index): return indexed(Int(index))
        case .rgb(let r, let g, let b): return RGB(red: r, green: g, blue: b)
        }
    }

    /// The xterm 256-colour table: the 16 configured colours, then a 6×6×6 cube,
    /// then a 24-step greyscale ramp.
    public func indexed(_ index: Int) -> RGB {
        if index < 16 { return ansi[index] }
        if index < 232 {
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let cube = index - 16
            return RGB(red: levels[cube / 36], green: levels[(cube / 6) % 6], blue: levels[cube % 6])
        }
        let step = min(max(index - 232, 0), 23)
        let value = UInt8(8 + step * 10)
        return RGB(red: value, green: value, blue: value)
    }

    // MARK: - Helpers

    private static func rgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> RGB {
        RGB(red: red, green: green, blue: blue)
    }
}
