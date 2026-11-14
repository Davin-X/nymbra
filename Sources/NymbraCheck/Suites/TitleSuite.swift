import NymbraCore

/// What tabs and windows are called: where the shell is and what it runs,
/// never the application's own name.
func titleSuite(_ h: Harness) {
    h.suite("title")

    let home = "/Users/me"
    typealias Facts = TerminalTitle.Facts

    // MARK: Paths

    h.equal(TerminalTitle.abbreviate("/Users/me/src/nymbra", home: home), "~/src/nymbra",
            "home is written ~")
    h.equal(TerminalTitle.abbreviate("/Users/me", home: home), "~", "home itself is ~")
    h.equal(TerminalTitle.abbreviate("/Users/meg/x", home: home), "/Users/meg/x",
            "a folder that only starts with the same letters is not home")
    h.equal(TerminalTitle.folderName("/Users/me/src/nymbra", home: home), "nymbra",
            "a tab is named after the folder it is in")
    h.equal(TerminalTitle.folderName("/", home: home), "/", "the root is /")
    h.equal(TerminalTitle.breadcrumbs("/Users/me/src/nymbra", home: home), ["~", "src", "nymbra"],
            "breadcrumbs start at home")
    h.equal(TerminalTitle.breadcrumbs("/usr/local/bin", home: home), ["/", "usr", "local", "bin"],
            "and at the root outside it")

    // MARK: Which name wins

    let here = Facts(directory: "/Users/me/src/nymbra", shellPath: "/bin/zsh", home: home)
    h.equal(TerminalTitle.tabName(here), "nymbra", "at the prompt, the folder")
    h.equal(TerminalTitle.windowTitle(here), "nymbra \u{2014} ~/src/nymbra",
            "the window adds where the folder is")

    var running = here
    running.foregroundProgram = "vim"
    h.equal(TerminalTitle.tabName(running), "vim", "a running program names the tab")
    h.equal(TerminalTitle.windowTitle(running), "vim \u{2014} ~/src/nymbra", "and the window says where")

    var titled = running
    titled.programTitle = "README.md - VIM"
    h.equal(TerminalTitle.tabName(titled), "README.md - VIM", "a title a program set wins over its name")
    h.equal(TerminalTitle.windowTitle(titled), "README.md - VIM", "and is shown as the program wrote it")

    var custom = titled
    custom.customTitle = "  deploy  "
    h.equal(TerminalTitle.tabName(custom), "deploy", "a name the person gave always wins")

    h.equal(TerminalTitle.tabName(Facts(shellPath: "/opt/homebrew/bin/fish", home: home)), "fish",
            "with nothing else known, the shell")
    h.equal(TerminalTitle.windowTitle(Facts(directory: home, home: home)), "~",
            "home is not written twice")
    h.expect(TerminalTitle.tabName(Facts(home: home)) != "Nymbra", "never the application's name")

    // MARK: OSC 7 — the shell says where it is

    let screen = Screen(rows: 3, cols: 20)
    let parser = Parser(screen: screen)
    parser.feed("\u{1B}]7;file://my-mac/Users/me/a%20folder\u{07}")
    h.equal(screen.reportedDirectory, "/Users/me/a folder", "OSC 7 is decoded to a path")
    parser.feed("\u{1B}]7;file:///srv/app\u{1B}\\")
    h.equal(screen.reportedDirectory, "/srv/app", "an empty host and an ST terminator are fine")
    parser.feed("\u{1B}]7;https://example.com/x\u{07}")
    h.equal(screen.reportedDirectory, "/srv/app", "anything that is not a file URL is ignored")
    h.equal(screen.rowText(0).trimmingCharacters(in: .whitespaces), "", "and none of it is drawn")
}
