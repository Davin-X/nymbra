import AppKit
import CoreText
import Foundation
import NymbraCore
import NymbraInput

// The settings window's behaviour: loading controls from the configuration,
// what each control does when changed, and the read-backs the proofs use.
extension SettingsWindowController {
    // MARK: - Reading the configuration back in

    /// Set every control from `configuration`. Called on open, on Reset, and
    /// after a font-size shortcut changes the configuration elsewhere.
    func reload(from configuration: Configuration) {
        self.configuration = configuration

        var families = Fonts.monospacedFamilies()
        if !families.contains(configuration.appearance.fontFamily) {
            families.insert(configuration.appearance.fontFamily, at: 0)
        }
        fontPopup.removeAllItems()
        fontPopup.addItems(withTitles: families)
        fontPopup.selectItem(withTitle: configuration.appearance.fontFamily)

        fontSizeField.doubleValue = configuration.appearance.fontSize
        fontSizeStepper.doubleValue = configuration.appearance.fontSize

        let palette = Palette(preset: configuration.colours.preset,
                              overrides: configuration.colours.overrides)
        for (name, well) in colourWells {
            well.color = Self.nsColor(palette.colour(named: name) ?? palette.background)
        }
        updateContrast(palette)
        refreshGallery()

        cursorSegments.selectedSegment = Configuration.Behaviour.CursorShape.allCases
            .firstIndex(of: configuration.behaviour.cursorShape) ?? 0
        blinkToggle.state = configuration.behaviour.cursorBlinks ? .on : .off
        confirmToggle.state = configuration.behaviour.confirmBeforeClosingRunningSession ? .on : .off

        scrollbackField.integerValue = configuration.behaviour.scrollbackLines

        promptApplyToggle.state = configuration.appearance.promptStyleApplied ? .on : .off
        for (styleID, card) in promptStyleCards {
            stylePromptCard(card, selected: styleID == configuration.appearance.promptStyle)
        }

        stopShortcutRecording()
        for (command, field) in shortcutFields {
            field.title = Command.shortcut(for: command,
                                           overrides: configuration.keyboard.overrides)?.display ?? "Record"
        }
        shortcutWarning.stringValue = ""

        shellPopup.removeAllItems()
        let choices = shellChoices()
        shellPopup.addItems(withTitles: choices.map(shellTitle))
        if let index = choices.firstIndex(where: { $0 == configuration.shell.path }) {
            shellPopup.selectItem(at: index)
        }
        shellPathField.stringValue = configuration.shell.path ?? ""
        shellNote.textColor = .secondaryLabelColor
        shellNote.stringValue = "Applies to new windows; a shell that is already running stays put."

        preview.configuration = configuration
    }

    /// Hand a change to the application. Deliberately does *not* reload the
    /// controls: that would fight whatever the user is in the middle of typing.
    func apply(_ updated: Configuration) {
        configuration = updated
        let palette = Palette(preset: updated.colours.preset, overrides: updated.colours.overrides)
        updateContrast(palette)
        preview.configuration = updated
        onChange(updated)
    }

    func updateContrast(_ palette: Palette) {
        let ratio = Palette.RGB.contrastRatio(palette.foreground, palette.background)
        contrastLabel.stringValue = ratio >= 4.5
            ? String(format: "Text on background: %.1f:1 — readable.", ratio)
            : String(format: "Text on background: %.1f:1 — hard to read. WCAG asks for 4.5:1.", ratio)
        contrastLabel.textColor = ratio >= 4.5 ? .secondaryLabelColor : .systemOrange
    }

    // MARK: - Actions: appearance

    @objc func fontChanged(_ sender: NSPopUpButton) {
        var updated = configuration
        updated.appearance.fontFamily = sender.titleOfSelectedItem ?? updated.appearance.fontFamily
        apply(updated)
    }

    @objc func fontSizeTyped(_ sender: NSTextField) {
        setFontSize(sender.doubleValue)
    }

    @objc func fontSizeStepped(_ sender: NSStepper) {
        setFontSize(sender.doubleValue)
    }

    func setFontSize(_ size: Double) {
        var updated = configuration
        let range = Configuration.Appearance.fontSizeRange
        updated.appearance.fontSize = min(max(size.rounded(), range.lowerBound), range.upperBound)
        fontSizeField.doubleValue = updated.appearance.fontSize
        fontSizeStepper.doubleValue = updated.appearance.fontSize
        apply(updated)
    }

    // MARK: - Actions: colours

    @objc func themeCardClicked(_ sender: ThemeCardView) {
        // A gallery card is a deliberate fresh choice, so it clears overrides:
        // what you see on the card is what the terminal shows.
        var updated = configuration
        updated.colours.preset = sender.preset
        updated.colours.overrides = [:]
        apply(updated)
        let palette = Palette(preset: sender.preset, overrides: [:])
        for (name, well) in colourWells {
            well.color = Self.nsColor(palette.colour(named: name) ?? palette.background)
        }
        updateContrast(palette)
        refreshGallery()
    }

    @objc func revertColours(_ sender: NSButton) {
        // The way back that clears *only* the colours: font, behaviour and
        // shell stay exactly as they were.
        var updated = configuration
        updated.colours.overrides = [:]
        apply(updated)
        let palette = Palette(preset: updated.colours.preset, overrides: [:])
        for (name, well) in colourWells {
            well.color = Self.nsColor(palette.colour(named: name) ?? palette.background)
        }
        updateContrast(palette)
        refreshGallery()
    }

    /// The gallery marks the selected preset as modified when custom overrides exist.
    func refreshGallery() {
        let modified = !configuration.colours.overrides.isEmpty
        for card in gallery {
            if card.preset == configuration.colours.preset {
                card.selectionState = modified ? .modified : .selected
            } else {
                card.selectionState = .unselected
            }
        }
        galleryModifiedNote.isHidden = !modified
        galleryRevertButton.isHidden = !modified
    }

    @objc func colourChanged(_ sender: NSColorWell) {
        guard let name = sender.identifier?.rawValue, let colour = Self.rgb(from: sender.color) else { return }
        var updated = configuration
        updated.colours.overrides[name] = colour.hex
        apply(updated)
        refreshGallery()
    }

    @objc func promptStyleSelected(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var updated = configuration
        updated.appearance.promptStyle = id
        // Picking a style is the same act as asking for it: leaving the toggle
        // off would record a preference that changes nothing, which is exactly
        // the complaint the gallery was meant to answer.
        updated.appearance.promptStyleApplied = true
        apply(updated)
        preview.configuration = updated
        promptApplyToggle.state = .on
        onApplyPrompt?(updated)
        for (styleID, card) in promptStyleCards {
            stylePromptCard(card, selected: styleID == id)
        }
    }

    @objc func applyPromptToCurrentTab(_ sender: NSButton) {
        onApplyPrompt?(configuration)
    }

    @objc func promptStyleApplyToggled(_ sender: NSButton) {
        var updated = configuration
        updated.appearance.promptStyleApplied = sender.state == .on
        apply(updated)
    }

    @objc func selectAdvancedPage(_ sender: NSButton) {
        selectPage("Advanced")
    }

    // MARK: - Actions: behaviour

    @objc func cursorShapeChanged(_ sender: NSSegmentedControl) {
        guard Configuration.Behaviour.CursorShape.allCases.indices.contains(sender.selectedSegment) else { return }
        var updated = configuration
        updated.behaviour.cursorShape =
            Configuration.Behaviour.CursorShape.allCases[sender.selectedSegment]
        apply(updated)
    }

    @objc func blinkChanged(_ sender: NSButton) {
        var updated = configuration
        updated.behaviour.cursorBlinks = sender.state == .on
        apply(updated)
    }

    @objc func scrollbackTyped(_ sender: NSTextField) {
        var updated = configuration
        let range = Configuration.Behaviour.scrollbackRange
        updated.behaviour.scrollbackLines = min(max(sender.integerValue, range.lowerBound), range.upperBound)
        sender.integerValue = updated.behaviour.scrollbackLines
        apply(updated)
    }

    @objc func confirmChanged(_ sender: NSButton) {
        var updated = configuration
        updated.behaviour.confirmBeforeClosingRunningSession = sender.state == .on
        apply(updated)
    }

    // MARK: - Actions: keyboard

    @objc func shortcutRecordRequested(_ sender: ShortcutCaptureButton) {
        guard let raw = sender.identifier?.rawValue, let command = Command(rawValue: raw) else { return }
        beginRecording(command)
    }

    /// Start recording a shortcut for `command`, exactly as clicking the command's
    /// button does.
    ///
    /// Internal rather than private because `--settings-test` drives this path: the
    /// monitor it installs sees every key in the application, so one that outlives
    /// the window it belongs to would swallow Escape everywhere — including in the
    /// terminal. That has to be a failing test rather than a review note.
    func beginRecording(_ command: Command) {
        stopShortcutRecording()
        guard let field = shortcutFields[command] else { return }
        recordingShortcut = command
        field.title = "Press shortcut…"
        shortcutWarning.textColor = .secondaryLabelColor
        shortcutWarning.stringValue = "Press a shortcut with at least one modifier. Escape cancels."
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureShortcut(event) ?? event
        }
    }

    @objc func shortcutRestoreDefault(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let command = Command(rawValue: raw) else { return }
        stopShortcutRecording()
        var updated = configuration
        updated.keyboard.overrides.removeValue(forKey: command.rawValue)
        apply(updated)
        shortcutFields[command]?.title = Command.shortcut(for: command)?.display ?? "Record"
        shortcutWarning.stringValue = ""
    }

    /// Handle a key while recording.
    ///
    /// Returns the event when it is somebody else's — including when nothing is
    /// being recorded, which is what makes a monitor that is on its way out
    /// harmless rather than a trap.
    ///
    /// Internal for the same reason as `beginRecording`: `--settings-test` sends
    /// events through it, because the rules it enforces (a modifier is required, a
    /// key already in use is refused) are claims in the changelog, and a claim
    /// should be an assertion.
    func captureShortcut(_ event: NSEvent) -> NSEvent? {
        guard recordingShortcut != nil else { return event }
        if event.keyCode == 53 {
            stopShortcutRecording()
            shortcutWarning.stringValue = ""
            return nil
        }
        guard let command = recordingShortcut, let field = shortcutFields[command] else { return event }
        guard let shortcut = shortcut(from: event) else {
            shortcutWarning.textColor = .systemRed
            shortcutWarning.stringValue = "That key cannot be used as a shortcut. Try a letter, arrow, or function key."
            return nil
        }
        guard !shortcut.modifiers.isEmpty else {
            shortcutWarning.textColor = .systemRed
            shortcutWarning.stringValue = "Add a modifier such as Command, Control, Option, or Shift."
            return nil
        }
        if let owner = Command.owner(of: shortcut, excluding: command,
                                     overrides: configuration.keyboard.overrides) {
            shortcutWarning.textColor = .systemRed
            shortcutWarning.stringValue = "\(shortcut.display) is already used by \(owner.title)."
            return nil
        }

        stopShortcutRecording()
        shortcutWarning.stringValue = ""
        commitShortcut(shortcut, for: command, field: field)
        return nil
    }

    func shortcut(from event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [String] = []
        if flags.contains(.command) { modifiers.append("cmd") }
        if flags.contains(.control) { modifiers.append("ctrl") }
        if flags.contains(.option) { modifiers.append("opt") }
        if flags.contains(.shift) { modifiers.append("shift") }

        let namedKeys: [UInt16: String] = [
            36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
            76: "keypadenter", 115: "home", 116: "pageup", 117: "forwarddelete",
            119: "end", 121: "pagedown", 123: "left", 124: "right", 125: "down", 126: "up",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
            98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
            105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17",
            79: "f18", 80: "f19", 90: "f20",
        ]
        let key: String
        if let named = namedKeys[event.keyCode] {
            key = named
        } else if let character = event.charactersIgnoringModifiers?.lowercased(),
                  character.count == 1 {
            switch character {
            case "+": key = "plus"
            case "-": key = "minus"
            case "=": key = "equal"
            case ",": key = "comma"
            case ".": key = "period"
            case "/": key = "slash"
            case "\\": key = "backslash"
            case ";": key = "semicolon"
            case "'": key = "quote"
            case "`": key = "backtick"
            default: key = character
            }
        } else {
            return nil
        }
        return Shortcut(parsing: (modifiers + [key]).joined(separator: "+"))
    }

    func stopShortcutRecording() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
        if let recordingShortcut, let field = shortcutFields[recordingShortcut] {
            field.title = Command.shortcut(for: recordingShortcut,
                                           overrides: configuration.keyboard.overrides)?.display ?? "Record"
        }
        recordingShortcut = nil
    }

    /// A recording must not outlive its window: the monitor it installs sees every
    /// key the application gets, so one left behind would swallow Escape in the
    /// terminal, in the command palette, and anywhere else that wants it.
    func windowWillClose(_ notification: Notification) {
        stopShortcutRecording()
    }

    func commitShortcut(_ shortcut: Shortcut, for command: Command, field: ShortcutCaptureButton) {
        var updated = configuration
        updated.keyboard.overrides[command.rawValue] = shortcut.text
        apply(updated)
        field.title = shortcut.display
        shortcutWarning.stringValue = ""
    }

    // MARK: - Actions: shell

    @objc func shellChanged(_ sender: NSPopUpButton) {
        var updated = configuration
        updated.shell.path = shellChoices()[safe: sender.indexOfSelectedItem] ?? nil
        shellPathField.stringValue = updated.shell.path ?? ""
        shellNote.textColor = .secondaryLabelColor
        shellNote.stringValue = "Applies to new windows; a shell that is already running stays put."
        apply(updated)
    }

    @objc func useCustomShell(_ sender: NSButton) {
        let path = shellPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else {
            shellNote.textColor = .systemRed
            shellNote.stringValue = "Choose an absolute path to an existing executable file."
            NSSound.beep()
            return
        }

        var updated = configuration
        updated.shell.path = path
        apply(updated)
        shellPopup.removeAllItems()
        let choices = shellChoices()
        shellPopup.addItems(withTitles: choices.map(shellTitle))
        if let index = choices.firstIndex(where: { $0 == path }) {
            shellPopup.selectItem(at: index)
        }
        shellNote.textColor = .secondaryLabelColor
        shellNote.stringValue = "Custom shell saved. Applies to new windows; running shells stay put."
    }

    /// The shells to offer. `/etc/shells` is the system's own record of what is a
    /// valid login shell, which beats a list we would have to maintain.
    func shellChoices() -> [String?] {
        var paths: Set<String> = ["/bin/zsh", "/bin/bash", "/bin/sh"]
        if let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("/"),
                      FileManager.default.isExecutableFile(atPath: trimmed) else { continue }
                paths.insert(trimmed)
            }
        }
        if let current = configuration.shell.path { paths.insert(current) }
        return [nil] + paths.sorted()
    }

    func shellTitle(_ path: String?) -> String {
        guard let path else {
            let fallback = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return "Use $SHELL — \(fallback)"
        }
        return path
    }

    // MARK: - Actions: reset and reveal

    @objc func resetAll(_ sender: Any?) {
        let differences = configuration.differingSections(from: Configuration())
        guard !differences.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Settings are already at their defaults."
            alert.informativeText = "There is nothing to discard."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Restore the original settings?"
        alert.informativeText = "These will go back to their defaults: "
            + differences.joined(separator: ", ") + "."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try Configuration.reset()
        } catch {
            showSettingsError("Could not restore settings", error: error)
            return
        }
        let defaults = Configuration()
        reload(from: defaults)
        onChange(defaults)
    }

    @objc func revealSettingsFile(_ sender: Any?) {
        do {
            try configuration.save()
        } catch {
            showSettingsError("Could not save settings", error: error)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([Configuration.defaultURL])
    }

    func showSettingsError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    // MARK: - Reading the window back
    //
    // `--settings-test` prints this, for the same reason `--menu-test` prints the
    // menu bar: a window is the one thing CI cannot look at, so the window
    // describes itself in text instead. These read what `reload` loaded, so a
    // control that failed to pick up the configuration is visible rather than
    // merely invisible.

    /// The settings pages in their navigation order.
    var pageTitles: [String] { pageOrder }

    /// Every command and the shortcut the window is showing for it.
    var shortcutBindings: [(command: String, shortcut: String)] {
        shortcutFields
            .map { (command: $0.key.rawValue, shortcut: $0.value.title) }
            .sorted { $0.command < $1.command }
    }

    /// The colour preset names shown in the gallery.
    ///
    /// Read from the cards themselves rather than from the enum: what the window
    /// shows is the thing worth asserting, and a gallery that stopped drawing a
    /// preset should fail a test rather than quietly agree with the enum.
    var presetTitles: [String] { gallery.map { Self.title($0.preset) } }

    /// The prompt-style cards the gallery is showing, in order.
    var promptStyleTitles: [String] { PromptStyle.allCases.map(\.rawValue) }

    /// The prompt the live preview is drawing, line by line — the thing the
    /// gallery is for. Read from the preview itself, so a style that was recorded
    /// but never reached the drawing would fail a test instead of passing one.
    var previewPromptText: [String] { preview.promptText }

    /// Whether the recorded style is also the one new shells will wear.
    var isPromptStyleApplied: Bool { configuration.appearance.promptStyleApplied }

    /// Press a prompt-style card through its own action and return the preference
    /// it recorded — a card that is drawn but not wired records nothing.
    func choosePromptStyle(_ id: String) -> String {
        promptStyleCards[id]?.performClick(nil)
        return configuration.appearance.promptStyle
    }

    /// Whether a shortcut is being recorded right now.
    var isRecordingShortcut: Bool { recordingShortcut != nil }

    /// The warning line the keyboard page is showing.
    var shortcutWarningText: String { shortcutWarning.stringValue }

    /// A compact summary of loaded controls, for the headless settings proof.
    var appearanceSummary: String {
        let preset = Self.title(configuration.colours.preset)
        return "preset=\(preset) font=\(fontPopup.titleOfSelectedItem ?? "?") "
            + "size=\(fontSizeField.stringValue) "
            + "cursor=\(cursorSegments.label(forSegment: cursorSegments.selectedSegment) ?? "?") "
            + "colours=\(colourWells.count) shells=\(shellPopup.numberOfItems) "
            + "presets=\(Configuration.Colours.Preset.allCases.count) "
            + "promptStyles=\(promptStyleTitles.count)"
    }

    // MARK: - Conversions

    static func title(_ preset: Configuration.Colours.Preset) -> String {
        switch preset {
        case .dark:
            return "Dark"
        case .ember:
            return "Ember (warm dark)"
        case .fern:
            return "Fern (green dark)"
        case .violet:
            return "Violet (purple dark)"
        case .light:
            return "Light"
        case .paper:
            return "Paper (warm light)"
        case .dawn:
            return "Dawn (soft light)"
        case .highContrast:
            return "High contrast"
        }
    }

    static func nsColor(_ rgb: Palette.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1)
    }

    static func rgb(from colour: NSColor) -> Palette.RGB? {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return nil }
        return Palette.RGB(red: UInt8((srgb.redComponent * 255).rounded()),
                           green: UInt8((srgb.greenComponent * 255).rounded()),
                           blue: UInt8((srgb.blueComponent * 255).rounded()))
    }
}
