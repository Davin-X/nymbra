import AppKit
import NymbraInput

/// The thin bar under the tabs: where the shell is on the left, what it is
/// doing on the right.
///
///     ⌂ › src › nymbra                    ● shell running · zsh · ⇧⌘P commands
///
/// It answers the two questions a terminal is otherwise silent about — "which
/// folder is this?" and "is something running in it?" — without the person
/// having to type `pwd` or look at the prompt. Clicking the path shows the
/// folder in Finder; clicking the hint opens the command palette.
final class PathBarView: NSView {

    enum Status: Equatable {
        /// The shell is at its prompt.
        case idle
        /// A program holds the foreground.
        case running(String)
        /// The shell has gone.
        case exited
    }

    static let height: CGFloat = 26

    var onRevealPath: ((String) -> Void)?
    var onCommandPalette: (() -> Void)?

    private let homeIcon = NSImageView()
    private let pathButton = NSButton()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let shellLabel = NSTextField(labelWithString: "")
    private let hintButton = NSButton()
    private let hairline = NSView()

    private var path: String?
    private var chrome: Theme.Chrome?
    private var crumbs: [String] = []
    private var status: Status = .idle

    /// What the bar says, for the proofs: the path as drawn and the status text.
    var pathText: String { pathButton.attributedTitle.string }
    var statusText: String { statusLabel.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Location")

        homeIcon.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Home")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        homeIcon.translatesAutoresizingMaskIntoConstraints = false

        pathButton.isBordered = false
        pathButton.title = ""
        pathButton.alignment = .left
        pathButton.lineBreakMode = .byTruncatingHead
        pathButton.target = self
        pathButton.action = #selector(pathPressed(_:))
        pathButton.toolTip = "Show in Finder"
        pathButton.refusesFirstResponder = true
        pathButton.translatesAutoresizingMaskIntoConstraints = false
        pathButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        for label in [statusLabel, shellLabel] {
            label.font = .systemFont(ofSize: 11)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        hintButton.isBordered = false
        hintButton.refusesFirstResponder = true
        hintButton.target = self
        hintButton.action = #selector(hintPressed(_:))
        hintButton.toolTip = "Command Palette"
        hintButton.translatesAutoresizingMaskIntoConstraints = false
        hintButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        hairline.wantsLayer = true
        hairline.translatesAutoresizingMaskIntoConstraints = false

        for view in [homeIcon, pathButton, statusDot, statusLabel, shellLabel, hintButton, hairline] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            homeIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            homeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathButton.leadingAnchor.constraint(equalTo: homeIcon.trailingAnchor, constant: 6),
            pathButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathButton.trailingAnchor.constraint(lessThanOrEqualTo: statusDot.leadingAnchor, constant: -16),

            hintButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hintButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            shellLabel.trailingAnchor.constraint(equalTo: hintButton.leadingAnchor, constant: -14),
            shellLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: shellLabel.leadingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Apply the window's chrome colours.
    func apply(_ chrome: Theme.Chrome) {
        self.chrome = chrome
        layer?.backgroundColor = chrome.background.cgColor
        hairline.layer?.backgroundColor = chrome.border.cgColor
        homeIcon.contentTintColor = chrome.tertiaryText
        shellLabel.textColor = chrome.tertiaryText
        render()
    }

    /// Say where the shell is and what it is doing.
    func update(path: String?, crumbs: [String], status: Status, shell: String, paletteShortcut: String?) {
        let hint = paletteShortcut.map { "\($0) commands" } ?? "Commands"
        guard path != self.path || crumbs != self.crumbs || status != self.status
                || shell != shellLabel.stringValue || hint != hintButton.title else { return }
        self.path = path
        self.crumbs = crumbs
        self.status = status
        shellLabel.stringValue = shell
        hintButton.title = hint
        render()
    }

    private func render() {
        guard let chrome else { return }
        // The path as the concept writes it — `⌂ › ~/src/nymbra` — with the
        // folder you are in in full ink and the way there in secondary ink.
        let title = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11)
        title.append(NSAttributedString(string: "›  ", attributes: [
            .font: font, .foregroundColor: chrome.tertiaryText]))
        if let last = crumbs.last {
            var lead = crumbs.dropLast().joined(separator: "/")
            if lead == "/" || lead.hasPrefix("//") { lead = String(lead.dropFirst()) }
            if !lead.isEmpty { lead += "/" }
            if crumbs.first == "/", crumbs.count == 2 { lead = "/" }
            title.append(NSAttributedString(string: lead, attributes: [
                .font: font, .foregroundColor: chrome.secondaryText]))
            title.append(NSAttributedString(string: last, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: chrome.text]))
        } else {
            title.append(NSAttributedString(string: "—", attributes: [
                .font: font, .foregroundColor: chrome.tertiaryText]))
        }
        pathButton.attributedTitle = title
        pathButton.isEnabled = path != nil
        homeIcon.image = NSImage(systemSymbolName: crumbs.first == "~" ? "house" : "internaldrive",
                                 accessibilityDescription: crumbs.first == "~" ? "Home" : "Disk")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        setAccessibilityValue(path)

        let (text, colour): (String, NSColor) = {
            switch status {
            case .idle: return ("shell running", chrome.positive)
            case .running(let program): return ("running \(program)", chrome.busy)
            case .exited: return ("shell exited", chrome.tertiaryText)
            }
        }()
        statusLabel.stringValue = text
        statusLabel.textColor = chrome.secondaryText
        statusDot.layer?.backgroundColor = colour.cgColor

        hintButton.attributedTitle = NSAttributedString(string: hintButton.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: chrome.tertiaryText])
    }

    @objc private func pathPressed(_ sender: NSButton) {
        if let path { onRevealPath?(path) }
    }

    @objc private func hintPressed(_ sender: NSButton) {
        onCommandPalette?()
    }
}
