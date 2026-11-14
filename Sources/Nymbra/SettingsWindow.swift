import AppKit
import CoreText
import Foundation
import NymbraCore
import NymbraInput

///
/// Every control writes one field of `Configuration` and hands the whole thing
/// back, which the application applies to the open terminals and then saves.
/// There is no state here that is not in the configuration — which is what stops
/// the window and the file from disagreeing, and what makes the preview real
/// rather than a mock-up.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSSearchFieldDelegate,
    NSWindowDelegate {

    var configuration: Configuration
    let onChange: (Configuration) -> Void

    let pageOrder = ["Appearance", "Keyboard", "Shell", "Behavior", "Advanced"]
    var pageViews: [String: NSView] = [:]
    var pageButtons: [String: NSButton] = [:]
    var keyboardRows: [Command: NSView] = [:]
    let pageHost = NSView()
    let pageHeading = NSTextField(labelWithString: "Appearance")
    let pageSubtitle = NSTextField(labelWithString: "Make your terminal comfortable to read.")
    let preview = PreviewView()
    let fontPopup = NSPopUpButton()
    let fontSizeField = NSTextField()
    let fontSizeStepper = NSStepper()
    let cursorSegments = NSSegmentedControl(labels: ["Block", "Bar", "Underline"],
                                                    trackingMode: .selectOne,
                                                    target: nil,
                                                    action: nil)
    let shortcutFilter = NSSearchField()
    let shortcutFilterEmpty = NSTextField(labelWithString: "No matching commands.")
    let blinkToggle = ToggleSwitch()
    let scrollbackField = NSTextField()
    let confirmToggle = ToggleSwitch()
    let shellPopup = NSPopUpButton()
    let shellPathField = NSTextField()
    let shellNote = NSTextField(labelWithString: "")
    let contrastLabel = NSTextField(labelWithString: "")
    // The gallery lives beside the colour controls rather than replacing them:
    // pick a preset with one click, then adjust individual colours freely.
    // A preset that arrives while overrides exist is "Modified" rather than
    // selected — the overrides are what the terminal actually shows.
    var gallery: [ThemeCardView] = []
    let galleryModifiedNote = NSTextField(labelWithString: "Modified — Revert to preset")
    let galleryRevertButton = NSButton(title: "Revert", target: nil, action: nil)
    var colourWells: [String: NSColorWell] = [:]
    var promptStyleCards: [String: NSButton] = [:]
    let promptApplyToggle = NSButton(checkboxWithTitle: "Apply in new zsh tabs",
                                             target: nil,
                                             action: nil)
    /// Called when the person asks for the chosen prompt in the tabs that are
    /// already open. Settings cannot reach the terminals itself, so the
    /// application installs this.
    var onApplyPrompt: ((Configuration) -> Void)?
    var shortcutFields: [Command: ShortcutCaptureButton] = [:]
    let shortcutWarning = NSTextField(labelWithString: "")
    var shortcutMonitor: Any?

    /// The command whose shortcut is being recorded, if one is.
    var recordingShortcut: Command?

    init(configuration: Configuration, onChange: @escaping (Configuration) -> Void) {
        self.configuration = configuration
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nymbra Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.094, green: 0.106, blue: 0.141, alpha: 1.0)  // #181b24
        window.minSize = NSSize(width: 880, height: 620)
        super.init(window: window)
        window.delegate = self

        let content = makeContent()
        window.contentView = content
        // The content view must take its size from the window, not from the
        // intrinsic size of the controls inside it. Without a definite width, an
        // equality chain through the header (leading + intrinsic + trailing)
        // lets Auto Layout collapse the window's content to a narrow "strip".
        if let guide = window.contentLayoutGuide as? NSLayoutGuide {
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                content.topAnchor.constraint(equalTo: guide.topAnchor),
                content.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            ])
        }
        reload(from: configuration)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    func makeContent() -> NSView {
        let panes: [(String, NSView)] = [
            ("Appearance", scrollable(appearancePane())),
            ("Keyboard", scrollable(keyboardPane())),
            ("Shell", scrollable(shellPane())),
            ("Behavior", scrollable(behaviourPane())),
            ("Advanced", scrollable(advancedPane())),
        ]
        pageViews = Dictionary(uniqueKeysWithValues: panes)

        // Sidebar: brand + navigation + bottom (version + settings file link)
        let brandMark = NSView()
        brandMark.wantsLayer = true
        brandMark.layer?.cornerRadius = 9
        brandMark.layer?.backgroundColor = NSColor(red: 0.106, green: 0.137, blue: 0.220, alpha: 1.0).cgColor  // #1b2338
        brandMark.layer?.borderWidth = 1
        brandMark.layer?.borderColor = NSColor(red: 0.169, green: 0.227, blue: 0.361, alpha: 1.0).cgColor  // #2b3a5c
        brandMark.layer?.shadowColor = NSColor.black.withAlphaComponent(0.025).cgColor
        brandMark.layer?.shadowOffset = CGSize(width: 0, height: 4)
        brandMark.layer?.shadowRadius = 14
        brandMark.layer?.shadowOpacity = 1
        brandMark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brandMark.widthAnchor.constraint(equalToConstant: 29),
            brandMark.heightAnchor.constraint(equalToConstant: 29),
        ])
        // Brand mark SVG: path m6 7 5 5-5 5 + rect at (14, 15.3) 4.5x2.3
        let brandMarkLayer = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6, y: 7))
        path.addLine(to: CGPoint(x: 11, y: 12))
        path.addLine(to: CGPoint(x: 6, y: 17))
        brandMarkLayer.path = path
        brandMarkLayer.strokeColor = NSColor(red: 0.431, green: 0.549, blue: 0.941, alpha: 1.0).cgColor  // #6e8cf0
        brandMarkLayer.lineWidth = 2.6
        brandMarkLayer.lineCap = .round
        brandMarkLayer.lineJoin = .round
        brandMarkLayer.fillColor = nil
        brandMarkLayer.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        brandMarkLayer.position = CGPoint(x: 14.5, y: 14.5)
        let rectLayer = CAShapeLayer()
        let rectPath = CGMutablePath()
        rectPath.addRoundedRect(in: CGRect(x: 14, y: 15.3, width: 4.5, height: 2.3), cornerWidth: 0.5, cornerHeight: 0.5)
        rectLayer.path = rectPath
        rectLayer.fillColor = NSColor(red: 0.851, green: 0.902, blue: 1.0, alpha: 1.0).cgColor  // #d9e6ff
        rectLayer.strokeColor = nil
        rectLayer.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        rectLayer.position = CGPoint(x: 14.5, y: 14.5)
        let svgContainer = CALayer()
        svgContainer.frame = CGRect(x: 0, y: 0, width: 29, height: 29)
        svgContainer.addSublayer(brandMarkLayer)
        svgContainer.addSublayer(rectLayer)
        brandMark.layer?.addSublayer(svgContainer)

        let brandName = NSTextField(labelWithString: "Nymbra")
        brandName.font = .systemFont(ofSize: 15, weight: .semibold)
        let brandCaption = NSTextField(labelWithString: "Settings")
        brandCaption.font = .systemFont(ofSize: 14)
        brandCaption.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3abbd
        let brandStack = NSStackView(views: [brandName, brandCaption])
        brandStack.orientation = .vertical
        brandStack.alignment = .leading
        brandStack.spacing = 1
        let brandRow = NSStackView(views: [brandMark, brandStack])
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 10

        let navLabel = sectionLabel("PREFERENCES")
        navLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let spacedTitle = NSAttributedString(string: "PREFERENCES", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(red: 0.596, green: 0.627, blue: 0.706, alpha: 1.0),  // #98a0b4
            .kern: 1.1,
        ])
        navLabel.attributedStringValue = spacedTitle

        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 3
        let navIcons = ["Appearance": "◐", "Keyboard": "⌘", "Shell": "›_", "Behavior": "◷", "Advanced": "⚙"]
        for title in pageOrder {
            let button = NavButton(icon: navIcons[title] ?? "", title: title,
                                   target: self, action: #selector(pageSelected(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(title)
            button.widthAnchor.constraint(equalToConstant: 180).isActive = true
            pageButtons[title] = button
            navigation.addArrangedSubview(button)
        }

        // Sidebar bottom: version + settings file link
        let versionLabel = NSTextField(labelWithString: "Nymbra · pre-alpha")
        versionLabel.font = .systemFont(ofSize: 14)
        versionLabel.textColor = NSColor(red: 0.612, green: 0.643, blue: 0.714, alpha: 1.0)  // #9ca4b6
        let settingsFileButton = NSButton(title: "Show settings file ↗", target: self, action: #selector(revealSettingsFile(_:)))
        settingsFileButton.bezelStyle = .inline
        settingsFileButton.isBordered = false
        settingsFileButton.contentTintColor = NSColor(red: 0.761, green: 0.788, blue: 0.855, alpha: 1.0)  // #c2c9da
        settingsFileButton.font = .systemFont(ofSize: 14)
        settingsFileButton.alignment = .left
        let sidebarBottom = NSStackView(views: [versionLabel, settingsFileButton])
        sidebarBottom.orientation = .vertical
        sidebarBottom.alignment = .leading
        sidebarBottom.spacing = 4
        sidebarBottom.translatesAutoresizingMaskIntoConstraints = false
        // Add top border to sidebarBottom
        let sidebarBottomBorder = NSBox()
        sidebarBottomBorder.boxType = .separator
        sidebarBottomBorder.translatesAutoresizingMaskIntoConstraints = false
        sidebarBottom.addSubview(sidebarBottomBorder, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            sidebarBottomBorder.leadingAnchor.constraint(equalTo: sidebarBottom.leadingAnchor),
            sidebarBottomBorder.trailingAnchor.constraint(equalTo: sidebarBottom.trailingAnchor),
            sidebarBottomBorder.topAnchor.constraint(equalTo: sidebarBottom.topAnchor),
            sidebarBottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])

        let sidebarSpacer = NSView()
        sidebarSpacer.translatesAutoresizingMaskIntoConstraints = false
        sidebarSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        let sidebar = NSStackView(views: [brandRow, navLabel, navigation, sidebarSpacer, sidebarBottom])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.distribution = .fill
        sidebar.spacing = 0
        sidebar.setCustomSpacing(22, after: brandRow)
        sidebar.setCustomSpacing(6, after: navLabel)
        sidebar.setCustomSpacing(0, after: navigation)
        sidebar.setCustomSpacing(0, after: sidebarSpacer)
        sidebar.edgeInsets = NSEdgeInsets(top: 20, left: 12, bottom: 12, right: 12)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(red: 0.082, green: 0.094, blue: 0.125, alpha: 1.0).cgColor  // #151820
        sidebarBottom.widthAnchor.constraint(equalToConstant: 180).isActive = true
        // Right border on sidebar
        let sidebarRightBorder = NSBox()
        sidebarRightBorder.boxType = .separator
        sidebarRightBorder.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarRightBorder, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            sidebarRightBorder.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarRightBorder.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarRightBorder.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarRightBorder.widthAnchor.constraint(equalToConstant: 1),
        ])
        sidebarRightBorder.boxType = .separator

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

        pageHeading.font = .systemFont(ofSize: 20, weight: .semibold)
        pageHeading.attributedStringValue = NSAttributedString(
            string: "Appearance",
            attributes: [.kern: -0.38]
        )
        pageSubtitle.font = .systemFont(ofSize: 14)
        pageSubtitle.textColor = NSColor(red: 0.573, green: 0.600, blue: 0.667, alpha: 1.0)  // #9299aa
        let heading = NSStackView(views: [pageHeading, pageSubtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        heading.translatesAutoresizingMaskIntoConstraints = false

        // Settings head close button (×)
        let settingsCloseButton = CloseButton(title: "×", target: self, action: #selector(done(_:)))
        settingsCloseButton.bezelStyle = .inline
        settingsCloseButton.isBordered = false
        settingsCloseButton.font = .systemFont(ofSize: 17, weight: .medium)
        settingsCloseButton.contentTintColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
        settingsCloseButton.toolTip = "Close settings"
        settingsCloseButton.translatesAutoresizingMaskIntoConstraints = false
        settingsCloseButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        settingsCloseButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let headingWithClose = NSStackView(views: [heading, settingsCloseButton])
        headingWithClose.orientation = .horizontal
        headingWithClose.distribution = .fill
        headingWithClose.spacing = 8
        headingWithClose.translatesAutoresizingMaskIntoConstraints = false

        // Footer: save status + Reset + Done (primary)
        let saveStatus = NSTextField(labelWithString: "● Changes apply immediately")
        saveStatus.font = .systemFont(ofSize: 14)
        saveStatus.textColor = NSColor(red: 0.471, green: 0.859, blue: 0.631, alpha: 1.0)  // #78dba2 (--green)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        let resetFooterButton = FooterButton(title: "Reset…", target: self, action: #selector(resetAll(_:)), isPrimary: false)
        resetFooterButton.configureTitle("Reset…",
                                         font: .systemFont(ofSize: 14, weight: .medium),
                                         color: NSColor(red: 0.796, green: 0.816, blue: 0.863, alpha: 1.0))  // #cbd0dc
        resetFooterButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resetFooterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),
            resetFooterButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        let doneButton = FooterButton(title: "Done", target: self, action: #selector(done(_:)), isPrimary: true)
        doneButton.configureTitle("Done",
                                  font: .systemFont(ofSize: 14, weight: .semibold),
                                  color: NSColor(red: 0.090, green: 0.078, blue: 0.141, alpha: 1.0))  // #171424
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 66),
            doneButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        let footer = NSStackView(views: [saveStatus, footerSpacer, resetFooterButton, doneButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 9
        footer.translatesAutoresizingMaskIntoConstraints = false

        // A hairline above the footer, so the action row reads as a separate
        // surface from the scrolling page above it.
        let footerBorder = NSBox()
        footerBorder.boxType = .separator
        footerBorder.translatesAutoresizingMaskIntoConstraints = false

        let main = NSView()
        main.wantsLayer = true
        main.layer?.backgroundColor = NSColor(red: 0.094, green: 0.106, blue: 0.141, alpha: 1.0).cgColor  // #181b24
        main.addSubview(headingWithClose)
        main.addSubview(pageHost)
        main.addSubview(footerBorder)
        main.addSubview(footer)
        main.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(red: 0.094, green: 0.106, blue: 0.141, alpha: 1.0).cgColor  // #181b24
        root.addSubview(sidebar)
        root.addSubview(main)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 204),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            headingWithClose.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28),
            headingWithClose.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28),
            headingWithClose.topAnchor.constraint(equalTo: main.topAnchor, constant: 25),
            pageHost.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            pageHost.topAnchor.constraint(equalTo: headingWithClose.bottomAnchor, constant: 17),
            pageHost.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -11),
            footer.heightAnchor.constraint(equalToConstant: 32),
            footerBorder.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            footerBorder.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            footerBorder.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerBorder.heightAnchor.constraint(equalToConstant: 1),
        ])
        selectPage("Appearance")
        return root
    }

    @objc func pageSelected(_ sender: NSButton) {
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

    func selectPage(_ title: String) {
        for (name, view) in pageViews {
            view.isHidden = name != title
        }
        for (name, button) in pageButtons {
            let isActive = name == title
            if let navButton = button as? NavButton {
                navButton.setActive(isActive)
            } else {
                button.contentTintColor = isActive ? nymbraAccent : .secondaryLabelColor
            }
        }
        pageHeading.stringValue = title
        pageSubtitle.stringValue = Self.pageDescription(title)
    }

    static func pageDescription(_ title: String) -> String {
        switch title {
        case "Appearance": return "Make your terminal comfortable to read."
        case "Keyboard": return "Find commands and record shortcuts that work for you."
        case "Shell": return "Choose the shell used for new terminal sessions."
        case "Behavior": return "Tune your cursor, scrollback, and close warnings."
        case "Advanced": return "Fine-tune colours and manage your configuration."
        default: return ""
        }
    }

    static func pageIcon(_ title: String) -> String {
        switch title {
        case "Appearance": return "textformat"
        case "Keyboard": return "keyboard"
        case "Shell": return "terminal"
        case "Behavior": return "slider.horizontal.3"
        case "Advanced": return "paintpalette"
        default: return "circle"
        }
    }

    /// A pane wrapped so a small window scrolls instead of clipping, and a
    /// large window gives the extra space to the content.
    func scrollable(_ pane: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = pane
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // The pane stack is flipped, so it is laid out from the top down. It keeps
        // its own (intrinsic) height and simply scrolls when that is taller than
        // the clip view; it is deliberately *not* stretched to the clip view's
        // height, because stretching would spread the rows apart in a tall window.
        pane.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            pane.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            pane.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            pane.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    func paneStack() -> NSStackView {
        let stack = PaneStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    func row(_ text: String, _ control: NSView, hint: String? = nil) -> NSStackView {
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        let labelStack = NSStackView(views: [title])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 3
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let hint {
            let detail = NSTextField(labelWithString: hint)
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: 14)
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
    func addRow(_ title: String, control: NSView, hint: String? = nil,
                        to pane: NSStackView) -> NSStackView {
        let rowView = row(title, control, hint: hint)
        pane.addArrangedSubview(rowView)
        rowView.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true
        return rowView
    }

    func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 14)
        return field
    }

    func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 14)
        field.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3acc0
        return field
    }

    // A section heading with title and optional subtle description
    func sectionHeading(_ title: String, description: String? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor(red: 0.875, green: 0.890, blue: 0.929, alpha: 1.0)  // #dfe3ed
        if let description {
            let descLabel = NSTextField(labelWithString: description)
            descLabel.font = .systemFont(ofSize: 12, weight: .regular)
            descLabel.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3acc0
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [titleLabel, spacer, descLabel])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.distribution = .fill
            stack.spacing = 8
            return stack
        }
        return titleLabel
    }

    // A card container with border and background (like .preview-card in concept)
    func cardView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.094, alpha: 1.0).cgColor  // #0b0e18
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(red: 0.208, green: 0.231, blue: 0.294, alpha: 1.0).cgColor  // #353b4b
        view.layer?.cornerRadius = 9
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// A grid whose columns share the available width equally. `NSGridView` sizes
    /// its columns to the widest cell, which left the tiles huddled at the left
    /// with a gap at the right once the window was resized; equal-width rows fill
    /// the pane and stay aligned at every width.
    func equalWidthGrid(rows: [[NSView]], columns: Int, spacing: CGFloat = 10) -> NSStackView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .width
        grid.distribution = .fill
        grid.spacing = spacing
        grid.translatesAutoresizingMaskIntoConstraints = false

        for cells in rows {
            var padded = cells
            while padded.count < columns { padded.append(NSView()) }
            let row = NSStackView(views: padded)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = spacing
            row.translatesAutoresizingMaskIntoConstraints = false
            grid.addArrangedSubview(row)
            // A vertical stack does not stretch its rows on its own; the row is
            // anchored to the grid so every column shares the same width.
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        return grid
    }

    // An inline row with label + control, bottom border (like .inline-row in concept)
    func inlineRow(title: String, help: String? = nil, control: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 3
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = NSColor(red: 0.847, green: 0.863, blue: 0.902, alpha: 1.0)  // #d8dce6
        labelStack.addArrangedSubview(titleLabel)

        if let help {
            let helpLabel = NSTextField(labelWithString: help)
            helpLabel.font = .systemFont(ofSize: 14)
            helpLabel.textColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
            helpLabel.lineBreakMode = .byWordWrapping
            helpLabel.maximumNumberOfLines = 2
            helpLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labelStack.addArrangedSubview(helpLabel)
        }

        // The label takes whatever the control does not: it must not be pinned to
        // a fixed width, or a longer help line is truncated mid-word.
        labelStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addSubview(labelStack)
        // The control is placed by the row's constraints, so its autoresizing mask
        // must not also dictate a position (which would leave a segmented control
        // sitting under its own label instead of at the trailing edge).
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labelStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            labelStack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 6),
            labelStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6),
            labelStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            control.leadingAnchor.constraint(greaterThanOrEqualTo: labelStack.trailingAnchor, constant: 12),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        // Bottom border
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(border, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            border.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])

        return container
    }
}
