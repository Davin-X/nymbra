import AppKit

/// One tab's chip in the strip: the name, the dot when there is output nobody has
/// looked at, its own close button, and the selection, drag and right-click
/// behaviour that belongs to a tab rather than to the terminal inside it.
///
/// A chip exists because `NSTabViewItem` cannot do any of this. The stock strip
/// centres its items, has no close button, offers no menu per item, and gives no
/// way to ask where an item is — the three things the concept asks of a tab strip.
final class TabChipView: NSView {
    private let iconField = NSTextField(labelWithString: "›_")
    private let titleField = NSTextField(labelWithString: "")
    private let unreadDot = NSView()
    private let closeButton = NSButton()

    /// Whether this tab has output the person has not seen. Drives the dot
    /// beside the name; the label keeps its own mark for compatibility.
    var isUnread: Bool = false {
        didSet { unreadDot.isHidden = !isUnread; needsDisplay = true }
    }

    /// The tab's name, exactly as the window composed it — including the dot, so
    /// that what is asserted is what is drawn.
    var title: String = "" {
        didSet {
            titleField.stringValue = title
            titleField.setAccessibilityLabel(title)
            // A truncated name is still a name a person can read in full by
            // hovering, rather than a guess.
            toolTip = title
            titleField.toolTip = title
            needsLayout = true
        }
    }

    var isSelected = false {
        didSet {
            titleField.textColor = isSelected ? .labelColor : .secondaryLabelColor
            closeButton.isHidden = !(isSelected || hovered)
            closeButton.contentTintColor = (isSelected || hovered) ? .labelColor : .secondaryLabelColor
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
            closeButton.contentTintColor = (isSelected || hovered) ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    private var tracking: NSTrackingArea?

    /// How wide this chip wants to be: its name, plus room for the close button,
    /// clamped so that one long title cannot take the whole strip.
    var desiredWidth: CGFloat {
        let text = titleField.intrinsicContentSize.width
        let icon = iconField.intrinsicContentSize.width
        return min(max(text + icon + 76, TabBarView.chipMinimumWidth), TabBarView.chipMaximumWidth)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        iconField.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        iconField.textColor = .tertiaryLabelColor
        iconField.translatesAutoresizingMaskIntoConstraints = false
        iconField.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(iconField)

        titleField.font = .systemFont(ofSize: 13)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        unreadDot.wantsLayer = true
        unreadDot.layer?.backgroundColor = NSColor.systemYellow.cgColor
        unreadDot.layer?.cornerRadius = 3
        unreadDot.isHidden = true
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(unreadDot)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
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
            iconField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: iconField.trailingAnchor, constant: 4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: unreadDot.leadingAnchor,
                                                 constant: -4),
            unreadDot.widthAnchor.constraint(equalToConstant: 6),
            unreadDot.heightAnchor.constraint(equalToConstant: 6),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            unreadDot.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
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
        // A middle click closes the tab under the pointer, the way a browser
        // does: the `×` is the obvious control, but the wheel click is the one
        // a person's hand is already on when they are tidying up.
        if event.buttonNumber == 2 {
            onClose?()
            return
        }
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
/// When there are more tabs than fit, the strip scrolls horizontally. The `+`
/// button stays fixed at the right edge so it is always reachable.
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
        var isUnread: Bool {
            get { chip.isUnread }
            set { chip.isUnread = newValue }
        }

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
    private static let plusWidth: CGFloat = 30
    private static let scrollViewHeight: CGFloat = 28  // height of the scrollable chip area

    private(set) var tabs: [Tab] = []
    /// The item in the strip that is not a tab. It is a button and never a
    /// selection: pressing it makes a tab instead of showing one.
    let plusButton = NSButton()

    // Scroll view for horizontal scrolling of chips
    private let scrollView = NSScrollView()
    private let chipContainer = NSView()

    // Fixed tab count, so a crowded strip still says how many tabs are open.
    private let tabCounterLabel = NSTextField(labelWithString: "0 tabs")
    private var scrollViewTrailingConstraint: NSLayoutConstraint!

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
        // Don't clip the whole view — we clip via the scroll view
        layer?.masksToBounds = false
        setAccessibilityLabel("Tabs")

        // Configure scroll view for horizontal scrolling
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScroller = NSScroller()
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = chipContainer
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Chip container holds the tab chips
        chipContainer.translatesAutoresizingMaskIntoConstraints = false
        chipContainer.wantsLayer = true

        // Plus button fixed at the right edge
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))

        // Tab counter: fixed, so it is not scrolled away with the chips.
        tabCounterLabel.font = .systemFont(ofSize: 10, weight: .medium)
        tabCounterLabel.textColor = .secondaryLabelColor
        tabCounterLabel.alignment = .center
        tabCounterLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabCounterLabel)
        plusButton.imagePosition = .imageOnly
        plusButton.isBordered = false
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.refusesFirstResponder = true
        plusButton.target = self
        plusButton.action = #selector(addPressed(_:))
        plusButton.toolTip = "New tab"
        addSubview(plusButton)

        // Layout constraints
        scrollViewTrailingConstraint = scrollView.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -(TabBarView.plusWidth + 52))
        NSLayoutConstraint.activate([
            // Scroll view fills the strip vertically, takes the width minus the
            // plus button and the tab counter.
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TabBarView.leadingInset),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollViewTrailingConstraint,

            // Chip container: fixed height, leading/top aligned to the content view.
            chipContainer.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            chipContainer.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            chipContainer.heightAnchor.constraint(equalToConstant: TabBarView.scrollViewHeight),

            // Plus button fixed at right edge
            plusButton.widthAnchor.constraint(equalToConstant: TabBarView.plusWidth),
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Trackpad/mouse wheel scrolling - on macOS the scroll view handles this natively
        // The NSScrollView with autohidesScrollers and horizontalScroller handles trackpad
        // scrolling automatically. No gesture recognizer needed.
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
        updateTabCounter()
        tab.chip.onSelect = { [weak self] in self?.selectAndTell(tab.identifier) }
        tab.chip.onDrop = { [weak self] point in
            guard let self else { return }
            let barPoint = tab.chip.convert(point, to: self.chipContainer)
            self.onReorder?(tab.identifier, self.insertionIndex(for: barPoint.x))
        }
        tab.chip.onMenu = { [weak self] point in
            guard let self else { return }
            self.onMenu?(tab.identifier, tab.chip.convert(point, to: self))
        }
        tab.chip.onClose = { [weak self] in self?.onClose?(tab.identifier) }
        chipContainer.addSubview(tab.chip, positioned: .below, relativeTo: nil)
        needsLayout = true
    }

    /// Take a tab out, and answer where it was.
    @discardableResult
    func remove(_ id: TabID) -> Int? {
        guard let index = tabs.firstIndex(where: { $0.identifier == id }) else { return nil }
        tabs[index].chip.removeFromSuperview()
        tabs.remove(at: index)
        if selectedID == id { selectedID = nil }
        updateTabCounter()
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
    ///
    /// The chips live in the chipContainer, which is the scroll view's documentView.
    /// We convert their frames from the chipContainer's coordinate space to the
    /// TabBarView's coordinate space so that tests (and drag/drop) work with the
    /// strip's own coordinates.
    var chipFrames: [NSRect] {
        tabs.map { tab in
            let frameInContainer = tab.chip.frame
            return chipContainer.convert(frameInContainer, to: self)
        }
    }

    /// Where the `+` is.
    var plusFrame: NSRect { plusButton.frame }

    /// Where the tab counter is.
    var tabCounterFrame: NSRect { tabCounterLabel.frame }

    private func updateTabCounter() {
        let count = tabs.count
        tabCounterLabel.stringValue = count == 1 ? "1 tab" : "\(count) tabs"
        needsLayout = true
    }

    override func layout() {
        // Leave room for the counter between the scroll view and the plus button.
        let counterWidth = max(tabCounterLabel.intrinsicContentSize.width + 10, 44)
        scrollViewTrailingConstraint.constant = -(TabBarView.plusWidth + counterWidth + 12)

        super.layout()
        let y: CGFloat = 1

        // Layout chips in the container. The scroll view already provides the
        // leading inset, so chips start at x=0 within the container.
        let wanted = tabs.map(\.chip.desiredWidth)

        var x: CGFloat = 0
        for (index, tab) in tabs.enumerated() {
            let width = max(wanted[index], TabBarView.chipMinimumWidth)
            tab.chip.frame = NSRect(x: x, y: y, width: width, height: TabBarView.scrollViewHeight)
            x += width + TabBarView.chipGap
        }

        // Update chip container width to match content
        chipContainer.frame.size.width = max(x, chipContainer.bounds.width)

        // Position the plus button directly — its frame is set here rather than
        // via a height constraint because NSButton's intrinsic content size for
        // the "plus" symbol (31.5pt) conflicts with the 28pt strip height.
        plusButton.frame = NSRect(x: bounds.width - TabBarView.plusWidth - 6,
                                  y: 1,
                                  width: TabBarView.plusWidth,
                                  height: TabBarView.scrollViewHeight)

        // Position the tab counter just to the left of the plus button.
        let counterX = plusButton.frame.minX - counterWidth - 4
        tabCounterLabel.frame = NSRect(x: counterX, y: 1,
                                      width: counterWidth, height: TabBarView.scrollViewHeight)
    }

// MARK: - Scrolling
    // Trackpad and mouse wheel scrolling are handled natively by NSScrollView.
    // The horizontal scroller appears automatically when chips overflow.
}
