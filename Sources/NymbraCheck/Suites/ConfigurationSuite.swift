import Foundation
import NymbraCore

/// Settings: defaults, the round trip, and — the part that matters — that no
/// configuration file can stop the app from starting.
func configurationSuite(_ h: Harness) {
    h.suite("configuration")

    // MARK: Defaults

    let defaults = Configuration()
    h.equal(defaults.behaviour.scrollbackLines, 10_000, "scrollback defaults to 10 000 lines")
    h.equal(defaults.behaviour.cursorShape, .block, "the cursor defaults to a block")
    h.equal(defaults.behaviour.cursorBlinks, true, "the cursor blinks by default")
    h.equal(defaults.behaviour.confirmBeforeClosingRunningSession, true,
            "closing a session that is still running is confirmed by default")
    h.equal(defaults.behaviour.shellIntegration, false,
            "shell integration is off until it is asked for")
    h.equal(defaults.colours.preset, .dark, "the default preset is dark")
    h.equal(defaults.appearance.fontSize, 13, "the default font size is 13pt")
    h.equal(defaults.appearance.fontFamily, "Menlo", "the default font is Menlo")
    h.equal(defaults.shell.path, nil, "the shell defaults to $SHELL, not a hardcoded path")
    h.expect(defaults.isNormalised, "the defaults need no repair")

    if ProcessInfo.processInfo.environment["NYMBRA_CONFIG"] == nil {
        h.expect(Configuration.defaultURL.path.hasSuffix("Nymbra/config.json"),
                 "the default location is Application Support/Nymbra/config.json")
    }

    // MARK: A file that is not there

    let missing = Configuration.load(from: tempURL())
    h.equal(missing.configuration, defaults, "a missing file is the defaults")
    h.equal(missing.isClean, true, "a missing file is not worth a warning")

    // MARK: The round trip

    var edited = Configuration()
    edited.appearance.fontFamily = "SF Mono"
    edited.appearance.fontSize = 16
    edited.colours.preset = .highContrast
    edited.colours.overrides["red"] = "#ff0000"
    edited.behaviour.cursorShape = .bar
    edited.behaviour.cursorBlinks = false
    edited.behaviour.scrollbackLines = 500
    edited.behaviour.shellIntegration = true
    edited.shell.path = "/bin/dash"

    let saved = tempURL()
    do {
        try edited.save(to: saved)
        let reloaded = Configuration.load(from: saved)
        h.equal(reloaded.configuration, edited, "a configuration survives a save and a load")
        h.equal(reloaded.isClean, true, "a configuration we wrote loads without complaint")

        let text = try String(contentsOf: saved, encoding: .utf8)
        h.expect(text.hasSuffix("\n"), "the file ends in a newline, because it is a text file")
        h.expect(text.contains("\n  \"appearance\""), "it is pretty-printed, so a diff is readable")
        try FileManager.default.removeItem(at: saved)
    } catch {
        h.expect(false, "writing a configuration to a temporary file")
    }

    // MARK: Reset

    var editedSections = Configuration()
    editedSections.appearance.fontSize = 20
    editedSections.colours.preset = .light
    h.equal(editedSections.differingSections(from: defaults), ["Appearance", "Colours"],
            "Reset can say which sections it would discard")
    h.equal(defaults.differingSections(from: defaults), [],
            "Reset on an unedited configuration reports nothing to discard")
    h.equal(Configuration().differingSections(from: editedSections), ["Appearance", "Colours"],
            "the difference does not depend on which way round it is compared")

    let resettable = tempURL()
    do {
        try edited.save(to: resettable)
        try Configuration.reset(at: resettable)
        h.equal(Configuration.load(from: resettable).configuration, defaults,
                "reset puts the defaults back")

        // Reset must also work when there was never a file to begin with.
        let absent = tempURL()
        try Configuration.reset(at: absent)
        h.equal(Configuration.load(from: absent).configuration, defaults,
                "reset creates the file when none exists")
        try FileManager.default.removeItem(at: absent)
        try FileManager.default.removeItem(at: resettable)
    } catch {
        h.expect(false, "resetting a configuration")
    }

    // MARK: Files a person could plausibly write

    withConfiguration(#"{"appearance": {"fontSize": 16}}"#) { result in
        h.equal(result.configuration.appearance.fontSize, 16, "a setting that is present is applied")
        h.equal(result.configuration.appearance.fontFamily, "Menlo", "a missing sibling keeps its default")
        h.equal(result.configuration.behaviour, Configuration.Behaviour(), "a missing section keeps its defaults")
        h.equal(result.configuration.shell, Configuration.Shell(), "a missing section keeps its defaults")
        h.equal(result.isClean, true, "a partial file is not a problem")
    }

    withConfiguration(#"{"futureThing": {"a": 1}, "appearance": {"fontSize": 15}}"#) { result in
        h.equal(result.configuration.appearance.fontSize, 15, "a known setting still applies")
        h.equal(result.warnings.count, 1, "an unknown setting is reported once")
        h.expect(result.warnings.first?.contains("futureThing") == true, "the warning names the setting")
    }

    withConfiguration(#"{"shell": {"path": "/opt/homebrew/bin/fish"}}"#) { result in
        h.equal(result.configuration.shell.path, "/opt/homebrew/bin/fish", "an absolute shell path is kept")
        h.equal(result.isClean, true, "an absolute shell path is not a problem")
    }

    // MARK: Files that are wrong, and must still not stop the app

    withConfiguration("{not json") { result in
        h.equal(result.configuration, defaults, "invalid JSON falls back to the defaults")
        h.equal(result.warnings.count, 1, "invalid JSON is reported")
    }

    withConfiguration("[1, 2, 3]") { result in
        h.equal(result.configuration, defaults, "a JSON array is not a configuration")
        h.equal(result.warnings.count, 1, "a JSON array is reported")
    }

    withConfiguration(#"{"appearance": {"fontSize": 0.5}}"#) { result in
        h.equal(result.configuration.appearance.fontSize, 6, "a font size below the range is clamped up")
        h.equal(result.warnings.count, 1, "clamping a font size is reported")
    }

    withConfiguration(#"{"appearance": {"fontSize": 1000}}"#) { result in
        h.equal(result.configuration.appearance.fontSize, 72, "a font size above the range is clamped down")
        h.equal(result.warnings.count, 1, "clamping a font size is reported")
    }

    withConfiguration(#"{"behaviour": {"scrollbackLines": -5}}"#) { result in
        h.equal(result.configuration.behaviour.scrollbackLines, 0, "a negative scrollback is clamped to nothing")
        h.equal(result.warnings.count, 1, "clamping the scrollback is reported")
    }

    // Note the `##` delimiters: `"#` would otherwise end the raw string.
    withConfiguration(##"{"colours": {"overrides": {"red": "#ff0000", "chartreuse": "#00ff00", "blue": "nothex"}}}"##) { result in
        h.equal(result.configuration.colours.overrides, ["red": "#ff0000"],
                "only colour overrides we can actually use survive")
        h.equal(result.warnings.count, 2, "each rejected colour override is reported")
    }

    withConfiguration(#"{"shell": {"path": "zsh"}}"#) { result in
        h.equal(result.configuration.shell.path, nil, "a relative shell path is refused")
        h.equal(result.warnings.count, 1, "a relative shell path is reported")
    }

    withConfiguration(#"{"keyboard": {"overrides": {"paste": "cmd+v", "copy": "cmd + c"}}}"#) { result in
        h.equal(result.configuration.keyboard.overrides, ["paste": "cmd+v"],
                "only shortcut-shaped overrides survive")
        h.equal(result.warnings.count, 1, "a rejected shortcut is reported")
    }

    // MARK: Shell integration

    // The setting is the only thing standing between a user and a rearranged
    // shell startup, so both halves are checked: that "off" writes nothing at
    // all, and that "on" writes every file zsh asks for by name — a file left
    // out is one of the user's own that would never run.
    let support = tempDirectory()
    let generated = support.appendingPathComponent("shell")
    defer { try? FileManager.default.removeItem(at: support) }

    h.expect(Configuration().shellIntegration(in: support, userZDOTDIR: "/tmp/user") == nil,
             "with the setting off there is no integration to start a shell with")
    h.expect(!FileManager.default.fileExists(atPath: generated.path),
             "and nothing is written for it")

    var wanting = Configuration()
    wanting.behaviour.shellIntegration = true
    let integration = wanting.shellIntegration(in: support, userZDOTDIR: "/tmp/user")
    h.expect(integration != nil, "with the setting on, an integration comes back")
    h.equal(integration?.environment["ZDOTDIR"] ?? "", generated.path,
            "the shell is pointed at Nymbra's own directory")
    h.equal(integration?.environment["NYMBRA_USER_ZDOTDIR"] ?? "", "/tmp/user",
            "and told where the real startup files are, so they still run")

    for name in ShellIntegration.startupFiles + ["nymbra.zsh"] {
        h.expect(FileManager.default.fileExists(atPath: generated.appendingPathComponent(name).path),
                 "\(name) is generated, so zsh reads ours and the user's own is not skipped")
    }

    let zshrc = (try? String(contentsOf: generated.appendingPathComponent(".zshrc"),
                             encoding: .utf8)) ?? ""
    // `NYMBRA_USER_ZDOTDIR` rather than the literal path: which directory the
    // user's own startup lives in is settled in the shell, at the moment, not
    // here — and the check above pins what it is set to.
    h.expect(zshrc.contains("NYMBRA_USER_ZDOTDIR") && zshrc.contains("/.zshrc"),
             "the generated .zshrc loads the user's own .zshrc, wherever it is")
    h.expect(zshrc.contains("${ZDOTDIR}/nymbra.zsh"),
             "and then the snippet, which is the only part that sends a mark")

    // MARK: Hostile input

    // Every one of these must leave the app able to start, and leave a
    // configuration that is already in range. This is the invariant the ADR
    // promises: the config file can annoy, but it cannot break.
    let hostile = [
        "", "null", "{}", "[]", "0", "\"a string\"",
        #"{"appearance": 1}"#,
        #"{"appearance": null}"#,
        #"{"appearance": []}"#,
        #"{"appearance": {"fontSize": null, "fontFamily": []}}"#,
        #"{"behaviour": "nonsense"}"#,
        #"{"colours": {"overrides": 3}}"#,
        #"{"colours": {"preset": "neon"}}"#,
        #"{"keyboard": {"overrides": []}}"#,
        #"{"shell": {"path": 42}}"#,
        #"{"shell": {"path": ""}}"#,
        #"{"appearance": {"fontFamily": "   "}}"#,
    ]
    for blob in hostile {
        withConfiguration(blob) { result in
            h.expect(result.configuration.isNormalised,
                     "a loaded configuration is already valid: \(blob.prefix(28))")
        }
    }
}

// MARK: - Helpers

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("nymbra-\(UUID().uuidString).json")
}

/// A path that does not exist yet, for things that write a directory of their
/// own rather than a single file.
private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("nymbra-\(UUID().uuidString)")
}

/// Write a configuration file, load it through the real path, and remove it.
private func withConfiguration(_ json: String, _ body: (Configuration.LoadResult) -> Void) {
    let url = tempURL()
    try? Data(json.utf8).write(to: url)
    body(Configuration.load(from: url))
    try? FileManager.default.removeItem(at: url)
}
