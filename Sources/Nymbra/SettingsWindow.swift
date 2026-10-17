import AppKit
import CoreText
import Foundation
import NymbraCore
import NymbraInput

/// The settings window.
///
/// Every control writes one field of `Configuration` and hands the whole thing
/// back, which the application applies to the open terminals and then saves.
/// There is no state here that is not in the configuration — which is what stops
/// the window and the file from disagreeing, and what makes the preview real
/// rather than a mock-up.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {

    private var configuration: Configuration
    private let onChange: (Configuration) -> Void

    // Held so `reload` can set them all again: Reset, and the font-size
    // shortcuts, change the configuration behind this window's back.
    private let tabs = NSTabView()
    private let preview = PreviewView()
    private let presetPopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let cursorPopup = NSPopUpButton()
    private let blinkCheckbox = NSButton(checkboxWithTitle: "Blink the cursor", target: nil, action: nil)
    private let scrollbackField = NSTextField()
    private let confirmCheckbox = NSButton(
        checkboxWithTitle: "Ask before closing a window whose command is still running",
        target: nil, action: nil
    )
    private let shellPopup = NSPopUpButton()
    private let shellNote = NSTextField(labelWithString: "")
    private let contrastLabel = NSTextField(labelWithString: "")
    private var colourWells: [String: NSColorWell] = [:]
    private var shortcutFields: [Command: NSTextField] = [:]
    private let shortcutWarning = NSTextField(labelWithString: "")

    init(configuration: Configuration, onChange: @escaping (Configuration) -> Void) {
        self.configuration = configuration
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nymbra Settings"
        super.init(window: window)

        let content = makeContent()
        window.contentView = content
        reload(from: configuration)
        window.setContentSize(content.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let panes: [(String, NSView)] = [
            ("Appearance", appearancePane()),
            ("Colours", coloursPane()),
            ("Behaviour", behaviourPane()),
            ("Keyboard", keyboardPane()),
            ("Shell", shellPane()),
        ]

        for (title, view) in panes {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = view
            tabs.addTabViewItem(item)
        }
        tabs.translatesAutoresizingMaskIntoConstraints = false

        // Size the window to the tallest tab, so nothing is scrolled away or
        // clipped. The panes are built from intrinsic sizes, so this is exact
        // rather than guessed at.
        let tallest = panes.map { $0.1.fittingSize }.max { $0.height < $1.height }
            ?? NSSize(width: 680, height: 480)
        NSLayoutConstraint.activate([
            tabs.widthAnchor.constraint(equalToConstant: max(700, tallest.width + 32)),
            tabs.heightAnchor.constraint(equalToConstant: tallest.height + 24),
        ])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [resetButton(), spacer, revealButton()])
        bottom.orientation = .horizontal
        bottom.distribution = .fill
        bottom.spacing = 10

        let root = NSStackView(views: [tabs, bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottom.widthAnchor.constraint(equalTo: tabs.widthAnchor),
        ])
        return container
    }

    private func paneStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func label(_ text: String, width: CGFloat = 100) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func row(_ text: String, _ control: NSView, hint: String? = nil) -> NSStackView {
        let stack = NSStackView(views: [label(text), control])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .firstBaseline
        if let hint {
            let hintLabel = NSTextField(labelWithString: hint)
            hintLabel.textColor = .secondaryLabelColor
            hintLabel.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(hintLabel)
        }
        return stack
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 12)
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10)
        field.textColor = .secondaryLabelColor
        return field
    }

    // MARK: - Panes

    private func appearancePane() -> NSView {
        let pane = paneStack()

        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        pane.addArrangedSubview(row("Font", fontPopup, hint: "Monospaced families"))

        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeTyped(_:))
        fontSizeField.alignment = .right
        fontSizeField.translatesAutoresizingMaskIntoConstraints = false
        fontSizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped(_:))
        fontSizeStepper.minValue = Configuration.Appearance.fontSizeRange.lowerBound
        fontSizeStepper.maxValue = Configuration.Appearance.fontSizeRange.upperBound
        fontSizeStepper.increment = 1
        let sizeControls = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeControls.orientation = .horizontal
        sizeControls.spacing = 6
        pane.addArrangedSubview(row("Size", sizeControls, hint: "6–72pt"))

        pane.addArrangedSubview(sectionLabel("Preview"))
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 560).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 150).isActive = true
        pane.addArrangedSubview(preview)
        pane.addArrangedSubview(caption("Everything here applies to the open terminal as you change it."))
        return pane
    }

    private func coloursPane() -> NSView {
        let pane = paneStack()

        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        presetPopup.addItems(withTitles: Configuration.Colours.Preset.allCases.map(Self.title))
        pane.addArrangedSubview(row("Preset", presetPopup, hint: "A starting point you can adjust"))

        pane.addArrangedSubview(sectionLabel("Colours"))
        let names = Palette.interfaceNames + Palette.ansiNames
        let grid = NSGridView(numberOfColumns: 4, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        for start in stride(from: 0, to: names.count, by: 4) {
            var cells: [NSView] = []
            for name in names[start..<min(start + 4, names.count)] {
                let well = NSColorWell()
                well.identifier = NSUserInterfaceItemIdentifier(name)
                well.target = self
                well.action = #selector(colourChanged(_:))
                well.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    well.widthAnchor.constraint(equalToConstant: 60),
                    well.heightAnchor.constraint(equalToConstant: 22),
                ])
                colourWells[name] = well

                let cell = NSStackView(views: [well, caption(name)])
                cell.orientation = .vertical
                cell.alignment = .leading
                cell.spacing = 2
                cells.append(cell)
            }
            grid.addRow(with: cells)
        }
        pane.addArrangedSubview(grid)

        contrastLabel.font = .systemFont(ofSize: 11)
        pane.addArrangedSubview(contrastLabel)
        return pane
    }

    private func behaviourPane() -> NSView {
        let pane = paneStack()

        cursorPopup.target = self
        cursorPopup.action = #selector(cursorShapeChanged(_:))
        cursorPopup.addItems(withTitles: Configuration.Behaviour.CursorShape.allCases.map { $0.rawValue.capitalized })
        pane.addArrangedSubview(row("Cursor", cursorPopup, hint: "A program can override this"))

        blinkCheckbox.target = self
        blinkCheckbox.action = #selector(blinkChanged(_:))
        pane.addArrangedSubview(row("Blink", blinkCheckbox))

        scrollbackField.target = self
        scrollbackField.action = #selector(scrollbackTyped(_:))
        scrollbackField.alignment = .right
        scrollbackField.translatesAutoresizingMaskIntoConstraints = false
        scrollbackField.widthAnchor.constraint(equalToConstant: 84).isActive = true
        pane.addArrangedSubview(row("Scrollback", scrollbackField, hint: "Lines kept above the screen"))

        confirmCheckbox.target = self
        confirmCheckbox.action = #selector(confirmChanged(_:))
        pane.addArrangedSubview(row("Closing", confirmCheckbox))
        return pane
    }

    private func keyboardPane() -> NSView {
        let pane = paneStack()
        pane.addArrangedSubview(caption("Nymbra's own shortcuts. Every other key goes to the program."))

        for (command, shortcut) in Command.bindings() {
            let field = NSTextField(string: shortcut?.text ?? "")
            field.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            field.target = self
            field.action = #selector(shortcutCommitted(_:))
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 130).isActive = true
            shortcutFields[command] = field

            let restore = NSButton(title: "Default", target: self, action: #selector(shortcutRestoreDefault(_:)))
            restore.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            restore.controlSize = .small

            let controls = NSStackView(views: [field, restore])
            controls.orientation = .horizontal
            controls.spacing = 6
            pane.addArrangedSubview(row(command.title, controls, hint: command.explanation))
        }

        shortcutWarning.font = .systemFont(ofSize: 11)
        pane.addArrangedSubview(shortcutWarning)
        return pane
    }

    private func shellPane() -> NSView {
        let pane = paneStack()

        shellPopup.target = self
        shellPopup.action = #selector(shellChanged(_:))
        pane.addArrangedSubview(row("Shell", shellPopup))

        // Say the true thing: a running shell cannot be swapped underneath the
        // program using it, so this is a setting for the next window.
        shellNote.font = .systemFont(ofSize: 11)
        shellNote.textColor = .secondaryLabelColor
        pane.addArrangedSubview(shellNote)
        return pane
    }

    private func resetButton() -> NSButton {
        NSButton(title: "Reset All Settings\u{2026}", target: self, action: #selector(resetAll(_:)))
    }

    private func revealButton() -> NSButton {
        NSButton(title: "Show Settings File", target: self, action: #selector(revealSettingsFile(_:)))
    }

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

        presetPopup.selectItem(at: Configuration.Colours.Preset.allCases
            .firstIndex(of: configuration.colours.preset) ?? 0)
        let palette = Palette(preset: configuration.colours.preset,
                              overrides: configuration.colours.overrides)
        for (name, well) in colourWells {
            well.color = Self.nsColor(palette.colour(named: name) ?? palette.background)
        }
        updateContrast(palette)

        cursorPopup.selectItem(at: Configuration.Behaviour.CursorShape.allCases
            .firstIndex(of: configuration.behaviour.cursorShape) ?? 0)
        blinkCheckbox.state = configuration.behaviour.cursorBlinks ? .on : .off
        scrollbackField.integerValue = configuration.behaviour.scrollbackLines
        confirmCheckbox.state = configuration.behaviour.confirmBeforeClosingRunningSession ? .on : .off

        for (command, field) in shortcutFields {
            field.stringValue = Command.shortcut(for: command,
                                                 overrides: configuration.keyboard.overrides)?.text ?? ""
            field.textColor = .labelColor
        }
        shortcutWarning.stringValue = ""

        shellPopup.removeAllItems()
        let choices = shellChoices()
        shellPopup.addItems(withTitles: choices.map(shellTitle))
        if let index = choices.firstIndex(where: { $0 == configuration.shell.path }) {
            shellPopup.selectItem(at: index)
        }
        shellNote.stringValue = "Applies to new windows; a shell that is already running stays put."

        preview.configuration = configuration
    }

    /// Hand a change to the application. Deliberately does *not* reload the
    /// controls: that would fight whatever the user is in the middle of typing.
    private func apply(_ updated: Configuration) {
        configuration = updated
        let palette = Palette(preset: updated.colours.preset, overrides: updated.colours.overrides)
        updateContrast(palette)
        preview.configuration = updated
        onChange(updated)
    }

    private func updateContrast(_ palette: Palette) {
        let ratio = Palette.RGB.contrastRatio(palette.foreground, palette.background)
        contrastLabel.stringValue = ratio >= 4.5
            ? String(format: "Text on background: %.1f:1 — readable.", ratio)
            : String(format: "Text on background: %.1f:1 — hard to read. WCAG asks for 4.5:1.", ratio)
        contrastLabel.textColor = ratio >= 4.5 ? .secondaryLabelColor : .systemOrange
    }

    // MARK: - Actions: appearance

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        var updated = configuration
        updated.appearance.fontFamily = sender.titleOfSelectedItem ?? updated.appearance.fontFamily
        apply(updated)
    }

    @objc private func fontSizeTyped(_ sender: NSTextField) {
        setFontSize(sender.doubleValue)
    }

    @objc private func fontSizeStepped(_ sender: NSStepper) {
        setFontSize(sender.doubleValue)
    }

    private func setFontSize(_ size: Double) {
        var updated = configuration
        let range = Configuration.Appearance.fontSizeRange
        updated.appearance.fontSize = min(max(size.rounded(), range.lowerBound), range.upperBound)
        fontSizeField.doubleValue = updated.appearance.fontSize
        fontSizeStepper.doubleValue = updated.appearance.fontSize
        apply(updated)
    }

    // MARK: - Actions: colours

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        var updated = configuration
        let preset = Configuration.Colours.Preset.allCases[safe: sender.indexOfSelectedItem] ?? .dark
        updated.colours.preset = preset
        // A preset is a starting point: keeping the overrides means one colour
        // the user tuned by hand is not thrown away when they try another theme.
        apply(updated)
        let palette = Palette(preset: preset, overrides: updated.colours.overrides)
        for (name, well) in colourWells {
            well.color = Self.nsColor(palette.colour(named: name) ?? palette.background)
        }
    }

    @objc private func colourChanged(_ sender: NSColorWell) {
        guard let name = sender.identifier?.rawValue, let colour = Self.rgb(from: sender.color) else { return }
        var updated = configuration
        updated.colours.overrides[name] = colour.hex
        apply(updated)
    }

    // MARK: - Actions: behaviour

    @objc private func cursorShapeChanged(_ sender: NSPopUpButton) {
        var updated = configuration
        updated.behaviour.cursorShape =
            Configuration.Behaviour.CursorShape.allCases[safe: sender.indexOfSelectedItem] ?? .block
        apply(updated)
    }

    @objc private func blinkChanged(_ sender: NSButton) {
        var updated = configuration
        updated.behaviour.cursorBlinks = sender.state == .on
        apply(updated)
    }

    @objc private func scrollbackTyped(_ sender: NSTextField) {
        var updated = configuration
        let range = Configuration.Behaviour.scrollbackRange
        updated.behaviour.scrollbackLines = min(max(sender.integerValue, range.lowerBound), range.upperBound)
        sender.integerValue = updated.behaviour.scrollbackLines
        apply(updated)
    }

    @objc private func confirmChanged(_ sender: NSButton) {
        var updated = configuration
        updated.behaviour.confirmBeforeClosingRunningSession = sender.state == .on
        apply(updated)
    }

    // MARK: - Actions: keyboard

    /// Validate as the user types, so a typo is visible before they leave the
    /// field rather than after.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        validate(field, commit: false)
    }

    @objc private func shortcutCommitted(_ sender: NSTextField) {
        validate(sender, commit: true)
    }

    @objc private func shortcutRestoreDefault(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let command = Command(rawValue: raw) else { return }
        var updated = configuration
        updated.keyboard.overrides.removeValue(forKey: command.rawValue)
        apply(updated)
        shortcutFields[command]?.stringValue = Command.shortcut(for: command)?.text ?? ""
        shortcutFields[command]?.textColor = .labelColor
        shortcutWarning.stringValue = ""
    }

    private func validate(_ field: NSTextField, commit: Bool) {
        guard let raw = field.identifier?.rawValue, let command = Command(rawValue: raw) else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)

        if text.isEmpty {
            commitShortcut(nil, for: command, field: field)
            return
        }
        guard let shortcut = Shortcut(parsing: text) else {
            field.textColor = .systemRed
            shortcutWarning.textColor = .systemRed
            shortcutWarning.stringValue = "\"\(text)\" is not a shortcut. Try cmd+shift+t, ctrl+left or f5."
            return
        }
        if let owner = Command.owner(of: shortcut, excluding: command,
                                     overrides: configuration.keyboard.overrides) {
            field.textColor = .systemRed
            shortcutWarning.textColor = .systemRed
            shortcutWarning.stringValue = "\(shortcut.display) is already used by \(owner.title)."
            return
        }

        field.textColor = .labelColor
        shortcutWarning.stringValue = ""
        if commit { commitShortcut(shortcut, for: command, field: field) }
    }

    private func commitShortcut(_ shortcut: Shortcut?, for command: Command, field: NSTextField) {
        var updated = configuration
        if let shortcut {
            updated.keyboard.overrides[command.rawValue] = shortcut.text
        } else {
            updated.keyboard.overrides.removeValue(forKey: command.rawValue)
        }
        apply(updated)
        field.stringValue = Command.shortcut(for: command, overrides: updated.keyboard.overrides)?.text ?? ""
        field.textColor = .labelColor
        shortcutWarning.stringValue = ""
    }

    // MARK: - Actions: shell

    @objc private func shellChanged(_ sender: NSPopUpButton) {
        var updated = configuration
        updated.shell.path = shellChoices()[safe: sender.indexOfSelectedItem] ?? nil
        apply(updated)
    }

    /// The shells to offer. `/etc/shells` is the system's own record of what is a
    /// valid login shell, which beats a list we would have to maintain.
    private func shellChoices() -> [String?] {
        var paths: Set<String> = ["/bin/zsh", "/bin/bash", "/bin/sh"]
        if let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("/"),
                      FileManager.default.isExecutableFile(atPath: trimmed) else { continue }
                paths.insert(trimmed)
            }
        }
        return [nil] + paths.sorted()
    }

    private func shellTitle(_ path: String?) -> String {
        guard let path else {
            let fallback = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return "Use $SHELL — \(fallback)"
        }
        return path
    }

    // MARK: - Actions: reset and reveal

    @objc private func resetAll(_ sender: Any?) {
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

        try? Configuration.reset()
        let defaults = Configuration()
        reload(from: defaults)
        onChange(defaults)
    }

    @objc private func revealSettingsFile(_ sender: Any?) {
        try? configuration.save()
        NSWorkspace.shared.activateFileViewerSelecting([Configuration.defaultURL])
    }

    // MARK: - Reading the window back
    //
    // `--settings-test` prints this, for the same reason `--menu-test` prints the
    // menu bar: a window is the one thing CI cannot look at, so the window
    // describes itself in text instead. These read what `reload` loaded, so a
    // control that failed to pick up the configuration is visible rather than
    // merely invisible.

    /// The tab labels, in order.
    var tabTitles: [String] { tabs.tabViewItems.map { $0.label } }

    /// Every command and the shortcut the window is showing for it.
    var shortcutBindings: [(command: String, shortcut: String)] {
        shortcutFields
            .map { (command: $0.key.rawValue, shortcut: $0.value.stringValue) }
            .sorted { $0.command < $1.command }
    }

    /// What the appearance controls loaded: preset, font, size, and how many
    /// shells `/etc/shells` offered.
    var appearanceSummary: String {
        let preset = Configuration.Colours.Preset.allCases[safe: presetPopup.indexOfSelectedItem]
            .map(Self.title) ?? "?"
        return "preset=\(preset) font=\(fontPopup.titleOfSelectedItem ?? "?") "
            + "size=\(fontSizeField.stringValue) "
            + "cursor=\(cursorPopup.titleOfSelectedItem ?? "?") "
            + "colours=\(colourWells.count) shells=\(shellPopup.numberOfItems)"
    }

    // MARK: - Conversions

    private static func title(_ preset: Configuration.Colours.Preset) -> String {
        switch preset {
        case .dark: return "Dark"
        case .light: return "Light"
        case .highContrast: return "High contrast"
        }
    }

    private static func nsColor(_ rgb: Palette.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1)
    }

    private static func rgb(from colour: NSColor) -> Palette.RGB? {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return nil }
        return Palette.RGB(red: UInt8((srgb.redComponent * 255).rounded()),
                           green: UInt8((srgb.greenComponent * 255).rounded()),
                           blue: UInt8((srgb.blueComponent * 255).rounded()))
    }
}

// MARK: - Preview

/// A live sample of the terminal: the chosen font, at the chosen size, in the
/// chosen colours.
///
/// It draws with the same `Theme` and palette the real view uses, so what it
/// shows is what the terminal will do rather than a drawing of an idea of it.
final class PreviewView: NSView {
    var configuration = Configuration() {
        didSet {
            theme = Theme(configuration)
            font = Fonts.resolve(configuration)
            boldFont = Fonts.bold(font)
            needsDisplay = true
        }
    }

    private var theme = Theme(Configuration())
    private var font = Fonts.resolve(Configuration())
    private var boldFont = Fonts.bold(Fonts.resolve(Configuration()))

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(theme.background)
        ctx.fill(bounds)

        let size = configuration.appearance.fontSize
        let lineHeight = (size * 1.5).rounded()
        let inset: CGFloat = 12
        let descent = CTFontGetDescent(font)

        let samples: [[(String, Attributes)]] = [
            [("nymbra ", sample(.indexed(2))), ("~/src/nymbra ", sample(.indexed(4))),
             ("git ", sample(.indexed(3))), ("status", sample())],
            [("On branch ", sample()), ("main", sample(.indexed(2), bold: true))],
            [("  modified:   ", sample()), ("Sources/Nymbra/SettingsWindow.swift", sample(.indexed(3)))],
            [("warning: ", sample(.indexed(1), bold: true)),
             ("1 file changed, 日本語 ok", sample(.indexed(1)))],
            [("README.md ", sample(.indexed(6), underline: .single)),
             ("docs/ ", sample(.indexed(4))),
             ("highlighted", sample(.default, background: .indexed(3)))],
            [("bold ", sample(bold: true)), ("faint ", sample(faint: true)),
             ("reverse ", sample(reverse: true))],
        ]

        for (index, runs) in samples.enumerated() {
            let baseline = bounds.height - inset - CGFloat(index + 1) * lineHeight + descent
            var x = inset
            for (text, attributes) in runs {
                let (foreground, background) = theme.resolve(attributes, reversed: false)
                let runFont = attributes.bold ? boldFont : self.font
                let attributed = NSAttributedString(string: text, attributes: [
                    .init(kCTFontAttributeName as String): runFont,
                    .init(kCTForegroundColorAttributeName as String): foreground,
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

                if let background {
                    ctx.setFillColor(background)
                    ctx.fill(CGRect(x: x, y: bounds.height - inset - CGFloat(index + 1) * lineHeight,
                                    width: width, height: lineHeight))
                }
                if attributes.underline != .none {
                    ctx.setFillColor(foreground)
                    ctx.fill(CGRect(x: x, y: bounds.height - inset - CGFloat(index + 1) * lineHeight + 1,
                                    width: width, height: 1))
                }

                ctx.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, ctx)
                x += width
            }
        }

        // The cursor, so its colour is part of the preview too.
        let cursorWidth = Fonts.advanceWidth(of: font)
        ctx.setFillColor(theme.cursor)
        ctx.fill(CGRect(x: inset,
                        y: bounds.height - inset - CGFloat(samples.count + 1) * lineHeight,
                        width: cursorWidth,
                        height: lineHeight))
    }

    private func sample(_ colour: Colour = .default,
                        bold: Bool = false,
                        faint: Bool = false,
                        reverse: Bool = false,
                        underline: UnderlineStyle = .none,
                        background: Colour = .default) -> Attributes {
        var attributes = Attributes()
        attributes.foreground = colour
        attributes.background = background
        attributes.bold = bold
        attributes.faint = faint
        attributes.inverse = reverse
        attributes.underline = underline
        return attributes
    }
}

// MARK: - Small helpers

private extension Array {
    /// A subscript that answers with nothing rather than trapping. Used for
    /// mapping a popup's index back to a value, where a stale index is a state
    /// the user can reach and a crash is not an acceptable answer.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
