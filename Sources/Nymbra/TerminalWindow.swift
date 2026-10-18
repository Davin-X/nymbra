import AppKit
import Foundation
import NymbraCore
import UserNotifications

/// One window: a set of tabs, each with its own layout of panes.
///
/// The window owns the strip and the tabs. Only the focused tab's container view
/// is in the window hierarchy — the window swaps them as the person switches tabs.
/// Splits live inside a tab; a new tab gets a fresh full-window shell.
///
/// All shell spawning goes through `posix_spawn` (ADR-0007), so a second tab —
/// like a second window or a split — can be started after AppKit is running.
final class TerminalWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    let window: NSWindow
    /// The strip along the top: one chip per tab, drawn and laid out by us,
    /// because every property a tab has here — where it sits, its close button,
    /// its menu, its dot — is a thing `NSTabView` does not do.
    let tabBar: TabBarView
    /// The view the tabs take turns in. The tab in front's container fills it, so
    /// the terminal reaches the window's edges on three sides and the strip on the
    /// fourth.
    private let paneHost = NSView()
    private let contentView = NSView()
    private let findBar = NSVisualEffectView()
    private let findSearchField = NSSearchField()
    private let findCaseButton = NSButton()
    private let findWordButton = NSButton()
    private let findRegexButton = NSButton()
    private let findCountLabel = NSTextField(labelWithString: "0 matches")
    private let findPreviousButton = NSButton()
    private let findNextButton = NSButton()
    private let findCloseButton = NSButton()

    /// Every tab, by identity. The focused tab's container is the one in the
    /// window hierarchy.
    private var tabs: [TabID: TerminalTab] = [:]
    private(set) var focusedTab: TabID

    /// Tabs that have printed something since they were last in front.
    ///
    /// Kept by the window rather than by each tab, because "unread" is a claim
    /// about the person's attention: a tab is unread only relative to the one
    /// they are looking at, and only the window knows which that is.
    private var unread: Set<TabID> = []

    private static let firstTab = TabID(0)

    private var configuration: Configuration

    /// The next tab identity to hand out.
    private var nextTabID = TerminalWindow.firstTab.raw + 1

    private(set) var isClosed = false

    var onSpawnFailure: ((Error) -> Void)? {
        get { tabs[focusedTab]?.onSpawnFailure }
        set { tabs[focusedTab]?.onSpawnFailure = newValue }
    }

    /// The view the keyboard is in: what Copy, Paste and Select All act on.
    var focusedView: TermView? { tabs[focusedTab]?.focusedView }

    /// Delegate through to the focused tab, so `--split-test` and `--window-test`
    /// keep working unchanged: they address the window as if it had one layout.
    var container: PaneContainerView { tabs[focusedTab]!.container }
    var panes: [PaneID: Pane] { tabs[focusedTab]!.panes }
    var layout: PaneLayout { tabs[focusedTab]!.layout }
    var focusedPane: PaneID { tabs[focusedTab]!.focusedPane }

    init(configuration: Configuration) throws {
        self.configuration = configuration
        self.focusedTab = TerminalWindow.firstTab

        let frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        self.tabBar = TabBarView()
        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.delegate = self
        window.title = "Nymbra"
        window.contentView = contentView
        window.setContentSize(frame.size)
        window.center()
        window.isReleasedWhenClosed = false
        // A window that cannot be shrunk past a usable grid. Without a floor the
        // window goes down to nothing and the shell is told it has one column,
        // which then redraws every line it prints into a strip one character wide.
        window.contentMinSize = NSSize(width: 420, height: 260)

        contentView.addSubview(tabBar)
        contentView.addSubview(paneHost)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // The strip takes the top edge, and the terminal takes everything
            // below it — to the left, right and bottom edges of the window. A
            // terminal that sits inside a frame the strip drew around it is a
            // terminal with less room than the window has.
            tabBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 30),
            paneHost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            paneHost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            paneHost.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            paneHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
        ])
        configureFindBar()

        // A window that will not be a tab of somebody else's window. Nymbra's tabs
        // are inside it (see the note in `main.swift`); the system's would be a
        // second strip above the real one, with none of the tabs in it.
        window.tabbingMode = .disallowed

        // The strip is the point. Without it a tab is something that happens *to*
        // the window: ⌘T swaps one view for another and the only evidence is the
        // screen going blank for a moment, which reads as the window reloading.
        tabBar.onSelect = { [weak self] id in self?.selectTab(id) }
        tabBar.onClose = { [weak self] id in self?.closeTab(id) }
        tabBar.onAdd = { [weak self] in _ = self?.newTab() }
        tabBar.onReorder = { [weak self] id, index in self?.reorderTab(id, to: index) }
        tabBar.onMenu = { [weak self] id, point in self?.showTabMenu(for: id, at: point) }
        findSearchField.placeholderString = "Find in terminal"
        findSearchField.delegate = self

        let first = TerminalWindow.firstTab
        let tab = try TerminalTab(configuration: configuration)
        tabs[first] = tab
        attach(tab, id: first)
        // The window is laid out *before* the first tab is shown. A container
        // dropped into a host with no size is a terminal told it has no cells, and
        // a shell told that has nothing to draw into — the prompt survives, and
        // everything printed after it does not.
        contentView.layoutSubtreeIfNeeded()
        selectTab(first)
    }

    /// Put a tab in the strip and wire the back-reference.
    ///
    /// The `+` is not an item and needs no insertion: the strip draws it after the
    /// last chip, so a new tab goes at the end of the tabs and everything else
    /// follows.
    private func attach(_ tab: TerminalTab, id: TabID) {
        tab.host = self
        let strip = TabBarView.Tab(identifier: id, label: tab.displayName, content: tab.container)
        tab.stripItem = strip
        tabBar.insert(strip, at: tabBar.tabs.count)
    }

    // MARK: - Tab operations

    /// A new tab: a fresh full-window shell alongside the existing tabs.
    @discardableResult
    func newTab() -> Bool {
        let id = TabID(nextTabID)
        nextTabID += 1

        let tab: TerminalTab
        do {
            tab = try TerminalTab(configuration: configuration)
        } catch {
            onSpawnFailure?(error)
            return false
        }

        tabs[id] = tab
        attach(tab, id: id)
        // Selected through `selectTab` rather than the tab view directly: the
        // delegate callback is not guaranteed to run synchronously, and until it
        // does the focused tab is still the old one — so the new shell's first
        // prompt would arrive while this tab was still "in the back" and dot
        // itself, which would put a mark on the tab the person just opened.
        selectTab(id)
        return true
    }

    /// Close the focused tab. When it is the last one, the window closes.
    func closeFocusedTab() {
        guard let tab = tabs[focusedTab] else { return }
        // A running command ends with its pane, so it is asked about — from the
        // menu, from the strip, and from a divider drag's consequences alike.
        guard tab.confirmClose(what: "Close this tab?") else { return }
        removeTab(focusedTab)
    }

    private func removeTab(_ id: TabID) {
        guard let tab = tabs[id] else { return }
        for pane in tab.panes.values { pane.terminal.terminate() }
        // Where it sat, so the tab that was next to it comes forward: a strip that
        // always jumped to the first tab would move the person somewhere they were
        // not, every time they closed one.
        let position = tabIDs.firstIndex(of: id) ?? 0
        tabs.removeValue(forKey: id)
        // A closed tab cannot be unread. The identity is never reused, so this is
        // tidiness rather than correctness, but a set that only grows is a set
        // that eventually lies about its size.
        unread.remove(id)

        tabBar.remove(id)

        if tabs.isEmpty {
            window.performClose(nil)
        } else if focusedTab == id {
            // The tab that was next to it, or the last one left. Closing a tab the
            // person was *not* looking at leaves them where they were: the `×` on a
            // background tab closes that tab, it does not switch to it.
            let remaining = tabIDs
            selectTab(remaining[min(position, remaining.count - 1)])
        }
    }

    /// The tabs, in strip order.
    private var tabIDs: [TabID] {
        tabBar.tabs.map(\.identifier)
    }

    func reorderTab(_ id: TabID, to destinationIndex: Int) {
        guard tabs[id] != nil, tabIDs.count > 1,
              let current = tabIDs.firstIndex(of: id),
              current != destinationIndex else { return }
        let selected = focusedTab
        tabBar.move(id, to: destinationIndex)
        // The tab in front is the same tab it was: moving a tab changes the strip,
        // and nothing about which terminal the person is looking at.
        selectTab(selected)
    }

    func selectNextTab() {
        let ids = tabIDs
        guard ids.count > 1, let index = ids.firstIndex(of: focusedTab) else { return }
        selectTab(ids[(index + 1) % ids.count])
    }

    func selectPreviousTab() {
        let ids = tabIDs
        guard ids.count > 1, let index = ids.firstIndex(of: focusedTab) else { return }
        selectTab(ids[(index - 1 + ids.count) % ids.count])
    }

    func beginFind() {
        findBar.isHidden = false
        focusedView?.startFind(query: findSearchField.stringValue, options: findOptions)
        window.makeFirstResponder(findSearchField)
        findSearchField.selectText(nil)
        updateFindCount()
    }

    func cancelFind() {
        findSearchField.stringValue = ""
        focusedView?.endFind()
        findBar.isHidden = true
        window.makeFirstResponder(focusedView)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === findSearchField else { return }
        focusedView?.updateFind(query: field.stringValue, options: findOptions)
        updateFindCount()
    }

    /// Escape and Return arrive *here*, not in the field's own `keyDown`: while a
    /// field is being edited the first responder is the field's editor, an
    /// `NSTextView`, and the control itself never sees the key. Measured rather
    /// than assumed — a key event sent the way the application sends one reaches
    /// this method with `cancelOperation:` and `insertNewline:`, and never
    /// reaches a `keyDown` override on the field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelFind()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            findNext()
            return true
        default:
            return false
        }
    }

    func findNext() {
        focusedView?.findNext()
        updateFindCount()
    }

    func findPrevious() {
        focusedView?.findPrevious()
        updateFindCount()
    }

    private func updateFindCount() {
        findCountLabel.stringValue = focusedView?.findStatus ?? "0 matches"
        let hasMatches = focusedView?.findHasMatches ?? false
        findPreviousButton.isEnabled = hasMatches
        findNextButton.isEnabled = hasMatches
    }

    // MARK: - Reading the find bar back
    //
    // `--find-test` types into the bar, steps through matches, and escapes out of
    // it, then prints what the bar shows. These are the facts it asserts, and
    // they are the same values the bar draws.

    /// Whether the find bar is on screen.
    var findBarIsVisible: Bool { !findBar.isHidden }

    /// What the bar's count label says right now.
    var findStatusText: String { findCountLabel.stringValue }

    /// The query the bar is holding.
    var findQuery: String { findSearchField.stringValue }

    /// The three switches, as the bar shows them.
    var findOptionSummary: String {
        "case=\(findCaseButton.state == .on ? 1 : 0) "
            + "word=\(findWordButton.state == .on ? 1 : 0) "
            + "regex=\(findRegexButton.state == .on ? 1 : 0)"
    }

    /// The bar's own bounds, and where each of its controls sits inside them — all
    /// in the bar's coordinates. A control laid out past the edge of the bar is a
    /// control nobody can use, and Auto Layout clips it rather than complaining.
    var findBarBounds: NSRect { findBar.bounds }

    var findControlFrames: [NSRect] {
        [findSearchField, findCaseButton, findWordButton, findRegexButton,
         findCountLabel, findPreviousButton, findNextButton, findCloseButton].map { view in
            view.superview.map { $0.convert(view.frame, to: findBar) } ?? view.frame
        }
    }

    /// Which switch a proof wants to press.
    enum FindToggle {
        case matchCase, wholeWord, regex
    }

    /// Press a switch the way a click does — through the button's own action, so a
    /// switch that is not wired is a switch that never moves.
    func clickFindToggle(_ toggle: FindToggle) {
        switch toggle {
        case .matchCase: findCaseButton.performClick(nil)
        case .wholeWord: findWordButton.performClick(nil)
        case .regex: findRegexButton.performClick(nil)
        }
    }

    /// Put a query in the bar and search for it — what typing does, without the
    /// keystrokes. The keystroke path has its own proof, in the same test.
    func search(_ query: String) {
        findSearchField.stringValue = query
        focusedView?.updateFind(query: query, options: findOptions)
        updateFindCount()
    }

    private func synchronizeFindWithFocus() {
        guard !findBar.isHidden else { return }
        focusedView?.startFind(query: findSearchField.stringValue, options: findOptions)
        updateFindCount()
    }

    /// What the three switches say the search should be.
    ///
    /// Read from the buttons rather than kept beside them: two copies of "is match
    /// case on" is two answers, and the one the person can see has to be the one
    /// that is used.
    private var findOptions: FindOptions {
        FindOptions(matchCase: findCaseButton.state == .on,
                    wholeWord: findWordButton.state == .on,
                    regex: findRegexButton.state == .on)
    }

    /// A switch moved: re-run the search with it, and with the query as it stands.
    private func applyFindOptions() {
        focusedView?.updateFind(query: findSearchField.stringValue, options: findOptions)
        updateFindCount()
    }

    private func configureFindBar() {
        findBar.material = .hudWindow
        findBar.blendingMode = .withinWindow
        findBar.state = .active
        findBar.wantsLayer = true
        findBar.layer?.cornerRadius = 9
        findBar.layer?.borderWidth = 1
        findBar.layer?.borderColor = NSColor.separatorColor.cgColor
        findBar.layer?.masksToBounds = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true

        findSearchField.placeholderString = "Find in terminal output…"
        findSearchField.setAccessibilityLabel("Find in terminal output")
        findSearchField.translatesAutoresizingMaskIntoConstraints = false

        findCountLabel.font = .systemFont(ofSize: 10)
        findCountLabel.textColor = .secondaryLabelColor
        findCountLabel.alignment = .center
        findCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        findCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureFindButton(findPreviousButton, symbol: "chevron.up",
                            label: "Previous match", action: #selector(findPreviousClicked(_:)))
        configureFindButton(findNextButton, symbol: "chevron.down",
                            label: "Next match", action: #selector(findNextClicked(_:)))
        configureFindButton(findCloseButton, symbol: "xmark",
                            label: "Close search", action: #selector(findCloseClicked(_:)))

        // Three switches, in the order the concept puts them and the order the
        // question is asked in: how the text is compared, then what counts as a
        // boundary, then how the query is read.
        configureFindToggle(findCaseButton, title: "Aa", label: "Match case",
                            action: #selector(findCaseClicked(_:)))
        configureFindToggle(findWordButton, title: "W", label: "Match whole word",
                            action: #selector(findWordClicked(_:)))
        configureFindToggle(findRegexButton, title: ".*", label: "Use regular expression",
                            action: #selector(findRegexClicked(_:)))

        let controls = NSStackView(views: [
            findSearchField, findCaseButton, findWordButton, findRegexButton,
            findCountLabel, findPreviousButton, findNextButton, findCloseButton,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 5
        controls.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(controls)
        contentView.addSubview(findBar)
        let preferredWidth = findBar.widthAnchor.constraint(equalToConstant: 470)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: paneHost.topAnchor, constant: 12),
            findBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            preferredWidth,
            findBar.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            findBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            findBar.heightAnchor.constraint(equalToConstant: 44),
            controls.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 7),
            controls.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -7),
            controls.topAnchor.constraint(equalTo: findBar.topAnchor, constant: 6),
            controls.bottomAnchor.constraint(equalTo: findBar.bottomAnchor, constant: -6),
            findSearchField.heightAnchor.constraint(equalToConstant: 28),
            findCaseButton.widthAnchor.constraint(equalToConstant: 34),
            findWordButton.widthAnchor.constraint(equalToConstant: 30),
            findRegexButton.widthAnchor.constraint(equalToConstant: 34),
            findPreviousButton.widthAnchor.constraint(equalToConstant: 27),
            findNextButton.widthAnchor.constraint(equalToConstant: 27),
            findCloseButton.widthAnchor.constraint(equalToConstant: 27),
        ])
    }

    /// One of the bar's switches. A switch that is on stays in: `pushOnPushOff`
    /// is what makes the state the person can see the same state the search uses.
    private func configureFindToggle(_ button: NSButton, title: String,
                                     label: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.setButtonType(.pushOnPushOff)
        button.state = .off
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureFindButton(_ button: NSButton, symbol: String,
                                    label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func findPreviousClicked(_ sender: NSButton) {
        findPrevious()
    }

    @objc private func findNextClicked(_ sender: NSButton) {
        findNext()
    }

    @objc private func findCloseClicked(_ sender: NSButton) {
        cancelFind()
    }

    @objc private func findCaseClicked(_ sender: NSButton) {
        applyFindOptions()
    }

    @objc private func findWordClicked(_ sender: NSButton) {
        applyFindOptions()
    }

    @objc private func findRegexClicked(_ sender: NSButton) {
        applyFindOptions()
    }

    /// Bring a tab to the front: the strip, the content, the focus and the title.
    ///
    /// All four here rather than spread between a selection call and a delegate
    /// callback, because a callback that runs late shows the wrong tab — and there
    /// is no callback now: the strip tells the window, and this is what it says.
    func selectTab(_ id: TabID) {
        guard let tab = tabs[id] else { return }
        focusedTab = id
        markRead(id)
        tab.host = self
        tabBar.select(id)
        show(tab)
        window.makeFirstResponder(tab.focusedView)
        refreshTitle()
        synchronizeFindWithFocus()
    }

    /// Put one tab's container in the window, and take the others out.
    private func show(_ tab: TerminalTab) {
        guard tab.container.superview !== paneHost else { return }
        paneHost.subviews.forEach { $0.removeFromSuperview() }
        tab.container.frame = paneHost.bounds
        tab.container.autoresizingMask = [.width, .height]
        paneHost.addSubview(tab.container)
    }

    /// Close one tab, wherever it is in the strip.
    ///
    /// The close button on a chip closes *that* tab, which is the point of having
    /// one per tab: the person who clicks the `×` on a background tab does not
    /// want to be moved into it first.
    func closeTab(_ id: TabID) {
        guard let tab = tabs[id], tab.confirmClose(what: "Close this tab?") else { return }
        removeTab(id)
    }

    @discardableResult
    func split(_ axis: PaneLayout.Axis) -> Bool {
        tabs[focusedTab]?.split(axis) ?? false
    }

    func focus(_ pane: PaneID) {
        tabs[focusedTab]?.focus(pane)
    }

    func focusedPaneDidChange() {
        synchronizeFindWithFocus()
    }

    func focusNextPane() {
        tabs[focusedTab]?.focusNextPane()
    }

    func focusPreviousPane() {
        tabs[focusedTab]?.focusPreviousPane()
    }

    func focusPane(towards direction: PaneLayout.Direction) {
        tabs[focusedTab]?.focusPane(towards: direction)
    }

    @discardableResult
    func closeFocusedPane() -> Bool {
        tabs[focusedTab]?.closeFocusedPane() ?? false
    }

    @discardableResult
    func close(_ pane: PaneID) -> Bool {
        tabs[focusedTab]?.close(pane) ?? false
    }

    func moveDivider(_ divider: PaneLayout.Divider, to position: Double) {
        tabs[focusedTab]?.moveDivider(divider, to: position)
    }

    func apply(_ configuration: Configuration) {
        self.configuration = configuration
        for tab in tabs.values { tab.apply(configuration) }
    }

    // MARK: - Unread

    /// A tab printed something.
    ///
    /// Marked only when it is not the tab in front: output the person is watching
    /// is not news, and a dot on the tab they are reading is noise. The mark is
    /// cleared by looking at the tab, which is the same act as bringing it
    /// forward.
    func tabDidReceiveOutput(_ id: TabID) {
        guard id != focusedTab else { return }
        guard unread.insert(id).inserted else { return }
        updateLabel(for: id)
    }

    /// Whether a tab has printed something since it was last in front. The strip
    /// draws a dot for exactly this, and a name change repaints it, so it is a
    /// question about what the person has seen rather than about the shell.
    func isUnread(_ tab: TabID) -> Bool { unread.contains(tab) }

    /// Looking at a tab reads it.
    private func markRead(_ id: TabID) {
        guard unread.remove(id) != nil else { return }
        updateLabel(for: id)
    }

    /// The strip's label for one tab: its name, and a dot when it has printed
    /// something the person has not seen.
    ///
    /// The dot lives in the label rather than beside it because the label is what
    /// the chip draws, and one string that is both composed and drawn here cannot
    /// disagree with itself. A rename does not touch `unread`, so renaming cannot
    /// silently clear the mark.
    private func updateLabel(for id: TabID) {
        guard let tab = tabs[id] else { return }
        tab.stripItem?.label = unread.contains(id) ? "\(tab.displayName) •" : tab.displayName
    }

    /// Paint every tab's label.
    ///
    /// Cheap — a window has a handful of tabs — and cheaper to reason about than
    /// tracking which label moved: a label depends on the tab's name and on
    /// whether it is unread, and either can change without the other.
    private func updateAllLabels() {
        for id in tabs.keys { updateLabel(for: id) }
    }

    // MARK: - Commands that finish

    /// A command finished in one of this window's shells.
    ///
    /// The rules for whether anybody should hear about it belong to
    /// `CommandAttention` and are tested there. What is gathered here is the two
    /// facts the shell cannot know: whether the person was already looking, and
    /// what this tab is called. A shell that reports no marks never reaches this
    /// method at all.
    ///
    /// - Parameters:
    ///   - status: the exit status, when the shell reported one.
    ///   - seconds: how long the command took.
    func commandFinished(in id: TabID, status: Int32?, seconds: Double) {
        guard let tab = tabs[id] else { return }
        guard let announcement = CommandAttention.announcement(
            status: status,
            seconds: seconds,
            threshold: configuration.behaviour.notifyAfterSeconds,
            isWatched: isBeingWatched(id),
            subject: tab.displayName
        ) else { return }
        deliver(announcement, id)
    }

    /// Bring one of this window's tabs to the front, if it still has it.
    ///
    /// A notification outlives the tab it is about: a command can finish, and the
    /// tab be closed, before anybody gets round to clicking. So both answers are
    /// ordinary — what is *not* allowed is selecting a tab that is gone, which is
    /// why the id is checked here rather than left to the tab view.
    @discardableResult
    func focus(tab id: TabID) -> Bool {
        guard tabs[id] != nil else { return false }
        selectTab(id)
        return true
    }

    /// Whether this tab is one the person is looking at: the tab in front, in the
    /// key window, in the active application.
    ///
    /// Three questions rather than one, because each can be false on its own. A
    /// window can be in front of this application's other windows without being
    /// the key one; an application can be active with a *different* window key;
    /// and the person can be in another application entirely with this one
    /// visible behind it. Only all three together mean "they are watching this".
    private func isBeingWatched(_ id: TabID) -> Bool {
        id == focusedTab && window.isKeyWindow && NSApp.isActive
    }

    /// Where an announcement goes.
    ///
    /// The default posts a notification; a test replaces it. That seam exists
    /// because there is no other way to observe what was *decided*:
    /// `UNUserNotificationCenter.current()` does not return an error outside an
    /// application bundle, it **aborts** — an `NSInternalInconsistencyException`
    /// about `bundleProxyForCurrentProcess` — and `make check` runs the bare
    /// executable. A harness that could not see past that line would have to test
    /// the rule indirectly or not at all.
    var deliver: (CommandAttention.Announcement, TabID) -> Void = TerminalWindow.post

    /// Post a notification, if this process is allowed to have one. Main thread
    /// only, which is where the marks are delivered.
    static func post(_ announcement: CommandAttention.Announcement, for id: TabID) {
        assert(Thread.isMainThread)
        // Not politeness — outside a bundle the call below does not fail, it
        // aborts. `swift run` and every headless test are outside one.
        guard Bundle.main.bundleIdentifier != nil else { return }

        let center = UNUserNotificationCenter.current()
        // Asked for once, because the permission prompt is a prompt: it belongs
        // at the first thing worth telling somebody about, not at launch, and
        // asking again every time would be noise. `sound` is requested so the
        // option exists in System Settings, but nothing here plays one — a
        // terminal that beeps at a finished build is a terminal people turn off.
        if !askedToNotify {
            askedToNotify = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        // Unique per announcement so that two finished builds are two
        // notifications rather than one that replaces the other.
        let request = UNNotificationRequest(
            identifier: "nymbra.command.\(id.raw).\(UUID().uuidString)",
            content: content(for: announcement, tab: id),
            trigger: nil
        )
        center.add(request)
    }

    /// What a notification about a tab looks like, before it is posted.
    ///
    /// Built apart from `post` because the part a click depends on — the tab
    /// carried inside it — is then a value a test can hold and hand back, rather
    /// than one that exists only inside a notification nobody is going to click.
    static func content(for announcement: CommandAttention.Announcement,
                        tab: TabID) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = announcement.title
        content.body = announcement.body
        content.userInfo = NotificationPayload.userInfo(for: tab)
        return content
    }

    /// Whether this process has already asked for permission to notify. Main
    /// thread only; see `post`.
    private static var askedToNotify = false

    // MARK: - Tab context menu

    /// Offer the things that can be done to one tab.
    ///
    /// The question is about the tab that was clicked rather than the one in
    /// front: a person right-clicks a tab to act on that tab.
    private func showTabMenu(for id: TabID, at point: NSPoint) {
        guard tabs[id] != nil else { return }
        let menu = NSMenu()
        menu.addItem(tabMenuItem("Rename…", action: #selector(renameTabFromMenu(_:)), for: id))
        menu.addItem(.separator())
        menu.addItem(tabMenuItem("Close Tab", action: #selector(closeTabFromMenu(_:)), for: id))
        menu.addItem(tabMenuItem("Close Tabs to the Left", action: #selector(closeTabsLeftFromMenu(_:)), for: id))
        menu.addItem(tabMenuItem("Close Tabs to the Right", action: #selector(closeTabsRightFromMenu(_:)), for: id))
        menu.addItem(tabMenuItem("Close Other Tabs", action: #selector(closeOtherTabsFromMenu(_:)), for: id))
        menu.addItem(tabMenuItem("Close All Tabs", action: #selector(closeAllTabsFromMenu(_:)), for: id))

        // Where the click was, not the window's centre: a right-click on the
        // leftmost tab must not open a menu at the far right.
        menu.popUp(positioning: nil, at: point, in: tabBar)
    }

    private func tabMenuItem(_ title: String, action: Selector, for id: TabID) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.representedObject = id
        entry.target = self
        return entry
    }

    @objc private func renameTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? TabID, let tab = tabs[id] else { return }
        let prompt = NSAlert()
        prompt.messageText = "Name this tab"
        prompt.informativeText = "Leave it empty to go back to whatever the shell calls it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.customTitle ?? ""
        prompt.accessoryView = field
        prompt.addButton(withTitle: "Rename")
        prompt.addButton(withTitle: "Cancel")
        prompt.window.initialFirstResponder = field
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        tab.customTitle = field.stringValue.isEmpty ? nil : field.stringValue
    }

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? TabID else { return }
        closeTab(id)
    }

    @objc private func closeTabsLeftFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? TabID,
              let position = tabIDs.firstIndex(of: id) else { return }
        closeTabs(Array(tabIDs[..<position]))
    }

    @objc private func closeTabsRightFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? TabID,
              let position = tabIDs.firstIndex(of: id) else { return }
        closeTabs(Array(tabIDs[(position + 1)...]))
    }

    @objc private func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? TabID else { return }
        closeTabs(tabIDs.filter { $0 != id })
    }

    @objc private func closeAllTabsFromMenu(_ sender: NSMenuItem) {
        closeTabs(tabIDs)
    }

    /// Close more than one tab at once.
    ///
    /// The set is the whole API; the menus only decide which one they mean. Each
    /// tab with something still running is asked about, and cancelling stops the
    /// whole thing rather than closing the ones after the refused one.
    @discardableResult
    func closeTabs(_ targets: [TabID]) -> Bool {
        for id in targets {
            guard let tab = tabs[id], tab.confirmClose(what: "Close this tab?") else { return false }
        }
        for id in targets { removeTab(id) }
        return true
    }

    // MARK: - The window itself

    func makeKeyAndOrderFront() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(focusedView)
    }

    /// The number of tabs the strip holds. The `+` is a button beside them rather
    /// than a tab, so it is not counted.
    var tabCount: Int { tabs.count }

    /// The area the tabs share, in the content view's coordinates. The terminal is
    /// as big as the window below the strip, and this is what says so.
    var paneHostFrame: NSRect { paneHost.frame }

    /// One tab's panes, by identity.
    ///
    /// A window's pane accessors all delegate to the tab in front, which is right
    /// for the person using it and useless for a test: the interesting question
    /// about a background tab is whether it is still itself, and that can only be
    /// asked of the tab that is not showing.
    func panes(in tab: TabID) -> [PaneID: Pane] {
        tabs[tab]?.panes ?? [:]
    }

    /// The window's title, taken from the tab that is in front.
    ///
    /// A tab calls this whenever anything changes its title — including a tab
    /// that is not the one showing — and it is this method's job to decide whose
    /// title that is. A background tab printing a new title must not move the
    /// window's out from under the person reading the tab they chose.
    func refreshTitle() {
        guard let tab = tabs[focusedTab], let pane = tab.panes[tab.focusedPane] else { return }
        // A shell that has gone says so, and only in the tab that is in front: the
        // notice is about what the person is looking at, not about a tab that
        // happened to finish something in the background.
        let title = pane.terminal.isRunning ? pane.title : "Nymbra \u{2014} shell exited"
        window.title = title.isEmpty ? "Nymbra" : title
        window.subtitle = tab.layout.count > 1 ? "\(tab.layout.count) panes" : ""
        updateAllLabels()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window closes every tab in it, so every tab's running
        // command is ended by it. The question is asked once for the window
        // rather than once per tab, because the person is closing one thing —
        // and the count is of commands, not of tabs holding them.
        let running = tabs.values.flatMap { $0.runningJobs }.count
        guard configuration.behaviour.confirmBeforeClosingRunningSession,
              running > 0 else { return true }
        return confirm(what: "Close this window?",
                       detail: running == 1
                           ? "A command is still running. Closing the window ends it."
                           : "\(running) commands are still running. Closing the window ends them.")
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        for tab in tabs.values {
            for pane in tab.panes.values { pane.terminal.terminate() }
        }
    }
}
