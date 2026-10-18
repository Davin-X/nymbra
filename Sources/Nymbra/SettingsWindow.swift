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
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSSearchFieldDelegate,
    NSWindowDelegate {

    private var configuration: Configuration
    private let onChange: (Configuration) -> Void

    private let pageOrder = ["Appearance", "Keyboard", "Shell", "Behaviour", "Advanced"]
    private var pageViews: [String: NSView] = [:]
    private var pageButtons: [String: NSButton] = [:]
    private var keyboardRows: [Command: NSView] = [:]
    private let pageHost = NSView()
    private let pageHeading = NSTextField(labelWithString: "Appearance")
    private let pageSubtitle = NSTextField(labelWithString: "Make your terminal comfortable to read.")
    private let preview = PreviewView()
    private let fontPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let cursorSegments = NSSegmentedControl(labels: ["Block", "Bar", "Underline"],
                                                    trackingMode: .selectOne,
                                                    target: nil,
                                                    action: nil)
    private let shortcutFilter = NSSearchField()
    private let shortcutFilterEmpty = NSTextField(labelWithString: "No matching commands.")
    private let blinkCheckbox = NSButton(checkboxWithTitle: "Blink the cursor", target: nil, action: nil)
    private let scrollbackField = NSTextField()
    private let confirmCheckbox = NSButton(
        checkboxWithTitle: "Ask before closing a window whose command is still running",
        target: nil, action: nil
    )
    private let shellPopup = NSPopUpButton()
    private let shellPathField = NSTextField()
    private let shellNote = NSTextField(labelWithString: "")
    private let contrastLabel = NSTextField(labelWithString: "")
    // The gallery lives beside the colour controls rather than replacing them:
    // pick a preset with one click, then adjust individual colours freely.
    // A preset that arrives while overrides exist is "Modified" rather than
    // selected — the overrides are what the terminal actually shows.
    private var gallery: [ThemeCardView] = []
    private let galleryModifiedNote = NSTextField(labelWithString: "Modified — Revert to preset")
    private let galleryRevertButton = NSButton(title: "Revert", target: nil, action: nil)
    private var colourWells: [String: NSColorWell] = [:]
    private var shortcutFields: [Command: ShortcutCaptureButton] = [:]
    private let shortcutWarning = NSTextField(labelWithString: "")
    private var shortcutMonitor: Any?

    init(configuration: Configuration, onChange: @escaping (Configuration) -> Void) {
        self.configuration = configuration
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nymbra Settings"
        window.minSize = NSSize(width: 840, height: 560)
        super.init(window: window)
        window.delegate = self

        let content = makeContent()
        window.contentView = content
        reload(from: configuration)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let panes: [(String, NSView)] = [
            ("Appearance", scrollable(appearancePane())),
            ("Keyboard", scrollable(keyboardPane())),
            ("Shell", scrollable(shellPane())),
            ("Behaviour", scrollable(behaviourPane())),
            ("Advanced", scrollable(advancedPane())),
        ]
        pageViews = Dictionary(uniqueKeysWithValues: panes)

        let brand = NSTextField(labelWithString: "Nymbra\nSettings")
        brand.font = .boldSystemFont(ofSize: 15)
        brand.maximumNumberOfLines = 2
        brand.alignment = .left
        brand.translatesAutoresizingMaskIntoConstraints = false
        let logo = NSImageView(image: NSApp.applicationIconImage)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 36),
            logo.heightAnchor.constraint(equalToConstant: 36),
        ])
        let brandRow = NSStackView(views: [logo, brand])
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 8
        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 5
        for title in pageOrder {
            let button = NSButton(title: title, target: self, action: #selector(pageSelected(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(title)
            button.setButtonType(.toggle)
            button.bezelStyle = .rounded
            button.image = NSImage(systemSymbolName: Self.pageIcon(title), accessibilityDescription: title)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.contentTintColor = .secondaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 180).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            pageButtons[title] = button
            navigation.addArrangedSubview(button)
        }
        let sidebar = NSStackView(views: [brandRow, sectionLabel("PREFERENCES"), navigation])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 14
        sidebar.edgeInsets = NSEdgeInsets(top: 20, left: 12, bottom: 12, right: 12)
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        pageHost.translatesAutoresizingMaskIntoConstraints = false
        for title in pageOrder {
            guard let view = pageViews[title] else { continue }
            pageHost.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: pageHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
            ])
            view.isHidden = true
        }

        pageHeading.font = .boldSystemFont(ofSize: 19)
        pageSubtitle.font = .systemFont(ofSize: 11)
        pageSubtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [pageHeading, pageSubtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        heading.translatesAutoresizingMaskIntoConstraints = false

        let footerStatus = NSTextField(labelWithString: "Changes apply immediately")
        footerStatus.font = .systemFont(ofSize: 11)
        footerStatus.textColor = .secondaryLabelColor
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [footerStatus, footerSpacer, resetButton(), doneButton()])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let main = NSView()
        main.addSubview(heading)
        main.addSubview(pageHost)
        main.addSubview(footer)
        main.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(sidebar)
        root.addSubview(separator)
        root.addSubview(main)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 204),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            heading.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 26),
            heading.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -26),
            heading.topAnchor.constraint(equalTo: main.topAnchor, constant: 22),
            pageHost.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            pageHost.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            pageHost.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -14),
            footer.heightAnchor.constraint(equalToConstant: 32),
        ])
        selectPage("Appearance")
        return root
    }

    @objc private func pageSelected(_ sender: NSButton) {
        guard let title = sender.identifier?.rawValue else { return }
        selectPage(title)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === shortcutFilter else { return }
        let query = shortcutFilter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var visibleCount = 0
        for (command, row) in keyboardRows {
            let isVisible = query.isEmpty
                || command.title.localizedCaseInsensitiveContains(query)
                || command.explanation.localizedCaseInsensitiveContains(query)
            row.isHidden = !isVisible
            if isVisible { visibleCount += 1 }
        }
        shortcutFilterEmpty.isHidden = visibleCount > 0
    }

    private func selectPage(_ title: String) {
        for (name, view) in pageViews {
            view.isHidden = name != title
        }
        for (name, button) in pageButtons {
            button.state = name == title ? .on : .off
        }
        pageHeading.stringValue = title
        pageSubtitle.stringValue = Self.pageDescription(title)
    }

    private static func pageDescription(_ title: String) -> String {
        switch title {
        case "Appearance": return "Make your terminal comfortable to read."
        case "Keyboard": return "Find commands and record shortcuts that work for you."
        case "Shell": return "Choose the shell used for new terminal sessions."
        case "Behaviour": return "Tune your cursor, scrollback, and close warnings."
        case "Advanced": return "Fine-tune colours and manage your configuration."
        default: return ""
        }
    }

    private static func pageIcon(_ title: String) -> String {
        switch title {
        case "Appearance": return "textformat"
        case "Keyboard": return "keyboard"
        case "Shell": return "terminal"
        case "Behaviour": return "slider.horizontal.3"
        case "Advanced": return "paintpalette"
        default: return "circle"
        }
    }

    /// A pane wrapped so a small window scrolls instead of clipping, and a
    /// large window gives the extra space to the content.
    private func scrollable(_ pane: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = pane
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // The pane decides its own height; the scroll view shows as much as
        // the window allows.
        pane.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            pane.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            pane.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func paneStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func row(_ text: String, _ control: NSView, hint: String? = nil) -> NSStackView {
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let labelStack = NSStackView(views: [title])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 3
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let hint {
            let detail = NSTextField(labelWithString: hint)
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: 10)
            detail.lineBreakMode = .byWordWrapping
            detail.maximumNumberOfLines = 2
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labelStack.addArrangedSubview(detail)
        }

        let stack = NSStackView(views: [labelStack, control])
        stack.orientation = .horizontal
        stack.spacing = 16
        stack.alignment = .centerY
        stack.distribution = .fill
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @discardableResult
    private func addRow(_ title: String, control: NSView, hint: String? = nil,
                        to pane: NSStackView) -> NSStackView {
        let rowView = row(title, control, hint: hint)
        pane.addArrangedSubview(rowView)
        rowView.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true
        return rowView
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 13)
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

        pane.addArrangedSubview(sectionLabel("Live preview"))
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 170).isActive = true
        pane.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true
        pane.addArrangedSubview(caption("Uses the same palette and font as your terminal. Changes apply immediately."))

        pane.addArrangedSubview(sectionLabel("Font"))
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        addRow("Font family", control: fontPopup,
               hint: "Monospaced fonts available on this Mac", to: pane)

        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeTyped(_:))
        fontSizeField.alignment = .right
        fontSizeField.translatesAutoresizingMaskIntoConstraints = false
        fontSizeField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped(_:))
        fontSizeStepper.minValue = Configuration.Appearance.fontSizeRange.lowerBound
        fontSizeStepper.maxValue = Configuration.Appearance.fontSizeRange.upperBound
        fontSizeStepper.increment = 1
        let sizeControls = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeControls.orientation = .horizontal
        sizeControls.spacing = 6
        addRow("Font size", control: sizeControls, hint: "Adjust terminal text from 6 to 72 pt", to: pane)

        pane.addArrangedSubview(sectionLabel("Theme"))
        pane.addArrangedSubview(themeGalleryGrid())
        return pane
    }

    private func advancedPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionLabel("Colour overrides"))
        pane.addArrangedSubview(caption("Optional fine-tuning for the selected theme. Changes apply to every open terminal."))

        galleryModifiedNote.textColor = .secondaryLabelColor
        galleryModifiedNote.font = .systemFont(ofSize: 11)
        galleryModifiedNote.isHidden = true
        galleryRevertButton.target = self
        galleryRevertButton.action = #selector(revertColours(_:))
        galleryRevertButton.bezelStyle = .inline
        galleryRevertButton.isHidden = true
        let modifiedRow = NSStackView(views: [galleryModifiedNote, galleryRevertButton])
        modifiedRow.orientation = .horizontal
        modifiedRow.spacing = 8
        pane.addArrangedSubview(modifiedRow)

        pane.addArrangedSubview(sectionLabel("Palette"))
        let names = Palette.interfaceNames + Palette.ansiNames
        let grid = NSGridView(numberOfColumns: 4, rows: 0)
        grid.rowSpacing = 10
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
                    well.widthAnchor.constraint(equalToConstant: 64),
                    well.heightAnchor.constraint(equalToConstant: 26)
                ])
                colourWells[name] = well

                let cell = NSStackView(views: [well, caption(name)])
                cell.orientation = .vertical
                cell.alignment = .leading
                cell.spacing = 3
                cells.append(cell)
            }
            grid.addRow(with: cells)
        }
        pane.addArrangedSubview(grid)

        contrastLabel.font = .systemFont(ofSize: 11)
        contrastLabel.textColor = .secondaryLabelColor
        pane.addArrangedSubview(contrastLabel)
        pane.addArrangedSubview(sectionLabel("Configuration"))
        addRow("Settings file", control: revealButton(),
               hint: "Hand-editable JSON stored locally on this Mac", to: pane)
        return pane
    }

    /// A visual preset picker whose swatches use Nymbra's actual palette data.
    private func themeGalleryGrid() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        let intro = NSTextField(labelWithString: "Choose a palette, then customize colours under Advanced.")
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 11)
        container.addArrangedSubview(intro)

        gallery.removeAll()
        let grid = NSGridView(numberOfColumns: 4, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        var cells: [NSView] = []
        for preset in Configuration.Colours.Preset.allCases {
            let card = ThemeCardView(preset: preset, target: self, action: #selector(themeCardClicked(_:)))
            gallery.append(card)
            cells.append(card)
            if cells.count == 4 {
                grid.addRow(with: cells)
                cells.removeAll()
            }
        }
        if !cells.isEmpty { grid.addRow(with: cells) }
        container.addArrangedSubview(grid)
        return container
    }

    private func behaviourPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionLabel("Terminal behaviour"))
        cursorSegments.target = self
        cursorSegments.action = #selector(cursorShapeChanged(_:))
        cursorSegments.segmentStyle = .rounded
        for index in 0..<cursorSegments.segmentCount {
            cursorSegments.setWidth(74, forSegment: index)
        }
        addRow("Cursor shape", control: cursorSegments,
               hint: "Programs can temporarily change the cursor.", to: pane)

        blinkCheckbox.target = self
        blinkCheckbox.action = #selector(blinkChanged(_:))
        addRow("Blinking cursor", control: blinkCheckbox,
               hint: "Only blinks in the focused pane.", to: pane)

        scrollbackField.target = self
        scrollbackField.action = #selector(scrollbackTyped(_:))
        scrollbackField.alignment = .right
        scrollbackField.translatesAutoresizingMaskIntoConstraints = false
        scrollbackField.widthAnchor.constraint(equalToConstant: 84).isActive = true
        addRow("Scrollback", control: scrollbackField,
               hint: "Maximum history retained above the screen.", to: pane)

        confirmCheckbox.target = self
        confirmCheckbox.action = #selector(confirmChanged(_:))
        addRow("Confirm before closing", control: confirmCheckbox,
               hint: "Warn when a command is still running.", to: pane)
        return pane
    }

    private func keyboardPane() -> NSView {
        let pane = paneStack()
        pane.addArrangedSubview(sectionLabel("Application shortcuts"))
        pane.addArrangedSubview(caption("Click a shortcut and press a new combination. Other keys continue to your shell."))
        shortcutFilter.placeholderString = "Filter commands"
        shortcutFilter.sendsSearchStringImmediately = true
        shortcutFilter.delegate = self
        pane.addArrangedSubview(shortcutFilter)
        shortcutFilter.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true
        shortcutFilterEmpty.textColor = .secondaryLabelColor
        shortcutFilterEmpty.isHidden = true
        pane.addArrangedSubview(shortcutFilterEmpty)
        keyboardRows.removeAll()

        for (command, shortcut) in Command.bindings() {
            let field = ShortcutCaptureButton(title: shortcut?.display ?? "Record", target: self,
                                               action: #selector(shortcutRecordRequested(_:)))
            field.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            field.setAccessibilityLabel("\(command.title) shortcut")
            field.setAccessibilityHelp("Click, then press a modifier and key combination to record a shortcut.")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true
            shortcutFields[command] = field

            let restore = NSButton(title: "Default", target: self, action: #selector(shortcutRestoreDefault(_:)))
            restore.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            restore.controlSize = .small

            let controls = NSStackView(views: [field, restore])
            controls.orientation = .horizontal
            controls.spacing = 6
            keyboardRows[command] = addRow(command.title, control: controls,
                                           hint: command.explanation, to: pane)
        }

        shortcutWarning.font = .systemFont(ofSize: 11)
        pane.addArrangedSubview(shortcutWarning)
        return pane
    }

    private func shellPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionLabel("Default shell"))
        shellPopup.target = self
        shellPopup.action = #selector(shellChanged(_:))
        addRow("Detected shells", control: shellPopup,
               hint: "Choose a shell installed on this Mac.", to: pane)

        pane.addArrangedSubview(sectionLabel("Custom executable"))
        pane.addArrangedSubview(caption("For shells not listed above, enter an absolute path to the executable."))
        shellPathField.placeholderString = "/path/to/shell"
        shellPathField.translatesAutoresizingMaskIntoConstraints = false
        shellPathField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let useShellButton = NSButton(title: "Use Custom Shell", target: self,
                                      action: #selector(useCustomShell(_:)))
        let customControls = NSStackView(views: [shellPathField, useShellButton])
        customControls.orientation = .horizontal
        customControls.spacing = 8
        addRow("Executable path", control: customControls, to: pane)

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

    private func doneButton() -> NSButton {
        NSButton(title: "Done", target: self, action: #selector(done(_:)))
    }

    @objc private func done(_ sender: NSButton) {
        window?.close()
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

        let palette = Palette(preset: configuration.colours.preset,
                              overrides: configuration.colours.overrides)
        for (name, well) in colourWells {
            well.color = Self.nsColor(palette.colour(named: name) ?? palette.background)
        }
        updateContrast(palette)
        refreshGallery()

        cursorSegments.selectedSegment = Configuration.Behaviour.CursorShape.allCases
            .firstIndex(of: configuration.behaviour.cursorShape) ?? 0
        blinkCheckbox.state = configuration.behaviour.cursorBlinks ? .on : .off
        scrollbackField.integerValue = configuration.behaviour.scrollbackLines
        confirmCheckbox.state = configuration.behaviour.confirmBeforeClosingRunningSession ? .on : .off

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

    @objc private func themeCardClicked(_ sender: ThemeCardView) {
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

    @objc private func revertColours(_ sender: NSButton) {
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
    private func refreshGallery() {
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

    @objc private func colourChanged(_ sender: NSColorWell) {
        guard let name = sender.identifier?.rawValue, let colour = Self.rgb(from: sender.color) else { return }
        var updated = configuration
        updated.colours.overrides[name] = colour.hex
        apply(updated)
        refreshGallery()
    }

    // MARK: - Actions: behaviour

    @objc private func cursorShapeChanged(_ sender: NSSegmentedControl) {
        guard Configuration.Behaviour.CursorShape.allCases.indices.contains(sender.selectedSegment) else { return }
        var updated = configuration
        updated.behaviour.cursorShape =
            Configuration.Behaviour.CursorShape.allCases[sender.selectedSegment]
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

    @objc private func shortcutRecordRequested(_ sender: ShortcutCaptureButton) {
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

    @objc private func shortcutRestoreDefault(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let command = Command(rawValue: raw) else { return }
        stopShortcutRecording()
        var updated = configuration
        updated.keyboard.overrides.removeValue(forKey: command.rawValue)
        apply(updated)
        shortcutFields[command]?.title = Command.shortcut(for: command)?.display ?? "Record"
        shortcutWarning.stringValue = ""
    }

    private var recordingShortcut: Command?

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

    private func shortcut(from event: NSEvent) -> Shortcut? {
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

    private func stopShortcutRecording() {
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

    private func commitShortcut(_ shortcut: Shortcut, for command: Command, field: ShortcutCaptureButton) {
        var updated = configuration
        updated.keyboard.overrides[command.rawValue] = shortcut.text
        apply(updated)
        field.title = shortcut.display
        shortcutWarning.stringValue = ""
    }

    // MARK: - Actions: shell

    @objc private func shellChanged(_ sender: NSPopUpButton) {
        var updated = configuration
        updated.shell.path = shellChoices()[safe: sender.indexOfSelectedItem] ?? nil
        shellPathField.stringValue = updated.shell.path ?? ""
        shellNote.textColor = .secondaryLabelColor
        shellNote.stringValue = "Applies to new windows; a shell that is already running stays put."
        apply(updated)
    }

    @objc private func useCustomShell(_ sender: NSButton) {
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
        if let current = configuration.shell.path { paths.insert(current) }
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

    @objc private func revealSettingsFile(_ sender: Any?) {
        do {
            try configuration.save()
        } catch {
            showSettingsError("Could not save settings", error: error)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([Configuration.defaultURL])
    }

    private func showSettingsError(_ message: String, error: Error) {
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
            + "presets=\(Configuration.Colours.Preset.allCases.count)"
    }

    // MARK: - Conversions

    private static func title(_ preset: Configuration.Colours.Preset) -> String {
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

    // swiftlint:disable:next function_body_length
    // The preview draws a small document; the limit is for logic, not for this.
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
             ("reverse ", sample(reverse: true))]
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

private final class ShortcutCaptureButton: NSButton {}

private final class ThemeCardView: NSButton {
    enum SelectionState {
        case selected
        case modified
        case unselected
    }

    let preset: Configuration.Colours.Preset
    var selectionState: SelectionState = .unselected {
        didSet { needsDisplay = true }
    }

    init(preset: Configuration.Colours.Preset, target: AnyObject?, action: Selector?) {
        self.preset = preset
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel("\(preset.rawValue) theme")
        toolTip = "Use the \(preset.rawValue) theme"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 136),
            heightAnchor.constraint(equalToConstant: 76),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette(preset: preset, overrides: [:])
        let bounds = bounds.insetBy(dx: 1, dy: 1)
        let card = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        Self.nsColor(palette.background).setFill()
        card.fill()

        let border: NSColor
        switch selectionState {
        case .selected:
            border = .controlAccentColor
        case .modified:
            border = .systemOrange
        case .unselected:
            border = .separatorColor
        }
        border.setStroke()
        card.lineWidth = selectionState == .unselected ? 1 : 2
        card.stroke()

        let title = (preset == .highContrast ? "High contrast" : preset.rawValue.capitalized) as NSString
        title.draw(at: NSPoint(x: 12, y: bounds.maxY - 23), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Self.nsColor(palette.foreground),
        ])
        for (index, name) in ["red", "green", "yellow", "blue"].enumerated() {
            guard let colour = palette.colour(named: name) else { continue }
            let swatch = NSBezierPath(roundedRect: NSRect(
                x: 12 + CGFloat(index) * 27,
                y: bounds.minY + 12,
                width: 19,
                height: 9
            ), xRadius: 3, yRadius: 3)
            Self.nsColor(colour).setFill()
            swatch.fill()
        }
        if selectionState == .modified {
            let badge = "Modified" as NSString
            badge.draw(at: NSPoint(x: bounds.maxX - 64, y: bounds.minY + 11), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
    }

    private static func nsColor(_ rgb: Palette.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1)
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
