import AppKit
import NymbraCore
import NymbraInput

/// A searchable list of the commands Nymbra can perform.
final class CommandPaletteController: NSWindowController, NSTextFieldDelegate {
    private let commands: [Command]
    private let onSelect: (Command) -> Void
    private let searchField = PaletteSearchField()
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
        searchField.onMove = { [weak self] offset in self?.moveSelection(by: offset) }
        searchField.onChoose = { [weak self] in self?.chooseSelection() }
        searchField.onCancel = { [weak self] in self?.dismiss() }

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
        renderResults(matching: searchField.stringValue)
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
        for (index, command) in visibleCommands.enumerated() {
            let button = commandButton(command, index: index)
            results.addArrangedSubview(button)
        }
        updateSelection()
    }

    private func commandButton(_ command: Command, index: Int) -> NSButton {
        let shortcut = Command.shortcut(for: command, overrides: configuration.keyboard.overrides)
            .map { "  \($0.display)" } ?? ""
        let button = NSButton(title: "\(command.title)\(shortcut)", target: self,
                              action: #selector(commandClicked(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
        button.alignment = .left
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.tag = index
        button.toolTip = command.explanation
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalTo: results.widthAnchor).isActive = true
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
}

private final class PaletteSearchField: NSTextField {
    var onMove: ((Int) -> Void)?
    var onChoose: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126:
            onMove?(-1)
        case 125:
            onMove?(1)
        case 36, 76:
            onChoose?()
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}
