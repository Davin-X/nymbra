import AppKit
import NymbraCore
import NymbraInput

/// A searchable list of the commands Nymbra can perform.
final class CommandPaletteController: NSWindowController, NSTextFieldDelegate {
    private let commands: [Command]
    private let onSelect: (Command) -> Void
    private let searchField = NSTextField()
    private let results = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private var configuration: Configuration
    private var visibleCommands: [Command] = []
    private var selectedIndex = 0
    private weak var parentWindow: NSWindow?

    init(commands: [Command], configuration: Configuration, onSelect: @escaping (Command) -> Void) {
        self.commands = commands
        self.configuration = configuration
        self.onSelect = onSelect

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Command Palette"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        super.init(window: panel)

        buildContent(in: panel)
        reload(configuration: configuration)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildContent(in panel: NSPanel) {
        searchField.placeholderString = "Search commands…"
        searchField.font = .systemFont(ofSize: 16)
        searchField.focusRingType = .default
        searchField.delegate = self

        results.orientation = .vertical
        results.alignment = .leading
        results.spacing = 2
        results.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = results
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.stringValue = "↑ ↓ to navigate  ·  Return to run  ·  Esc to close"
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let content = NSStackView(views: [searchField, scroll, hint])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            content.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            searchField.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            results.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    func reload(configuration: Configuration) {
        self.configuration = configuration
        renderResults(matching: searchField.stringValue)
    }

    func show(over parent: NSWindow?) {
        parentWindow = parent
        if let parent {
            let frame = parent.frame
            window?.setFrameOrigin(NSPoint(
                x: frame.midX - (window?.frame.width ?? 0) / 2,
                y: frame.midY - (window?.frame.height ?? 0) / 2
            ))
        } else {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateQuery(searchField.stringValue)
    }

    /// Show a query. Typing and a programmatic change both come through here, so
    /// there is one place that knows how a query becomes a list.
    func updateQuery(_ query: String) {
        searchField.stringValue = query
        // A new shortlist starts at its first row. Keeping the old index would
        // point the highlight at whatever slot happened to survive the filter.
        selectedIndex = 0
        renderResults(matching: query)
    }

    /// Arrows, Return and Escape arrive *here*, not in a text field's own
    /// `keyDown` — while a field is being edited the first responder is the
    /// field's editor, an `NSTextView`, and the control itself never sees the
    /// key. That is measured rather than assumed: a key event sent the way the
    /// application sends one reaches this method with `moveUp:`, `moveDown:`,
    /// `insertNewline:` and `cancelOperation:`, and never reaches a `keyDown`
    /// override on the field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    private func renderResults(matching query: String) {
        for view in results.arrangedSubviews {
            results.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleCommands = commands.filter { command in
            needle.isEmpty
                || command.title.localizedCaseInsensitiveContains(needle)
                || command.explanation.localizedCaseInsensitiveContains(needle)
        }
        selectedIndex = min(selectedIndex, max(visibleCommands.count - 1, 0))

        guard !visibleCommands.isEmpty else {
            let empty = NSTextField(labelWithString: "No matching commands")
            empty.textColor = .secondaryLabelColor
            results.addArrangedSubview(empty)
            hint.stringValue = "Try another command name"
            return
        }

        hint.stringValue = "↑ ↓ to navigate  ·  Return to run  ·  Esc to close"
        for command in visibleCommands {
            let button = commandButton(command)
            results.addArrangedSubview(button)
            // A row spans the list, so its highlight is a full-width bar and the
            // whole row is a click target. The constraint is made *here*, after
            // the button has a superview: between views with no common ancestor —
            // which is what a button and the stack are until it joins it — an
            // activated constraint throws, and the palette is built before it is
            // ever shown, so it would throw on the keystroke that opens it.
            button.widthAnchor.constraint(equalTo: results.widthAnchor).isActive = true
        }
        updateSelection()
    }

    /// The text of a row: the command's name, and the shortcut it answers to now.
    private func rowTitle(for command: Command) -> String {
        let shortcut = Command.shortcut(for: command, overrides: configuration.keyboard.overrides)
            .map { "  \($0.display)" } ?? ""
        return "\(command.title)\(shortcut)"
    }

    private func commandButton(_ command: Command) -> NSButton {
        let button = NSButton(title: rowTitle(for: command), target: self,
                              action: #selector(commandClicked(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
        button.alignment = .left
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.toolTip = command.explanation
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    @objc private func commandClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let command = Command(rawValue: raw) else { return }
        choose(command)
    }

    private func moveSelection(by offset: Int) {
        guard !visibleCommands.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + visibleCommands.count) % visibleCommands.count
        updateSelection()
    }

    private func updateSelection() {
        for (index, view) in results.arrangedSubviews.enumerated() {
            guard let button = view as? NSButton else { continue }
            button.state = index == selectedIndex ? .on : .off
            button.highlight(button.state == .on)
            if index == selectedIndex { button.scrollToVisible(button.bounds) }
        }
    }

    private func chooseSelection() {
        guard visibleCommands.indices.contains(selectedIndex) else { return }
        choose(visibleCommands[selectedIndex])
    }

    private func choose(_ command: Command) {
        dismiss()
        onSelect(command)
    }

    private func dismiss() {
        window?.orderOut(nil)
        parentWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Reading the palette back
    //
    // `--palette-test` drives the palette with real key events and prints what
    // came back. These are the facts it needs to see, and they are the same
    // values the palette draws — so a query that filters nothing, or a highlight
    // that does not move, is visible rather than merely invisible.

    /// The rows on screen, with their shortcut labels, in draw order.
    var visibleRows: [String] { visibleCommands.map(rowTitle(for:)) }

    /// What Return would run.
    var selectedCommand: Command? {
        visibleCommands.indices.contains(selectedIndex) ? visibleCommands[selectedIndex] : nil
    }

    /// Whether the panel is on screen. Escape has to be able to make this false.
    var isShowing: Bool { window?.isVisible == true }

    /// The query the search field is holding.
    var query: String { searchField.stringValue }
}
