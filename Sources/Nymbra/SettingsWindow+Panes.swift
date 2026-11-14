import AppKit
import CoreText
import Foundation
import NymbraCore
import NymbraInput

// The settings window's panes: one builder per page of the sidebar.
extension SettingsWindowController {
    // MARK: - Panes

    func appearancePane() -> NSView {
        let pane = paneStack()

        // Live preview section with card
        pane.addArrangedSubview(sectionHeading("Live preview", description: "Uses the same palette and font as your terminal"))

        let previewCard = cardView()
        let previewStack = NSStackView()
        previewStack.orientation = .vertical
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(previewStack)
        NSLayoutConstraint.activate([
            previewStack.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor),
            previewStack.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor),
            previewStack.topAnchor.constraint(equalTo: previewCard.topAnchor),
            previewStack.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor),
        ])

        // Preview topline with traffic lights
        let topline = NSView()
        topline.translatesAutoresizingMaskIntoConstraints = false
        topline.heightAnchor.constraint(equalToConstant: 36).isActive = true
        topline.wantsLayer = true
        topline.layer?.borderWidth = 1
        topline.layer?.borderColor = NSColor(red: 0.153, green: 0.169, blue: 0.224, alpha: 1.0).cgColor  // #272b39
        for i in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = NSColor(red: 0.255, green: 0.275, blue: 0.329, alpha: 1.0).cgColor  // #414654
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            topline.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: topline.leadingAnchor, constant: 10 + CGFloat(i) * 10),
                dot.centerYAnchor.constraint(equalTo: topline.centerYAnchor),
            ])
        }
        let previewLabel = NSTextField(labelWithString: "~/src/nymbra — shell preview")
        previewLabel.font = .systemFont(ofSize: 14)
        previewLabel.textColor = NSColor(red: 0.537, green: 0.569, blue: 0.639, alpha: 1.0)  // #8991a3
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        topline.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: topline.leadingAnchor, constant: 46),
            previewLabel.centerYAnchor.constraint(equalTo: topline.centerYAnchor),
        ])
        previewStack.addArrangedSubview(topline)

        // Preview content - use the existing PreviewView but embedded
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewStack.addArrangedSubview(preview)

        pane.addArrangedSubview(previewCard)
        previewCard.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Font section
        pane.addArrangedSubview(sectionHeading("Font"))
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        fontPopup.translatesAutoresizingMaskIntoConstraints = false
        fontPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let fontRow = inlineRow(title: "Font family", help: "Monospaced fonts available on this Mac", control: fontPopup)
        pane.addArrangedSubview(fontRow)
        fontRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeTyped(_:))
        fontSizeField.alignment = .right
        fontSizeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        fontSizeField.textColor = NSColor(red: 0.875, green: 0.890, blue: 0.929, alpha: 1.0)  // #dfe3ec
        fontSizeField.isBordered = false
        fontSizeField.drawsBackground = false
        fontSizeField.focusRingType = .none
        fontSizeField.wantsLayer = true
        fontSizeField.layer?.cornerRadius = 6
        fontSizeField.layer?.borderWidth = 1
        fontSizeField.layer?.borderColor = NSColor(red: 0.216, green: 0.239, blue: 0.302, alpha: 1.0).cgColor  // #373d4d
        fontSizeField.layer?.backgroundColor = NSColor(red: 0.125, green: 0.141, blue: 0.188, alpha: 1.0).cgColor  // #202430
        fontSizeField.translatesAutoresizingMaskIntoConstraints = false
        fontSizeField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        fontSizeField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped(_:))
        fontSizeStepper.controlSize = .small
        fontSizeStepper.minValue = Configuration.Appearance.fontSizeRange.lowerBound
        fontSizeStepper.maxValue = Configuration.Appearance.fontSizeRange.upperBound
        fontSizeStepper.increment = 1
        let sizeControls = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeControls.orientation = .horizontal
        sizeControls.spacing = 6
        let sizeRow = inlineRow(title: "Font size", help: "Adjust terminal text from 6 to 72 pt", control: sizeControls)
        pane.addArrangedSubview(sizeRow)
        sizeRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Prompt style section
        pane.addArrangedSubview(sectionHeading("Prompt style",
                                                description: "Applied by Nymbra to new zsh tabs"))
        let promptGrid = promptStyleGrid()
        pane.addArrangedSubview(promptGrid)
        promptGrid.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Theme section
        pane.addArrangedSubview(sectionHeading("Theme", description: "Choose a palette; customize colours below"))
        let themeGrid = themeGalleryGrid()
        pane.addArrangedSubview(themeGrid)
        themeGrid.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Customize colours link
        let customizeRow = NSView()
        customizeRow.translatesAutoresizingMaskIntoConstraints = false
        customizeRow.wantsLayer = true
        customizeRow.layer?.borderWidth = 1
        customizeRow.layer?.borderColor = NSColor(red: 0.188, green: 0.212, blue: 0.275, alpha: 1.0).cgColor  // #303646
        customizeRow.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor  // #1d212c
        customizeRow.layer?.cornerRadius = 7
        let customizeStack = NSStackView()
        customizeStack.orientation = .horizontal
        customizeStack.distribution = .fill
        customizeStack.alignment = .centerY
        customizeStack.spacing = 12
        customizeStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        customizeStack.translatesAutoresizingMaskIntoConstraints = false
        customizeRow.addSubview(customizeStack)
        NSLayoutConstraint.activate([
            customizeStack.leadingAnchor.constraint(equalTo: customizeRow.leadingAnchor),
            customizeStack.trailingAnchor.constraint(equalTo: customizeRow.trailingAnchor),
            customizeStack.topAnchor.constraint(equalTo: customizeRow.topAnchor),
            customizeStack.bottomAnchor.constraint(equalTo: customizeRow.bottomAnchor),
        ])
        let customizeLabelStack = NSStackView()
        customizeLabelStack.orientation = .vertical
        customizeLabelStack.alignment = .leading
        customizeLabelStack.spacing = 2
        let customizeTitle = NSTextField(labelWithString: "Need more control?")
        customizeTitle.font = .systemFont(ofSize: 14, weight: .medium)
        customizeTitle.textColor = NSColor(red: 0.886, green: 0.898, blue: 0.929, alpha: 1.0)  // #e2e5ed
        let customizeHelp = NSTextField(labelWithString: "Adjust ANSI and interface colours individually.")
        customizeHelp.font = .systemFont(ofSize: 14)
        customizeHelp.textColor = NSColor(red: 0.553, green: 0.580, blue: 0.647, alpha: 1.0)  // #8d94a5
        customizeLabelStack.addArrangedSubview(customizeTitle)
        customizeLabelStack.addArrangedSubview(customizeHelp)
        let customizeButton = SmallButton(title: "Customize colours", target: self, action: #selector(selectAdvancedPage(_:)))
        customizeStack.addArrangedSubview(customizeLabelStack)
        customizeStack.addArrangedSubview(NSView()) // spacer
        customizeStack.addArrangedSubview(customizeButton)
        pane.addArrangedSubview(customizeRow)
        customizeRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        return pane
    }

    func advancedPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionHeading("Colour overrides", description: "Optional fine-tuning for the selected theme"))

        galleryModifiedNote.textColor = NSColor(red: 0.522, green: 0.553, blue: 0.620, alpha: 1.0)  // #858c9e
        galleryModifiedNote.font = .systemFont(ofSize: 14)
        galleryModifiedNote.isHidden = true
        galleryRevertButton.target = self
        galleryRevertButton.action = #selector(revertColours(_:))
        galleryRevertButton.bezelStyle = .inline
        galleryRevertButton.isHidden = true
        let modifiedRow = NSStackView(views: [galleryModifiedNote, galleryRevertButton])
        modifiedRow.orientation = .horizontal
        modifiedRow.spacing = 8
        pane.addArrangedSubview(modifiedRow)

        pane.addArrangedSubview(sectionHeading("Palette"))

        // Create a bordered container for the palette grid
        let paletteContainer = NSView()
        paletteContainer.wantsLayer = true
        paletteContainer.layer?.borderWidth = 1
        paletteContainer.layer?.borderColor = NSColor(red: 0.188, green: 0.212, blue: 0.275, alpha: 1.0).cgColor  // #303646
        paletteContainer.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor  // #1d212c
        paletteContainer.layer?.cornerRadius = 8
        paletteContainer.translatesAutoresizingMaskIntoConstraints = false

        let paletteGrid = NSGridView(numberOfColumns: 4, rows: 0)
        paletteGrid.rowSpacing = 10
        paletteGrid.columnSpacing = 16
        paletteGrid.translatesAutoresizingMaskIntoConstraints = false
        paletteContainer.addSubview(paletteGrid)
        NSLayoutConstraint.activate([
            paletteGrid.leadingAnchor.constraint(equalTo: paletteContainer.leadingAnchor, constant: 16),
            paletteGrid.trailingAnchor.constraint(equalTo: paletteContainer.trailingAnchor, constant: -16),
            paletteGrid.topAnchor.constraint(equalTo: paletteContainer.topAnchor, constant: 16),
            paletteGrid.bottomAnchor.constraint(equalTo: paletteContainer.bottomAnchor, constant: -16),
        ])

        let names = Palette.interfaceNames + Palette.ansiNames
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
            paletteGrid.addRow(with: cells)
        }

        pane.addArrangedSubview(paletteContainer)
        paletteContainer.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        contrastLabel.font = .systemFont(ofSize: 14)
        contrastLabel.textColor = .secondaryLabelColor
        pane.addArrangedSubview(contrastLabel)

        pane.addArrangedSubview(sectionHeading("Configuration"))

        let revealConfigButton = SmallButton(title: "Show file ↗", target: self, action: #selector(revealSettingsFile(_:)))

        let revealRow = inlineRow(title: "Settings file", help: "Hand-editable JSON, stored locally on this Mac.", control: revealConfigButton)
        pane.addArrangedSubview(revealRow)
        revealRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        let resetButton = SmallButton(title: "Reset all…", target: self, action: #selector(resetAll(_:)))

        let resetRow = inlineRow(title: "Restore defaults", help: "Reset appearance, behavior, shortcuts, and shell.", control: resetButton)
        pane.addArrangedSubview(resetRow)
        resetRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        return pane
    }

    /// A visual preset picker whose swatches use Nymbra's actual palette data.
    func themeGalleryGrid() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 10

        gallery.removeAll()
        var rows: [[NSView]] = []
        var cells: [NSView] = []
        for preset in Configuration.Colours.Preset.allCases {
            let card = ThemeCardView(preset: preset, target: self, action: #selector(themeCardClicked(_:)))
            gallery.append(card)
            cells.append(card)
            if cells.count == 4 {
                rows.append(cells)
                cells.removeAll()
            }
        }
        if !cells.isEmpty { rows.append(cells) }
        let grid = equalWidthGrid(rows: rows, columns: 4, spacing: 8)
        container.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    func promptStyleGrid() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        promptApplyToggle.target = self
        promptApplyToggle.action = #selector(promptStyleApplyToggled(_:))
        promptApplyToggle.state = configuration.appearance.promptStyleApplied ? .on : .off
        promptApplyToggle.font = .systemFont(ofSize: 14, weight: .medium)
        promptApplyToggle.contentTintColor = NSColor(red: 0.749, green: 0.780, blue: 0.847, alpha: 1.0)  // #bfc7d8
        promptApplyToggle.toolTip = "Nymbra starts new zsh tabs with the selected prompt. "
            + "Shells that are already running keep the prompt they started with."
        container.addArrangedSubview(promptApplyToggle)

        var rows: [[NSView]] = []
        var cells: [NSView] = []
        promptStyleCards.removeAll()
        for style in PromptStyle.allCases {
            let id = style.rawValue
            let card = HoverCardButton()
            card.title = ""
            card.bezelStyle = .regularSquare
            card.isBordered = false
            card.wantsLayer = true
            card.layer?.cornerRadius = 10
            card.layer?.borderWidth = 1
            card.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor
            card.setButtonType(.momentaryChange)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.heightAnchor.constraint(equalToConstant: 100).isActive = true

            let cardStack = NSStackView()
            cardStack.orientation = .vertical
            cardStack.alignment = .leading
            cardStack.spacing = 4
            cardStack.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
            cardStack.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = NSTextField(labelWithString: style.title)
            nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
            nameLabel.textColor = NSColor(red: 0.886, green: 0.898, blue: 0.929, alpha: 1.0)  // #e2e5ed
            let descLabel = NSTextField(labelWithString: style.summary)
            descLabel.font = .systemFont(ofSize: 14)
            descLabel.textColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
            descLabel.maximumNumberOfLines = 2
            descLabel.lineBreakMode = .byWordWrapping
            let sampleLabel = NSTextField(labelWithString: "")
            sampleLabel.attributedStringValue = promptSample(style)
            sampleLabel.lineBreakMode = .byTruncatingTail
            sampleLabel.maximumNumberOfLines = 2
            sampleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            cardStack.addArrangedSubview(nameLabel)
            cardStack.addArrangedSubview(descLabel)
            cardStack.addArrangedSubview(sampleLabel)
            card.addSubview(cardStack)
            NSLayoutConstraint.activate([
                cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                cardStack.topAnchor.constraint(equalTo: card.topAnchor),
                cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            ])

            card.identifier = NSUserInterfaceItemIdentifier(id)
            card.target = self
            card.action = #selector(promptStyleSelected(_:))
            card.hoverChanged = { [weak self, weak card] in
                guard let self, let card else { return }
                self.stylePromptCard(card,
                                     selected: card.identifier?.rawValue == self.configuration.appearance.promptStyle)
            }
            promptStyleCards[id] = card
            stylePromptCard(card, selected: configuration.appearance.promptStyle == id)

            cells.append(card)
            if cells.count == 3 {
                rows.append(cells)
                cells.removeAll()
            }
        }
        if !cells.isEmpty { rows.append(cells) }

        let grid = equalWidthGrid(rows: rows, columns: 3, spacing: 10)
        container.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let applyNowButton = SmallButton(title: "Apply to current tab", target: self,
                                         action: #selector(applyPromptToCurrentTab(_:)))
        applyNowButton.font = .systemFont(ofSize: 11, weight: .medium)
        applyNowButton.contentTintColor = NSColor(red: 0.796, green: 0.816, blue: 0.863, alpha: 1.0)  // #cbd0dc
        let applyNowRow = NSStackView(views: [applyNowButton])
        applyNowRow.orientation = .horizontal
        applyNowRow.alignment = .leading
        container.addArrangedSubview(applyNowRow)

        let note = NSTextField(wrappingLabelWithString:
            "New zsh tabs wear the selected prompt. \"Apply to current tab\" sends it "
            + "to a shell that is sitting at its own prompt. Branch names come from git.")
        note.font = .systemFont(ofSize: 14)
        note.textColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        container.addArrangedSubview(note)

        return container
    }

    /// The text a gallery card shows for a style, drawn from the same model the
    /// preview draws from: a card that disagreed with the preview would be a
    /// preview of nothing. The runs keep their palette ink (and their filled
    /// block, where a Powerline-shaped prompt has one), so the card shows the
    /// style rather than a greyed-out description of it.
    func promptSample(_ style: PromptStyle) -> NSAttributedString {
        let regular = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let sample = NSMutableAttributedString()
        for (lineIndex, runs) in PreviewView.promptLines(style, palette: previewPalette).enumerated() {
            if lineIndex > 0 {
                sample.append(NSAttributedString(string: "\n", attributes: [.font: regular]))
            }
            for run in runs {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: run.bold ? bold : regular,
                    .foregroundColor: Self.nsColor(run.ink),
                ]
                if let paper = run.paper {
                    attributes[.backgroundColor] = Self.nsColor(paper)
                }
                sample.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return sample
    }

    /// The palette the preview and the gallery cards draw with.
    var previewPalette: Palette {
        Palette(preset: configuration.colours.preset, overrides: configuration.colours.overrides)
    }

    /// Paint a prompt-style card as chosen or not. The selected card carries the
    /// accent border the concept shows, so the current choice is never a guess.
    func stylePromptCard(_ card: NSButton, selected: Bool) {
        let hovered = (card as? HoverCardButton)?.isHovered ?? false
        let border: NSColor
        if selected {
            border = nymbraAccent
        } else if hovered {
            border = NSColor(red: 0.408, green: 0.376, blue: 0.514, alpha: 1.0)  // #686083
        } else {
            border = NSColor(red: 0.204, green: 0.224, blue: 0.286, alpha: 1.0)  // #343949
        }
        let background: NSColor
        if selected {
            background = NSColor(red: 0.153, green: 0.141, blue: 0.227, alpha: 1.0)  // #27243a
        } else if hovered {
            background = NSColor(red: 0.141, green: 0.157, blue: 0.216, alpha: 1.0)  // #242837
        } else {
            background = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0)  // #1d212c
        }
        card.layer?.borderColor = border.cgColor
        card.layer?.backgroundColor = background.cgColor
    }

    func behaviourPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionHeading("Terminal behavior", description: "Preferences apply to new and open terminals"))

        cursorSegments.target = self
        cursorSegments.action = #selector(cursorShapeChanged(_:))
        cursorSegments.segmentStyle = .rounded
        for index in 0..<cursorSegments.segmentCount {
            cursorSegments.setWidth(74, forSegment: index)
        }
        let cursorRow = inlineRow(title: "Cursor shape", help: "Programs can temporarily change the cursor.", control: cursorSegments)
        pane.addArrangedSubview(cursorRow)
        cursorRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        blinkToggle.target = self
        blinkToggle.action = #selector(blinkChanged(_:))
        blinkToggle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            blinkToggle.widthAnchor.constraint(equalToConstant: 31),
            blinkToggle.heightAnchor.constraint(equalToConstant: 18),
        ])
        let blinkRow = inlineRow(title: "Blinking cursor", help: "Only blinks in the focused pane.", control: blinkToggle)
        pane.addArrangedSubview(blinkRow)
        blinkRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        scrollbackField.target = self
        scrollbackField.action = #selector(scrollbackTyped(_:))
        scrollbackField.alignment = .right
        scrollbackField.translatesAutoresizingMaskIntoConstraints = false
        scrollbackField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let scrollbackRow = inlineRow(title: "Scrollback", help: "Maximum history retained above the screen.", control: scrollbackField)
        pane.addArrangedSubview(scrollbackRow)
        scrollbackRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        confirmToggle.target = self
        confirmToggle.action = #selector(confirmChanged(_:))
        confirmToggle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            confirmToggle.widthAnchor.constraint(equalToConstant: 31),
            confirmToggle.heightAnchor.constraint(equalToConstant: 18),
        ])
        let confirmRow = inlineRow(title: "Confirm before closing", help: "Warn when a command is still running.", control: confirmToggle)
        pane.addArrangedSubview(confirmRow)
        confirmRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        return pane
    }

    func keyboardPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionHeading("Application shortcuts", description: "Click a shortcut and press a new combination. Other keys continue to your shell."))

        shortcutFilter.placeholderString = "⌕  Filter commands"
        shortcutFilter.sendsSearchStringImmediately = true
        shortcutFilter.delegate = self
        shortcutFilter.translatesAutoresizingMaskIntoConstraints = false
        shortcutFilter.wantsLayer = true
        shortcutFilter.layer?.cornerRadius = 6
        shortcutFilter.layer?.borderWidth = 1
        shortcutFilter.layer?.borderColor = NSColor(red: 0.204, green: 0.224, blue: 0.286, alpha: 1.0).cgColor  // #343949
        shortcutFilter.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor  // #1d212c
        shortcutFilter.cell?.backgroundStyle = .emphasized
        pane.addArrangedSubview(shortcutFilter)
        shortcutFilter.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        shortcutFilterEmpty.font = .systemFont(ofSize: 14)
        shortcutFilterEmpty.textColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
        shortcutFilterEmpty.isHidden = true
        pane.addArrangedSubview(shortcutFilterEmpty)

        keyboardRows.removeAll()

        // Create a bordered list container (like .shortcut-list in concept)
        let listContainer = NSView()
        listContainer.wantsLayer = true
        listContainer.layer?.borderWidth = 1
        listContainer.layer?.borderColor = NSColor(red: 0.188, green: 0.212, blue: 0.275, alpha: 1.0).cgColor  // #303646
        listContainer.layer?.cornerRadius = 8
        listContainer.translatesAutoresizingMaskIntoConstraints = false

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
        ])

        var first = true
        for (command, shortcut) in Command.bindings() {
            let field = ShortcutCaptureButton(title: shortcut?.display ?? "Record", target: self,
                                               action: #selector(shortcutRecordRequested(_:)))
            field.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            field.setAccessibilityLabel("\(command.title) shortcut")
            field.setAccessibilityHelp("Click, then press a modifier and key combination to record a shortcut.")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true
            shortcutFields[command] = field

            let restore = SmallButton(title: "Default", target: self, action: #selector(shortcutRestoreDefault(_:)))
            restore.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            restore.layer?.cornerRadius = 5

            let controls = NSStackView(views: [field, restore])
            controls.orientation = .horizontal
            controls.spacing = 6

            let rowView = NSView()
            rowView.translatesAutoresizingMaskIntoConstraints = false

            let infoStack = NSStackView()
            infoStack.orientation = .vertical
            infoStack.alignment = .leading
            infoStack.spacing = 2
            infoStack.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = NSTextField(labelWithString: command.title)
            nameLabel.font = .systemFont(ofSize: 14)
            nameLabel.textColor = NSColor(red: 0.886, green: 0.898, blue: 0.929, alpha: 1.0)  // #e2e5ed
            let descLabel = NSTextField(labelWithString: command.explanation)
            descLabel.font = .systemFont(ofSize: 14)
            descLabel.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3acc0
            infoStack.addArrangedSubview(nameLabel)
            infoStack.addArrangedSubview(descLabel)

            rowView.addSubview(infoStack)
            rowView.addSubview(controls)

            NSLayoutConstraint.activate([
                infoStack.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10),
                infoStack.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
                infoStack.widthAnchor.constraint(equalTo: rowView.widthAnchor, multiplier: 0.7),

                controls.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -10),
                controls.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),

                rowView.heightAnchor.constraint(equalToConstant: 43),
            ])

            // Add border separator
            if !first {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                listContainer.addSubview(separator, positioned: .below, relativeTo: listStack.arrangedSubviews.last!)
                NSLayoutConstraint.activate([
                    separator.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
                    separator.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
                    separator.topAnchor.constraint(equalTo: listStack.arrangedSubviews.last!.bottomAnchor),
                    separator.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
            first = false

            listStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            keyboardRows[command] = rowView
        }

        pane.addArrangedSubview(listContainer)
        listContainer.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        shortcutWarning.font = .systemFont(ofSize: 14)
        pane.addArrangedSubview(shortcutWarning)
        return pane
    }

    func shellPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionHeading("Default shell", description: "Applied to new tabs and windows"))

        shellPopup.target = self
        shellPopup.action = #selector(shellChanged(_:))
        shellPopup.translatesAutoresizingMaskIntoConstraints = false
        shellPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let shellRow = inlineRow(title: "Detected shells", help: "Choose a shell installed on this Mac", control: shellPopup)
        pane.addArrangedSubview(shellRow)
        shellRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        pane.addArrangedSubview(sectionHeading("Custom executable", description: "For shells not listed above, enter an absolute path to the executable."))

        shellPathField.placeholderString = "/opt/homebrew/bin/fish"
        shellPathField.translatesAutoresizingMaskIntoConstraints = false
        shellPathField.widthAnchor.constraint(equalToConstant: 210).isActive = true
        shellPathField.wantsLayer = true
        shellPathField.layer?.cornerRadius = 6
        shellPathField.layer?.borderWidth = 1
        shellPathField.layer?.borderColor = NSColor(red: 0.216, green: 0.239, blue: 0.302, alpha: 1.0).cgColor  // #373d4d
        shellPathField.layer?.backgroundColor = NSColor(red: 0.125, green: 0.141, blue: 0.188, alpha: 1.0).cgColor  // #202430
        shellPathField.font = .systemFont(ofSize: 14)
        shellPathField.textColor = NSColor(red: 0.875, green: 0.890, blue: 0.929, alpha: 1.0)  // #dfe3ec

        let validateButton = SmallButton(title: "Validate", target: self, action: #selector(useCustomShell(_:)))

        let pathStack = NSStackView(views: [shellPathField, validateButton])
        pathStack.orientation = .horizontal
        pathStack.spacing = 7
        pathStack.translatesAutoresizingMaskIntoConstraints = false

        let pathRow = inlineRow(title: "Executable path", help: "Absolute path to an executable file", control: pathStack)
        pane.addArrangedSubview(pathRow)
        pathRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Status row
        let statusRow = NSView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.wantsLayer = true
        statusRow.layer?.borderWidth = 1
        statusRow.layer?.borderColor = NSColor(red: 0.188, green: 0.212, blue: 0.275, alpha: 1.0).cgColor  // #303646
        statusRow.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor  // #1d212c
        statusRow.layer?.cornerRadius = 7

        let statusStack = NSStackView()
        statusStack.orientation = .horizontal
        statusStack.distribution = .fill
        statusStack.alignment = .centerY
        statusStack.spacing = 12
        statusStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor),
            statusStack.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor),
            statusStack.topAnchor.constraint(equalTo: statusRow.topAnchor),
            statusStack.bottomAnchor.constraint(equalTo: statusRow.bottomAnchor),
        ])

        let statusLabelStack = NSStackView()
        statusLabelStack.orientation = .vertical
        statusLabelStack.alignment = .leading
        statusLabelStack.spacing = 2
        let statusTitle = NSTextField(labelWithString: "Existing sessions won't be interrupted")
        statusTitle.font = .systemFont(ofSize: 13, weight: .medium)
        statusTitle.textColor = NSColor(red: 0.886, green: 0.898, blue: 0.929, alpha: 1.0)  // #e2e5ed
        let statusHelp = NSTextField(labelWithString: "The new shell is used next time you open a tab or window.")
        statusHelp.font = .systemFont(ofSize: 12)
        statusHelp.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3acc0
        statusLabelStack.addArrangedSubview(statusTitle)
        statusLabelStack.addArrangedSubview(statusHelp)

        let statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.backgroundColor = NSColor(red: 0.471, green: 0.859, blue: 0.631, alpha: 1.0).cgColor  // #78dba2
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        statusStack.addArrangedSubview(statusLabelStack)
        statusStack.addArrangedSubview(NSView()) // spacer
        statusStack.addArrangedSubview(statusDot)

        pane.addArrangedSubview(statusRow)
        // The status bar carries two lines of text; give it the full content
        // width rather than the narrower column the small rows use, so neither
        // line has to wrap into a cramped block.
        statusRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -20).isActive = true

        return pane
    }

    func resetButton() -> NSButton {
        NSButton(title: "Reset All Settings\u{2026}", target: self, action: #selector(resetAll(_:)))
    }

    func revealButton() -> NSButton {
        NSButton(title: "Show file ↗", target: self, action: #selector(revealSettingsFile(_:)))
    }

    func doneButton() -> NSButton {
        NSButton(title: "Done", target: self, action: #selector(done(_:)))
    }

    @objc func done(_ sender: NSButton) {
        window?.close()
    }
}
