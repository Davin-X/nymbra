import Foundation
import NymbraCore

/// The prompt gallery, asserted without a window.
///
/// The gallery is a control, and a control that changes nothing is worse than no
/// control at all — so the questions here are the ones a screenshot cannot
/// answer: does every style draw something, does every style draw something
/// *different*, and is what it draws readable in every preset a person can pick.
func promptStyleSuite(_ h: Harness) {
    h.suite("promptStyle")

    let user = "devendra"
    let host = "nmb"
    let path = "~/src/nymbra"
    let branch = "main"

    func lines(_ style: PromptStyle, _ palette: Palette = Palette(preset: .dark)) -> [[PromptRun]] {
        style.lines(user: user, host: host, path: path, branch: branch, palette: palette)
    }

    func text(_ style: PromptStyle) -> String {
        lines(style).map { $0.map(\.text).joined() }.joined(separator: "\n")
    }

    // MARK: The list itself

    h.equal(PromptStyle.allCases.count, 8, "the gallery offers every style")
    h.equal(Set(PromptStyle.allCases.map(\.rawValue)).count, 8, "the stored names are unique")
    h.equal(Set(PromptStyle.allCases.map(\.title)).count, 8, "the card titles are unique")
    h.equal(Set(PromptStyle.allCases.map(\.summary)).count, 8, "the card summaries are unique")

    for style in PromptStyle.allCases {
        h.expect(!style.title.isEmpty, "\(style.rawValue) has a title")
        h.expect(!style.summary.isEmpty, "\(style.rawValue) has a summary")
        h.equal(PromptStyle(stored: style.rawValue), style, "\(style.rawValue) survives a round trip")
    }

    // A name we do not know is the default, not a preview of nothing: a config
    // file edited by hand into nonsense must not blank the preview.
    h.equal(PromptStyle(stored: "no-such-prompt"), PromptStyle.fallback, "an unknown name falls back")
    h.equal(PromptStyle(stored: ""), PromptStyle.fallback, "an empty name falls back")

    // MARK: Every style draws something

    for style in PromptStyle.allCases {
        let drawn = lines(style)
        h.expect(!drawn.isEmpty, "\(style.rawValue) draws at least one line")
        for (index, line) in drawn.enumerated() {
            h.expect(!line.isEmpty, "\(style.rawValue) line \(index) has runs")
            h.expect(line.allSatisfy { !$0.text.isEmpty },
                     "\(style.rawValue) line \(index) has no empty run")
            h.expect(line.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty },
                     "\(style.rawValue) line \(index) is not blank")
        }
    }

    // MARK: Every style looks unlike every other one
    //
    // The gallery's whole promise. Two styles that drew the same thing would be
    // two buttons that do the same nothing.

    let drawnTexts = PromptStyle.allCases.map(text)
    h.equal(Set(drawnTexts).count, PromptStyle.allCases.count, "every style draws something different")

    // MARK: Shapes worth naming

    h.expect(text(.git).contains(user), "git names the user")
    h.expect(text(.git).contains("git:(\(branch))"), "git names the branch")
    h.expect(text(.git).hasSuffix("$"), "git ends on a shell symbol")

    h.expect(!text(.robbyrussell).contains(user), "robbyrussell drops the user")
    h.expect(text(.robbyrussell).hasSuffix("➜"), "robbyrussell ends on its arrow")

    h.expect(!text(.pure).contains(user), "pure drops the user")
    h.expect(text(.pure).contains(branch), "pure still names the branch")
    h.expect(text(.pure).hasSuffix("❯"), "pure ends on its glyph")

    h.expect(text(.starship).contains("▸ \(path)"), "starship marks the path")
    h.expect(text(.starship).hasSuffix("❯"), "starship ends on its glyph")

    h.expect(text(.spaceship).hasPrefix("in "), "spaceship leads with its connective")
    h.expect(!text(.spaceship).contains(user), "spaceship drops the user")

    h.equal(lines(.kali).count, 2, "kali is a two-line prompt")
    h.expect(text(.kali).contains("┌──(\(user)@\(host))-[\(path)]"), "kali draws the classic frame")
    h.expect(text(.kali).hasSuffix("└─$ "), "kali ends on its second line")

    h.equal(lines(.powerlevel10k).count, 1, "powerlevel10k is a single line")

    // MARK: Blocks
    //
    // Two of the styles are Powerline-shaped: the pieces are filled blocks rather
    // than coloured text. That is the difference a person sees at a glance.

    for style in [PromptStyle.agnoster, PromptStyle.powerlevel10k] {
        h.expect(lines(style).flatMap { $0 }.contains { $0.paper != nil },
                 "\(style.rawValue) fills blocks")
    }
    for style in [PromptStyle.git, PromptStyle.robbyrussell, PromptStyle.pure,
                  PromptStyle.starship, PromptStyle.spaceship, PromptStyle.kali] {
        h.expect(lines(style).flatMap { $0 }.allSatisfy { $0.paper == nil },
                 "\(style.rawValue) draws plain text, not blocks")
    }

    // MARK: Readability, in every preset
    //
    // The preview is drawn with a real palette, so the promise the palettes make —
    // text can be read on its background — has to hold for the prompt too, in
    // every theme a person can choose and on both the text and the blocks.

    for preset in Configuration.Colours.Preset.allCases {
        let palette = Palette(preset: preset)
        for style in PromptStyle.allCases {
            for run in style.lines(user: user, host: host, path: path, branch: branch, palette: palette)
                .flatMap({ $0 }) {
                let behind = run.paper ?? palette.background
                let ratio = Palette.RGB.contrastRatio(run.ink, behind)
                h.expect(ratio >= 4.5,
                         "\(preset) \(style.rawValue) \"\(run.text)\" is readable "
                             + "(\(String(format: "%.2f", ratio)):1)")
            }
        }
    }

    // MARK: Overrides reach the prompt

    // The palette a person actually has is a preset plus overrides, and the
    // preview has to follow the override rather than the preset it replaces.
    let overridden = Palette(preset: .dark, overrides: ["blue": "#ff00ff"])
    let plain = Palette(preset: .dark)
    let plainInk = PromptStyle.spaceship
        .lines(user: user, host: host, path: path, branch: branch, palette: plain)
        .flatMap { $0 }.map(\.ink)
    let overriddenInk = PromptStyle.spaceship
        .lines(user: user, host: host, path: path, branch: branch, palette: overridden)
        .flatMap { $0 }.map(\.ink)
    h.expect(plainInk != overriddenInk, "an override changes the ink the prompt draws with")

    // MARK: The prompt a shell actually wears
    //
    // The gallery is not a picture any more: the same runs become a zsh prompt.
    // What matters here is that every style produces one, that it is built from
    // prompt escapes rather than the preview's literal names, and that a style
    // which names a branch asks the snippet to compute one.

    let zshPrompts = PromptStyle.allCases.map { $0.zshPrompt(palette: Palette(preset: .dark)) }
    h.equal(Set(zshPrompts.map(\.prompt)).count, PromptStyle.allCases.count,
            "every style produces a different zsh prompt")
    for (style, prompt) in zip(PromptStyle.allCases, zshPrompts) {
        h.expect(prompt.prompt.contains("%F{#"),
                 "\(style.rawValue) colours the prompt with its palette")
        h.expect(prompt.prompt.contains("%~"),
                 "\(style.rawValue) asks zsh for the working directory")
        h.expect(!prompt.prompt.contains(user) && !prompt.prompt.contains(host),
                 "\(style.rawValue) leaves user and host to zsh")
        h.expect(prompt.prompt.contains("${__nymbra_branch}") == prompt.usesBranch,
                 "\(style.rawValue) asks for a branch only when it draws one")
    }
    h.expect(PromptStyle.agnoster.zshPrompt(palette: Palette(preset: .dark))
                .prompt.contains("%K{#"),
             "a Powerline style fills its blocks in the shell too")
    h.expect(PromptStyle.kali.zshPrompt(palette: Palette(preset: .dark))
                .prompt.contains("\n"),
             "kali keeps its second line in the shell")
}
