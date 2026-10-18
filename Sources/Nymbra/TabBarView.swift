import AppKit

/// One tab's chip in the strip: the name, the dot when there is output nobody has
/// looked at, its own close button, and the selection, drag and right-click
/// behaviour that belongs to a tab rather than to the terminal inside it.
///
/// A chip exists because `NSTabViewItem` cannot do any of this. The stock strip
/// centres its items, has no close button, offers no menu per item, and gives no
/// way to ask where an item is — the three things the concept asks of a tab strip.
final class TabChipView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    /// The tab's name, exactly as the window composed it — including the dot, so
    /// that what is asserted is what is drawn.
    var title: String = "" {
        didSet {
            titleField.stringValue = title
            titleField.setAccessibilityLabel(title)
            needsLayout = true
        }
    }

    var isSelected = false {
        didSet {
            titleField.textColor = isSelected ? .labelColor : .secondaryLabelColor
            closeButton.isHidden = !(isSelected || hovered)
            needsDisplay = true
        }
    }

    /// A click on the chip itself. Selection happens on the way down, because that
    /// is what a tab does: the person should not have to release to see it.
    var onSelect: (() -> Void)?
    /// The chip was released at a point in its own coordinates: a drag, which the
    /// strip turns into a move.
    var onDrop: ((NSPoint) -> Void)?
    /// A right-click, at a point in the chip's own coordinates.
    var onMenu: ((NSPoint) -> Void)?
    /// The close button was pressed.
    var onClose: (() -> Void)?

    private var hovered = false {
        didSet {
            closeButton.isHidden = !(isSelected || hovered)
            needsDisplay = true
        }
    }

    private var tracking: NSTrackingArea?

    /// How wide this chip wants to be: its name, plus room for the close button,
    /// clamped so that one long title cannot take the whole strip.
    var desiredWidth: CGFloat {
        let text = titleField.intrinsicContentSize.width
        return min(max(text + 54, TabBarView.chipMinimumWidth), TabBarView.chipMaximumWidth)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        titleField.font = .systemFont(ofSize: 12)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor,
                                                 constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The name of the tab, as a person would say it, for the accessibility tree.
    func describe(as name: String) {
        setAccessibilityLabel("Tab \(name)")
        closeButton.setAccessibilityLabel("Close \(name)")
    }

    /// Press the close button the way a click does — through the button's own
    /// action, so a close button that is not wired is one that never fires.
    func pressClose() { closeButton.performClick(nil) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }

    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func mouseUp(with event: NSEvent) {
        onDrop?(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(convert(event.locationInWindow, from: nil))
    }

    @objc private func closePressed(_ sender: NSButton) {
        onClose?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = isSelected
        guard selected || hovered else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 5, yRadius: 5)
        let fill = NSColor.controlBackgroundColor
        (selected ? fill : fill.withAlphaComponent(0.4)).setFill()
        path.fill()
        if selected {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// The strip along the top of a window: one chip per tab, laid out from the left,
/// and a `+` that follows the last of them.
///
/// Laid out by hand rather than by a stack view, because the order and the place
/// of every chip is the whole of what this view is: tabs read left to right in the
/// order they were opened, the `+` is always the last thing in the row rather than
/// floating in the middle, and a drag from one chip to another changes the order
/// without changing anything else. That also makes every one of those facts
/// checkable from the frames — no screenshot required.
final class TabBarView: NSVisualEffectView {
    /// One tab as the strip holds it: what it is called, the view to show when it
    /// is in front, and the chip that represents it.
    final class Tab {
        let identifier: TabID
        /// What the tab's content would be — the container that holds its panes.
        let content: NSView
        fileprivate let chip = TabChipView()

        init(identifier: TabID, label: String, content: NSView) {
            self.identifier = identifier
            self.content = content
            chip.title = label
            chip.describe(as: label)
        }

        /// The label as drawn, dot included. Read off the chip so the strip cannot
        /// say one thing and draw another.
        var label: String {
            get { chip.title }
            set {
                chip.title = newValue
                chip.describe(as: newValue)
            }
        }
    }

    static let chipMinimumWidth: CGFloat = 40
    static let chipMaximumWidth: CGFloat = 220
    private static let chipGap: CGFloat = 4
    private static let leadingInset: CGFloat = 8
    private static let plusWidth: CGFloat = 26

    private(set) var tabs: [Tab] = []
    /// The item in the strip that is not a tab. It is a button and never a
    /// selection: pressing it makes a tab instead of showing one.
    let plusButton = NSButton()

    private(set) var selectedID: TabID?

    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onAdd: (() -> Void)?
    var onReorder: ((TabID, Int) -> Void)?
    var onMenu: ((TabID, NSPoint) -> Void)?

    init() {
        super.init(frame: .zero)
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityLabel("Tabs")

        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        plusButton.imagePosition = .imageOnly
        plusButton.isBordered = false
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.refusesFirstResponder = true
        plusButton.target = self
        plusButton.action = #selector(addPressed(_:))
        plusButton.toolTip = "New tab"
        addSubview(plusButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - The tabs in it

    func tab(_ id: TabID) -> Tab? {
        tabs.first { $0.identifier == id }
    }

    /// Put a tab in the strip at `index`, as a chip and as an entry.
    func insert(_ tab: Tab, at index: Int) {
        let place = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: place)
        tab.chip.onSelect = { [weak self] in self?.selectAndTell(tab.identifier) }
        tab.chip.onDrop = { [weak self] point in
            guard let self else { return }
            let barPoint = tab.chip.convert(point, to: self)
            self.onReorder?(tab.identifier, self.insertionIndex(for: barPoint.x))
        }
        tab.chip.onMenu = { [weak self] point in
            guard let self else { return }
            self.onMenu?(tab.identifier, tab.chip.convert(point, to: self))
        }
        tab.chip.onClose = { [weak self] in self?.onClose?(tab.identifier) }
        addSubview(tab.chip, positioned: .below, relativeTo: plusButton)
        needsLayout = true
    }

    /// Take a tab out, and answer where it was.
    @discardableResult
    func remove(_ id: TabID) -> Int? {
        guard let index = tabs.firstIndex(where: { $0.identifier == id }) else { return nil }
        tabs[index].chip.removeFromSuperview()
        tabs.remove(at: index)
        if selectedID == id { selectedID = nil }
        needsLayout = true
        return index
    }

    /// Move a tab to a position, the way a drag does.
    func move(_ id: TabID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.identifier == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
        needsLayout = true
    }

    /// Bring a tab forward. The strip's own idea of the front is the selection,
    /// and it is set here so a chip's appearance cannot lag the content behind it.
    func select(_ id: TabID?) {
        selectedID = id
        for tab in tabs {
            tab.chip.isSelected = tab.identifier == id
        }
    }

    private func selectAndTell(_ id: TabID) {
        select(id)
        onSelect?(id)
    }

    /// Which position a drag released at `x` would insert before.
    private func insertionIndex(for x: CGFloat) -> Int {
        for (index, tab) in tabs.enumerated() where x < tab.chip.frame.midX {
            return index
        }
        return tabs.count
    }

    /// Press the `+`, and press one chip's close button, the way a click does —
    /// through the control's own action, so a `+` that is not wired, or a chip
    /// whose `×` is not, cannot pass a proof by looking right.
    func pressPlus() { plusButton.performClick(nil) }

    func pressClose(of id: TabID) { tab(id)?.chip.pressClose() }

    @objc private func addPressed(_ sender: NSButton) {
        onAdd?()
    }

    // MARK: - Where everything is

    /// Where each chip is, in the strip's coordinates, in tab order.
    var chipFrames: [NSRect] { tabs.map(\.chip.frame) }

    /// Where the `+` is.
    var plusFrame: NSRect { plusButton.frame }

    override func layout() {
        super.layout()
        let height = max(bounds.height - 8, 1)
        let y = (bounds.height - height) / 2

        // Squeezed to fit rather than allowed to run past the `+`: a strip that
        // pushed its own button off the edge would hide the one control that makes
        // another tab. Past the minimum the chips stop shrinking and are clipped by
        // the strip instead — a tab nobody can read is still a tab, and one that is
        // not drawn at all is not. See the roadmap's note on a scrolling strip.
        let available = bounds.width - TabBarView.leadingInset - TabBarView.plusWidth - 8
        let wanted = tabs.map(\.chip.desiredWidth)
        let total = wanted.reduce(0, +) + CGFloat(max(tabs.count - 1, 0)) * TabBarView.chipGap
        let squeeze = total > available && total > 0 ? available / total : 1

        var x = TabBarView.leadingInset
        for (index, tab) in tabs.enumerated() {
            let width = max(wanted[index] * squeeze, TabBarView.chipMinimumWidth)
            tab.chip.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + TabBarView.chipGap
        }

        // The `+` follows the last tab, and stays inside the strip even when the
        // tabs have filled it.
        let plusX = min(x + 2, bounds.width - TabBarView.plusWidth - 6)
        plusButton.frame = NSRect(x: max(plusX, TabBarView.leadingInset),
                                  y: y, width: TabBarView.plusWidth, height: height)
    }
}
