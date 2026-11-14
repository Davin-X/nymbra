import Foundation

/// A shell prompt's look, as the settings gallery shows it.
///
/// Nymbra does not edit a shell's startup files. When a person asks for one of
/// these styles, Nymbra generates a `PROMPT` for the shell it starts and hands it
/// over through the same generated `ZDOTDIR` that carries the rest of its shell
/// integration — see `ShellIntegration`. A shell that is already running keeps
/// the prompt it started with, and a shell Nymbra did not start is untouched.
///
/// The styles are named after prompts people recognise and reproduce only their
/// *shape*: which pieces appear, in what order, in which palette colour, and
/// whether a piece is a filled block. No third-party prompt's code is involved,
/// and nothing here is drawn from one.
public enum PromptStyle: String, CaseIterable, Sendable {
    case git
    case robbyrussell
    case pure
    case agnoster
    case starship
    case spaceship
    case kali
    case powerlevel10k

    /// The name on the gallery card.
    public var title: String {
        switch self {
        case .git: return "Git-aware"
        case .robbyrussell: return "Robbyrussell"
        case .pure: return "Pure"
        case .agnoster: return "Agnoster"
        case .starship: return "Starship"
        case .spaceship: return "Spaceship"
        case .kali: return "Kali"
        case .powerlevel10k: return "Powerlevel10k"
        }
    }

    /// The one-line description under the name.
    public var summary: String {
        switch self {
        case .git: return "Simple path and branch status"
        case .robbyrussell: return "The classic arrow prompt"
        case .pure: return "Quiet, minimal prompt with a clean glyph"
        case .agnoster: return "Classic Powerline color-block segments"
        case .starship: return "Fast, contextual cross-shell modules"
        case .spaceship: return "Informative prompt with clear sections"
        case .kali: return "Two-line user, host, and directory prompt"
        case .powerlevel10k: return "Highly configurable, instant-style segments"
        }
    }

    /// The style a configuration naming something we do not know falls back to.
    public static let fallback = PromptStyle.git

    /// The style named by a stored string, or the fallback.
    public init(stored name: String) {
        self = PromptStyle(rawValue: name) ?? PromptStyle.fallback
    }
}

/// One drawn piece of a previewed prompt.
///
/// The colours are *resolved* rather than symbolic. A preview is drawn on a
/// background the theme already chose, so a run has to know its own ink — and,
/// where the style fills a block, its own paper. `Palette.readable` is applied
/// when the run is built, so a preview cannot show text the real terminal would
/// have refused to.
public struct PromptRun: Equatable, Sendable {
    public let text: String
    public let ink: Palette.RGB
    /// The block drawn behind the text, when the style fills one. `nil` is
    /// "no block", which lets the renderer skip the rectangle entirely.
    public let paper: Palette.RGB?
    public let bold: Bool

    public init(text: String, ink: Palette.RGB, paper: Palette.RGB? = nil, bold: Bool = false) {
        self.text = text
        self.ink = ink
        self.paper = paper
        self.bold = bold
    }
}

/// A prompt a shell can actually wear, rather than a picture of one.
///
/// zsh prompts are a small formatting language of their own: `%n` is the user,
/// `%~` is the working directory, and `%F{...}`/`%K{...}` change the ink and the
/// paper. The strings here are that language, not the preview's text, which is
/// why they are built from the same runs and checked against the same palette
/// rather than written a second time by hand.
public struct ZshPrompt: Equatable, Sendable {
    /// The value to hand zsh as `PROMPT`.
    public let prompt: String
    /// The value to hand zsh as `RPROMPT`; empty when the style draws nothing on
    /// the right.
    public let rightPrompt: String
    /// Whether `prompt` reads the branch variable the generated precmd sets.
    /// A style that does not name a branch should not pay for a `git` process on
    /// every prompt.
    public let usesBranch: Bool

    public init(prompt: String, rightPrompt: String = "", usesBranch: Bool = false) {
        self.prompt = prompt
        self.rightPrompt = rightPrompt
        self.usesBranch = usesBranch
    }
}

extension PromptStyle {

    /// The tokens the runs use where a shell will substitute its own value. The
    /// preview passes real strings; the zsh renderer passes these, and turns them
    /// into prompt escapes once the literal text has been escaped.
    private enum Placeholder {
        static let user = "\u{E000}user\u{E001}"
        static let host = "\u{E000}host\u{E001}"
        static let path = "\u{E000}path\u{E001}"
        static let branch = "\u{E000}branch\u{E001}"
    }

    /// The style as a zsh prompt, with the palette the terminal is actually
    /// wearing. Readable ink is chosen by the same rule the preview uses, so the
    /// shell prompt and the picture of it cannot drift apart.
    public func zshPrompt(palette: Palette) -> ZshPrompt {
        let lines = lines(user: Placeholder.user,
                          host: Placeholder.host,
                          path: Placeholder.path,
                          branch: Placeholder.branch,
                          palette: palette)
        let prompt = lines
            .map { line in line.map(Self.zshEscaped).joined() }
            .joined(separator: "\n")
        // Read the branch question off the runs rather than keeping a second list
        // of which styles have one: a style that stops drawing the branch stops
        // paying for the `git` process in the same edit.
        let usesBranch = lines.flatMap { $0 }.contains { $0.text.contains(Placeholder.branch) }
        return ZshPrompt(prompt: prompt, usesBranch: usesBranch)
    }

    /// One run as zsh prompt text: escape what zsh would read as syntax, then put
    /// the colour changes and, for a block, the paper behind it.
    private static func zshEscaped(_ run: PromptRun) -> String {
        // A `%` in a zsh prompt starts an escape, so a literal one is doubled.
        var text = run.text.replacingOccurrences(of: "%", with: "%%")
        text = text.replacingOccurrences(of: Placeholder.user, with: "%n")
        text = text.replacingOccurrences(of: Placeholder.host, with: "%m")
        text = text.replacingOccurrences(of: Placeholder.path, with: "%~")
        // `${__nymbra_branch}` is expanded because the generated snippet turns on
        // `prompt_subst` when it installs a prompt.
        text = text.replacingOccurrences(of: Placeholder.branch, with: "${__nymbra_branch}")
        if let paper = run.paper {
            return "%K{\(paper.hex)}%F{\(run.ink.hex)}%B\(text)%b%f%k"
        }
        if run.bold {
            return "%F{\(run.ink.hex)}%B\(text)%b%f"
        }
        return "%F{\(run.ink.hex)}\(text)%f"
    }

    /// The previewed prompt, as lines of runs.
    ///
    /// Lines, plural, because one of the styles is a two-line prompt: the shape
    /// is the whole point of it, and a "two-line prompt" drawn on one line would
    /// be a preview of something else.
    ///
    /// The palette is a parameter rather than a stored value because the preview
    /// has to follow the theme the person is actually looking at: a block that
    /// reads on the dark preset has to still read on Paper.
    public func lines(
        user: String,
        host: String,
        path: String,
        branch: String,
        palette: Palette
    ) -> [[PromptRun]] {
        /// Text in a palette colour, held to the contrast the preset promises.
        func ink(_ text: String, _ index: Int, bold: Bool = false) -> PromptRun {
            let colour = palette.indexed(index)
            return PromptRun(
                text: text,
                ink: Palette.readable(colour, on: palette.background),
                bold: bold
            )
        }

        /// A filled block, the way Powerline prompts draw one. The fill is the
        /// palette's own colour held back toward that theme's background, so the
        /// block reads as a block in every preset instead of as a bright bar the
        /// theme never chose — the same reasoning as the find highlight.
        func block(_ text: String, _ index: Int) -> PromptRun {
            let colour = palette.indexed(index)
            let paper = Palette.blend(palette.background, with: colour, amount: 0.30)
            return PromptRun(text: text, ink: Palette.readable(colour, on: paper), paper: paper, bold: true)
        }

        /// The neutral block a Powerline prompt ends on.
        func neutralBlock(_ text: String) -> PromptRun {
            let paper = Palette.blend(palette.background, with: palette.foreground, amount: 0.22)
            return PromptRun(
                text: text,
                ink: Palette.readable(palette.foreground, on: paper),
                paper: paper,
                bold: true
            )
        }

        /// The style's own text colour: what a program that named no colour gets.
        func plain(_ text: String, bold: Bool = false) -> PromptRun {
            PromptRun(text: text, ink: Palette.readable(palette.foreground, on: palette.background), bold: bold)
        }

        switch self {
        case .git:
            return [[
                ink("\(user) ", Ansi.green),
                ink("\(path) ", Ansi.blue),
                ink("git:(\(branch)) ", Ansi.yellow),
                plain("$", bold: true),
            ]]

        case .robbyrussell:
            // The arrow replaces the user and the branch, which is what makes it
            // recognisable: one glyph and where you are.
            return [[
                ink("\(path) ", Ansi.blue),
                ink("➜", Ansi.green, bold: true),
            ]]

        case .pure:
            return [[
                ink("\(path) ", Ansi.blue),
                ink("\(branch) ", Ansi.cyan),
                ink("❯", Ansi.cyan, bold: true),
            ]]

        case .agnoster:
            // Segments with separators between them.
            return [[
                block(" \(user) ", Ansi.green),
                block(" \(path) ", Ansi.blue),
                ink(" ›", Ansi.white),
                block(" \(branch) ", Ansi.yellow),
                ink(" ›", Ansi.white),
                neutralBlock(" $ "),
            ]]

        case .starship:
            return [[
                ink("\(user) ", Ansi.green),
                ink("▸ \(path) ", Ansi.blue),
                ink("\(branch) ", Ansi.green),
                ink("❯", Ansi.green, bold: true),
            ]]

        case .spaceship:
            // The little words carry the pieces, so the eye can skip them.
            return [[
                ink("in ", Ansi.brightBlack),
                ink("\(path) ", Ansi.blue),
                ink(" on ", Ansi.brightBlack),
                ink("\(branch) ", Ansi.yellow),
                ink("❯", Ansi.magenta, bold: true),
            ]]

        case .kali:
            return [
                [ink("┌──(\(user)@\(host))-[\(path)]", Ansi.blue)],
                [ink("└─$ ", Ansi.blue)],
            ]

        case .powerlevel10k:
            return [[
                block(" \(user) ", Ansi.green),
                block(" \(path) ", Ansi.blue),
                block(" \(branch) ", Ansi.yellow),
                neutralBlock(" $ "),
            ]]
        }
    }
}

/// The palette slots a preview names, by the slot's conventional role rather
/// than by number, so "the path is blue" reads as the thing it is.
private enum Ansi {
    static let green = 2
    static let yellow = 3
    static let blue = 4
    static let magenta = 5
    static let cyan = 6
    static let white = 7
    static let brightBlack = 8
}
