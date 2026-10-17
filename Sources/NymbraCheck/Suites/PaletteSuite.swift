import Foundation
import NymbraCore

/// The colour tables, asserted without a window.
///
/// This is why the palette lives in the UI-free core: "is the foreground
/// readable on the background" and "does an override touch only the colour it
/// names" are questions a test can answer, and a screenshot cannot.
func paletteSuite(_ h: Harness) {
    h.suite("palette")

    let presets: [Configuration.Colours.Preset] = [.dark, .light, .highContrast]

    // MARK: Structure

    for preset in presets {
        let palette = Palette(preset: preset)
        h.equal(palette.ansi.count, 16, "\(preset) defines all 16 ANSI colours")
    }

    let dark = Palette(preset: .dark)
    let light = Palette(preset: .light)
    let highContrast = Palette(preset: .highContrast)

    h.expect(dark.background != light.background, "the dark and light presets differ")
    h.expect(dark.background != highContrast.background, "dark and high contrast differ")
    h.expect(light.foreground != highContrast.foreground, "light and high contrast differ")
    h.expect(dark.ansi != light.ansi, "the ANSI colours are not simply shared between presets")

    // MARK: Readability
    //
    // The promise a preset makes is that text can be read on it. WCAG AA puts
    // that at 4.5:1, and it is worth holding presets to a number rather than to
    // taste.

    for preset in presets {
        let palette = Palette(preset: preset)
        let ratio = Palette.RGB.contrastRatio(palette.foreground, palette.background)
        h.expect(ratio >= 4.5,
                 "\(preset) foreground is readable on its background (\(rounded(ratio)):1)")
        h.expect(Palette.RGB.contrastRatio(palette.cursor, palette.background) >= 4.5,
                 "\(preset) cursor is visible against its background")
    }

    // Every ANSI colour has to be readable on its own background, not merely
    // present. This is not taste: `ls` prints directories in colour 4, so a dim
    // blue is a bug report about "hidden" filenames rather than an aesthetic
    // choice. The old table shipped #0000ee — 2:1 on the dark background — and
    // that is exactly what happened.
    for preset in presets {
        let palette = Palette(preset: preset)
        for (index, colour) in palette.ansi.enumerated() {
            let ratio = Palette.RGB.contrastRatio(colour, palette.background)
            h.expect(ratio >= 4.5,
                     "\(preset) ANSI colour \(index) is readable on its background (\(rounded(ratio)):1)")
        }
    }

    // The specific regression: colour 4 on the *dark* background, which is what
    // `ls` colours a directory with.
    h.expect(Palette.RGB.contrastRatio(dark.ansi[4], dark.background) >= 4.5,
             "a directory is legible on the dark preset")

    // MARK: Readability, for colours a program chooses for itself

    let navy = Palette.RGB(red: 0x0B, green: 0x0E, blue: 0x18)
    let page = Palette.RGB(red: 0xFF, green: 0xFF, blue: 0xFF)

    h.equal(Palette.readable(dark.foreground, on: navy), dark.foreground,
            "a colour that is already readable is left exactly alone")
    h.equal(Palette.readable(Palette.RGB(red: 0, green: 0, blue: 0), on: page),
            Palette.RGB(red: 0, green: 0, blue: 0),
            "black on white is left alone")

    // The reported bug, at its root: the traditional xterm blue.
    let traditionalBlue = Palette.RGB(red: 0x00, green: 0x00, blue: 0xEE)
    h.expect(Palette.RGB.contrastRatio(traditionalBlue, navy) < 4.5,
             "the traditional blue really is unreadable on the dark background")
    let rescued = Palette.readable(traditionalBlue, on: navy)
    h.expect(Palette.RGB.contrastRatio(rescued, navy) >= 4.5,
             "an unreadable blue is lifted until it can be read (\(rounded(Palette.RGB.contrastRatio(rescued, navy))):1)")
    h.expect(rescued.blue > rescued.red && rescued.blue > rescued.green,
             "the lifted colour is still blue")

    h.expect(Palette.RGB.contrastRatio(Palette.readable(dark.ansi[4], on: page), page) >= 4.5,
             "a dark blue is darkened further when the background is white")

    // Nothing readable is ever darkened past the bar, and the rule is stable.
    for preset in presets {
        let palette = Palette(preset: preset)
        for colour in palette.ansi + [palette.foreground] {
            let fixed = Palette.readable(colour, on: palette.background)
            h.expect(Palette.RGB.contrastRatio(fixed, palette.background) >= 4.5,
                     "\(preset) every colour comes out readable after the rule")
            h.equal(Palette.readable(fixed, on: palette.background), fixed,
                    "\(preset) the rule is idempotent")
        }
    }

    // A mid-grey background can be escaped in either direction, and the smaller
    // change is the one taken.
    let grey = Palette.RGB(red: 0x80, green: 0x80, blue: 0x80)
    let escapee = Palette.readable(Palette.RGB(red: 0x66, green: 0x66, blue: 0x66), on: grey)
    h.expect(Palette.RGB.contrastRatio(escapee, grey) >= 4.5,
             "a colour close to a mid-grey background is moved until it can be read")
    h.expect(escapee.red < 0x66, "and it moves toward black, the shorter trip from 0x66")

    h.equal(Palette.blend(navy, with: page, amount: 0), navy, "blending by nothing changes nothing")
    h.equal(Palette.blend(navy, with: page, amount: 1), page, "blending by everything replaces")
    h.equal(Palette.blend(Palette.RGB(red: 0, green: 0, blue: 0),
                          with: Palette.RGB(red: 255, green: 255, blue: 255),
                          amount: 0.5),
            Palette.RGB(red: 128, green: 128, blue: 128),
            "halfway between black and white is the middle grey")

    // MARK: Luminance and contrast arithmetic

    let black = Palette.RGB(red: 0, green: 0, blue: 0)
    let white = Palette.RGB(red: 255, green: 255, blue: 255)
    h.expect(abs(black.luminance) < 0.0001, "black has no luminance")
    h.expect(abs(white.luminance - 1) < 0.0001, "white has full luminance")
    h.expect(abs(Palette.RGB.contrastRatio(black, white) - 21) < 0.01, "black on white is 21:1")
    h.expect(abs(Palette.RGB.contrastRatio(white, black) - 21) < 0.01, "contrast does not depend on order")
    h.expect(abs(Palette.RGB.contrastRatio(white, white) - 1) < 0.0001, "a colour on itself is 1:1")

    // MARK: Hex

    h.equal(Palette.RGB(red: 0x1F, green: 0x24, blue: 0x30).hex, "#1f2430", "a colour prints as #rrggbb")
    h.equal(Palette.RGB(hex: "#1f2430"), Palette.RGB(red: 0x1F, green: 0x24, blue: 0x30), "hex parses back")
    h.equal(Palette.RGB(hex: dark.foreground.hex), dark.foreground, "every preset colour round-trips through hex")
    h.equal(Palette.RGB(hex: "#FFF"), nil, "a three-digit hex is not a colour")
    h.equal(Palette.RGB(hex: "1f2430"), nil, "a hex without # is not a colour")
    h.equal(Palette.RGB(hex: "#gggggg"), nil, "a non-hex digit is not a colour")
    h.equal(Palette.RGB(hex: ""), nil, "an empty string is not a colour")

    // MARK: Overrides

    let overridden = Palette(preset: .dark, overrides: ["red": "#ff0000"])
    h.equal(overridden.ansi[1], Palette.RGB(red: 0xFF, green: 0, blue: 0), "an override replaces its colour")
    h.equal(overridden.ansi[0], dark.ansi[0], "an override leaves other colours alone")
    h.equal(overridden.background, dark.background, "an override leaves the background alone")
    h.equal(overridden.ansi.count, 16, "an override does not change the number of colours")

    let backgroundOverride = Palette(preset: .dark, overrides: ["background": "#123456"])
    h.equal(backgroundOverride.background, Palette.RGB(red: 0x12, green: 0x34, blue: 0x56),
            "an interface colour can be overridden too")
    h.equal(backgroundOverride.ansi, dark.ansi, "overriding the background leaves the ANSI colours alone")

    let nonsense = Palette(preset: .dark,
                           overrides: ["chartreuse": "#00ff00", "blue": "not a colour"])
    h.equal(nonsense, dark, "an override that is not usable changes nothing")

    // MARK: The 256-colour table

    h.equal(dark.indexed(0), dark.ansi[0], "the first 16 indexed colours are the configured ones")
    h.equal(dark.indexed(15), dark.ansi[15], "index 15 is the last configured colour")
    h.equal(dark.indexed(16), Palette.RGB(red: 0, green: 0, blue: 0), "the cube starts at black")
    h.equal(dark.indexed(196), Palette.RGB(red: 255, green: 0, blue: 0), "the cube reaches pure red")
    h.equal(dark.indexed(231), Palette.RGB(red: 255, green: 255, blue: 255), "the cube ends at white")
    h.equal(dark.indexed(232), Palette.RGB(red: 8, green: 8, blue: 8), "the grey ramp starts at 8")
    h.equal(dark.indexed(255), Palette.RGB(red: 238, green: 238, blue: 238), "the grey ramp ends at 238")

    // MARK: Resolving SGR colours

    h.equal(dark.resolve(.default), nil, "the default colour is the background, not a colour")
    h.equal(dark.resolve(.indexed(1)), dark.ansi[1], "an indexed colour resolves through the palette")
    h.equal(dark.resolve(.rgb(r: 1, g: 2, b: 3)), Palette.RGB(red: 1, green: 2, blue: 3),
            "a true colour resolves as itself")

    // MARK: The palette in configuration's vocabulary

    h.expect(Palette.names.contains("foreground"), "the interface colours are overridable")
    h.expect(Palette.names.contains("bright-cyan"), "the ANSI colours are overridable")
    h.equal(Palette.names.count, 20, "there are twenty colours a user can override")
    h.equal(Set(Palette.ansiNames).count, 16, "no ANSI colour name is repeated")

    // Drift is the risk when two lists describe one vocabulary, so check the
    // names the config file validates against are the names drawing understands.
    h.equal(Configuration.Colours.names, Palette.names,
            "validation and drawing agree on the colour vocabulary")
}

private func rounded(_ value: Double) -> String {
    String(format: "%.2f", value)
}
