import NymbraInput

/// Shortcut parsing and the command list behind the settings window.
///
/// The point of testing this rather than eyeballing it: a shortcut that parses
/// when it should not is a key the terminal silently steals, and a shortcut that
/// fails to parse when it should not is a setting the user cannot use.
func shortcutSuite(_ h: Harness) {
    h.suite("shortcut")

    let command = Keyboard.Modifiers.command
    let shift = Keyboard.Modifiers.shift
    let control = Keyboard.Modifiers.control
    let option = Keyboard.Modifiers.option

    // MARK: Parsing

    h.equal(Shortcut(parsing: "cmd+c"), Shortcut(modifiers: command, key: .character("c")),
            "a command chord parses")
    h.equal(Shortcut(parsing: "cmd+shift+t"), Shortcut(modifiers: [command, shift], key: .character("t")),
            "modifiers stack")
    h.equal(Shortcut(parsing: "ctrl+left"),
            Shortcut(modifiers: control, key: .named(.left)),
            "a key with no character of its own parses by name")
    h.equal(Shortcut(parsing: "cmd+f5"),
            Shortcut(modifiers: command, key: .named(.function(5))),
            "function keys parse")
    h.equal(Shortcut(parsing: "cmd+f20"),
            Shortcut(modifiers: command, key: .named(.function(20))),
            "the last function key parses")

    // Aliases exist because people write these four ways.
    h.equal(Shortcut(parsing: "command+c"), Shortcut(parsing: "cmd+c"), "command is cmd")
    h.equal(Shortcut(parsing: "control+c"), Shortcut(parsing: "ctrl+c"), "control is ctrl")
    h.equal(Shortcut(parsing: "alt+c"), Shortcut(parsing: "opt+c"), "alt is opt")
    h.equal(Shortcut(parsing: "option+c"), Shortcut(parsing: "opt+c"), "option is opt")
    h.equal(Shortcut(parsing: "CMD+C"), Shortcut(parsing: "cmd+c"), "case does not matter")
    h.equal(Shortcut(parsing: "cmd + c"), Shortcut(parsing: "cmd+c"), "spaces around + are tolerated")
    h.equal(Shortcut(parsing: "return"), Shortcut(modifiers: [], key: .named(.returnKey)),
            "a bare key is a shortcut with no modifiers")
    h.equal(Shortcut(parsing: "enter"), Shortcut(parsing: "return"), "enter is return")
    h.equal(Shortcut(parsing: "esc"), Shortcut(parsing: "escape"), "esc is escape")
    h.equal(Shortcut(parsing: "backspace"), Shortcut(parsing: "delete"), "backspace is delete")

    // Keys whose written form would be ambiguous in a +-separated list.
    h.equal(Shortcut(parsing: "cmd+plus"), Shortcut(modifiers: command, key: .character("+")),
            "plus names the + key")
    h.equal(Shortcut(parsing: "cmd+minus"), Shortcut(modifiers: command, key: .character("-")),
            "minus names the - key")
    h.equal(Shortcut(parsing: "cmd+comma"), Shortcut(modifiers: command, key: .character(",")),
            "comma names the , key")

    // MARK: Parsing refuses what it should

    h.equal(Shortcut(parsing: ""), nil, "an empty string is not a shortcut")
    h.equal(Shortcut(parsing: "cmd+"), nil, "a modifier with no key is not a shortcut")
    h.equal(Shortcut(parsing: "+c"), nil, "a key with no modifier and an empty modifier is refused")
    h.equal(Shortcut(parsing: "cmd+notakey"), nil, "an unknown key name is refused")
    h.equal(Shortcut(parsing: "hyper+c"), nil, "an unknown modifier is refused")
    h.equal(Shortcut(parsing: "cmd+f21"), nil, "there is no F21")
    h.equal(Shortcut(parsing: "cmd+f0"), nil, "there is no F0")
    h.equal(Shortcut(parsing: "cmd c"), nil, "a missing + is refused rather than guessed at")

    // MARK: Round trip and display

    let samples = ["cmd+c", "cmd+shift+t", "ctrl+left", "cmd+f5", "cmd+comma", "opt+up"]
    for sample in samples {
        guard let parsed = Shortcut(parsing: sample) else {
            h.expect(false, "\(sample) parses")
            continue
        }
        h.equal(Shortcut(parsing: parsed.text), parsed, "\(sample) survives a round trip through text")
    }

    h.equal(Shortcut(parsing: "cmd+c")?.text, "cmd+c", "a chord prints back as it was written")
    h.equal(Shortcut(parsing: "command+shift+t")?.text, "cmd+shift+t",
            "a chord prints back in canonical form")
    h.equal(Shortcut(parsing: "cmd+c")?.display, "⌘C", "the display form uses the Apple glyphs")
    h.equal(Shortcut(parsing: "cmd+shift+t")?.display, "⇧⌘T",
            "several modifiers display together, in the platform's order")
    h.equal(Shortcut(parsing: "ctrl+left")?.display, "⌃←", "an arrow displays as an arrow")
    h.equal(Shortcut(parsing: "cmd+f5")?.display, "⌘F5", "a function key displays as F5")
    h.equal(Shortcut(parsing: "shift+cmd+t")?.display, "⇧⌘T",
            "display does not depend on the order the shortcut was written in")
    h.equal(Shortcut(parsing: "opt+c")?.modifiers, option, "opt is the option modifier")

    // MARK: Matching

    let copy = Shortcut(parsing: "cmd+c")!
    h.expect(copy.matches(keyCode: 8, charactersIgnoringModifiers: "c", modifiers: command),
             "a matching chord matches")
    h.expect(copy.matches(keyCode: 8, charactersIgnoringModifiers: "C", modifiers: command),
             "a chord matches regardless of the character's case")
    h.expect(!copy.matches(keyCode: 8, charactersIgnoringModifiers: "c", modifiers: [command, shift]),
             "a chord with an extra modifier does not match")
    h.expect(!copy.matches(keyCode: 8, charactersIgnoringModifiers: "c", modifiers: []),
             "a chord without its modifier does not match")
    h.expect(!copy.matches(keyCode: 8, charactersIgnoringModifiers: "d", modifiers: command),
             "a different key does not match")
    h.expect(!copy.matches(keyCode: 8, charactersIgnoringModifiers: nil, modifiers: command),
             "a key that produces nothing does not match a character chord")

    let arrow = Shortcut(parsing: "ctrl+left")!
    h.expect(arrow.matches(keyCode: Keyboard.Key.left.rawValue, charactersIgnoringModifiers: nil,
                           modifiers: control),
             "a named key matches by key code")
    h.expect(!arrow.matches(keyCode: Keyboard.Key.right.rawValue, charactersIgnoringModifiers: nil,
                            modifiers: control),
             "a named key does not match a different key code")

    // Shift is carried by the modifier set, so Cmd+Shift+C is a different
    // shortcut from Cmd+C and must not trigger it.
    let upper = Shortcut(parsing: "cmd+shift+c")!
    h.expect(upper.matches(keyCode: 8, charactersIgnoringModifiers: "C", modifiers: [command, shift]),
             "a shifted chord matches a shifted key")
    h.expect(!upper.matches(keyCode: 8, charactersIgnoringModifiers: "C", modifiers: command),
             "a shifted chord does not match an unshifted key")

    // MARK: The command list

    // The count is here to make "a command was added and its tests were not" a
    // failure rather than an oversight — so it is stated as the one place that
    // knows, and the loop below is what actually covers every command.
    h.equal(Command.allCases.count, 13,
            "there are thirteen commands (add one, and this line, deliberately)")
    for command in Command.allCases {
        h.expect(command.defaultShortcut != nil, "\(command.rawValue) has a default shortcut")
        h.expect(!command.title.isEmpty, "\(command.rawValue) has a title")
        h.expect(!command.explanation.isEmpty, "\(command.rawValue) explains itself")
    }

    // The pane commands have to follow the platform's conventions, because muscle
    // memory from every other terminal is the whole reason to pick these chords
    // and not others.
    h.equal(Command.splitRight.defaultShortcut, Shortcut(parsing: "cmd+d"),
            "a pane splits sideways with \u{2318}D")
    h.equal(Command.splitDown.defaultShortcut, Shortcut(parsing: "cmd+shift+d"),
            "and downwards with \u{21E7}\u{2318}D")
    h.equal(Command.closePane.defaultShortcut, Shortcut(parsing: "cmd+w"),
            "the pane the keyboard is in closes with \u{2318}W")
    h.equal(Command.focusNextPane.defaultShortcut, Shortcut(parsing: "cmd+rightbracket"),
            "focus moves on with \u{2318}]")

    // Two commands sharing a shortcut would mean one of them never fires.
    var seen: [Shortcut: Command] = [:]
    for command in Command.allCases {
        guard let shortcut = command.defaultShortcut else { continue }
        if let other = seen[shortcut] {
            h.expect(false, "\(command.rawValue) and \(other.rawValue) share \(shortcut.text)")
        }
        seen[shortcut] = command
    }
    h.expect(true, "no two commands share a default shortcut")

    h.equal(Command.shortcut(for: .copy).map { $0.text }, "cmd+c", "Copy defaults to Cmd+C")
    h.equal(Command.shortcut(for: .paste).map { $0.text }, "cmd+v", "Paste defaults to Cmd+V")
    h.equal(Command.shortcut(for: .settings).map { $0.text }, "cmd+,",
            "Settings defaults to Cmd+,")

    // MARK: Overrides

    h.equal(Command.shortcut(for: .copy, overrides: ["copy": "ctrl+shift+y"]).map { $0.text },
            "ctrl+shift+y", "an override replaces the default")
    h.equal(Command.shortcut(for: .copy, overrides: ["paste": "ctrl+shift+y"]).map { $0.text },
            "cmd+c", "an override for another command leaves this one alone")
    h.equal(Command.shortcut(for: .copy, overrides: ["copy": "nonsense"]).map { $0.text },
            "cmd+c", "an override that does not parse falls back to the default")
    h.equal(Command.shortcut(for: .copy, overrides: ["copy": ""]).map { $0.text },
            "cmd+c", "an empty override falls back to the default")

    h.equal(Command.matching(keyCode: 8, charactersIgnoringModifiers: "c", modifiers: command),
            .copy, "an event finds the command it is bound to")
    h.equal(Command.matching(keyCode: 8, charactersIgnoringModifiers: "c", modifiers: command,
                             overrides: ["copy": "ctrl+shift+y"]), nil,
            "a rebound command no longer fires on its old shortcut")
    h.equal(Command.matching(keyCode: 7, charactersIgnoringModifiers: "y",
                             modifiers: [control, shift],
                             overrides: ["copy": "ctrl+shift+y"]), .copy,
            "a rebound command fires on its new shortcut")
    h.equal(Command.matching(keyCode: 38, charactersIgnoringModifiers: "j", modifiers: command), nil,
            "a chord that belongs to no command is not a command")

    let bindings = Command.bindings()
    h.equal(bindings.count, Command.allCases.count, "the bindings list covers every command")
    // The order is the order of the enum, and the settings window renders the
    // list top to bottom: a reordering is a change to what people see, so it is
    // pinned here rather than discovered in a screenshot.
    h.equal(bindings.first?.command, .newWindow, "the bindings list is in a stable order")

    // MARK: What the menu bar will be built from
    //
    // The menu sets a key equivalent per item from `Shortcut.menuKey`, so a
    // shortcut whose menu key is empty or wider than one character would appear
    // in the menu and never fire. `AppKit` is not available to this harness, but
    // the data the menu is built from is, so the property is asserted here.

    for (command, shortcut) in Command.bindings() {
        guard let shortcut else {
            h.expect(false, "\(command.rawValue) has a shortcut to advertise")
            continue
        }
        h.equal(shortcut.menuKey.count, 1,
                "\(command.rawValue)'s menu key is exactly one character")
        h.expect(shortcut.display.hasSuffix(shortcut.key.displayText),
                 "\(command.rawValue) displays its key")
    }

    // The settings window refuses a duplicate at the moment it is typed, so the
    // search that implements that refusal has to find the other owner — and only
    // the other owner.
    h.equal(Command.owner(of: Shortcut(parsing: "cmd+c")!, excluding: .paste), .copy,
            "a chord already in use names its owner")
    h.equal(Command.owner(of: Shortcut(parsing: "cmd+c")!, excluding: .copy), nil,
            "a command is not its own conflict")
    h.equal(Command.owner(of: Shortcut(parsing: "ctrl+shift+y")!, excluding: .copy), nil,
            "an unused chord has no owner")
    h.equal(Command.owner(of: Shortcut(parsing: "ctrl+shift+y")!, excluding: .copy,
                          overrides: ["paste": "ctrl+shift+y"]), .paste,
            "an override is a conflict too")
}
