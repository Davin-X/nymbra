import AppKit
import Foundation
import NymbraCore
import UserNotifications

/// One window: a set of tabs, each with its own layout of panes.
///
/// The window owns the tab view and the tabs. Only the focused tab's container
/// view is in the window hierarchy — NSTabView swaps them as the person switches
/// tabs. Splits live inside a tab; a new tab gets a fresh full-window shell.
///
/// All shell spawning goes through `posix_spawn` (ADR-0007), so a second tab —
/// like a second window or a split — can be started after AppKit is running.
final class TerminalWindow: NSObject, NSWindowDelegate, NSTabViewDelegate, NSToolbarDelegate,
    NSTextFieldDelegate, NSSearchFieldDelegate {
    let window: NSWindow
    let tabView: TabStripView
    private let findSearchField = FindSearchField()

    private enum ToolbarItemID {
        static let find = NSToolbarItem.Identifier("nymbra.find")
    }

    private final class FindSearchField: NSSearchField {
        var onCancel: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            super.keyDown(with: event)
        }
    }

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

    /// The item in the strip that is not a tab.
    ///
    /// A native strip is made of items and nothing else, so a `+` has to be one.
    /// It is never allowed to become the selected item — a click on it becomes a
    /// new tab and the new tab takes the selection — which is what keeps an empty
    /// page from ever being shown and the `+` from ever being a tab.
    private static let plusIdentifier = "nymbra.add-tab"

    /// The strip's `+`. Held by reference, because the delegate is asked about
    /// items by identity.
    private(set) var plusItem = NSTabViewItem(identifier: plusIdentifier)

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
        self.tabView = TabStripView(frame: frame)
        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.delegate = self
        window.title = "Nymbra"
        window.contentView = tabView
        window.setContentSize(frame.size)
        window.center()
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("nymbra.window-toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // A window that will not be a tab of somebody else's window. Nymbra's tabs
        // are inside it (see the note in `main.swift`); the system's would be a
        // second strip above the real one, with none of the tabs in it.
        window.tabbingMode = .disallowed

        tabView.delegate = self
        // The strip is the point. Without it a tab is something that happens *to*
        // the window: ⌘T swaps one view for another and the only evidence is the
        // screen going blank for a moment, which reads as the window reloading.
        //
        // The modern pair, rather than the deprecated `tabViewType`: tabs at the
        // top, with the content bevelled behind them.
        tabView.tabPosition = .top
        tabView.tabViewBorderType = .bezel
        tabView.plusItem = plusItem
        tabView.onTabRightClick = { [weak self] item in self?.showTabMenu(for: item) }
        tabView.onAddTab = { [weak self] in _ = self?.newTab() }
        tabView.onTabReorder = { [weak self] item, index in self?.reorderTab(item, to: index) }
        findSearchField.placeholderString = "Find in terminal"
        findSearchField.delegate = self
        findSearchField.onCancel = { [weak self] in self?.cancelFind() }
        findSearchField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            findSearchField.widthAnchor.constraint(equalToConstant: 240),
            findSearchField.heightAnchor.constraint(equalToConstant: 28),
        ])

        let first = TerminalWindow.firstTab
        let tab = try TerminalTab(configuration: configuration)
        tabs[first] = tab
        attach(tab, id: first)
        tabView.selectTabViewItem(at: 0)
        window.makeFirstResponder(tab.focusedView)

        // Last item in the strip, so every tab sits in front of it.
        plusItem.label = "+"
        plusItem.view = NSView()
        tabView.addTabViewItem(plusItem)
    }

    /// Add a tab's container view as an NSTabViewItem and wire the back-reference.
    ///
    /// The tab goes in front of the `+`, which is always the last item, so the
    /// strip reads left to right in the order the person opened them and ends with
    /// the thing that makes another one.
    private func attach(_ tab: TerminalTab, id: TabID) {
        tab.host = self
        let item = NSTabViewItem(identifier: id)
        item.label = tab.displayName
        item.view = tab.container
        tab.item = item
        let plus = tabView.tabViewItems.firstIndex(of: plusItem) ?? tabView.numberOfTabViewItems
        tabView.insertTabViewItem(item, at: plus)
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
        tabs.removeValue(forKey: id)
        // A closed tab cannot be unread. The identity is never reused, so this is
        // tidiness rather than correctness, but a set that only grows is a set
        // that eventually lies about its size.
        unread.remove(id)

        let index = tabView.indexOfTabViewItem(withIdentifier: id)
        if index >= 0 {
            tabView.removeTabViewItem(tabView.tabViewItems[index])
        }

        if !tabs.isEmpty {
            // The tab that was next to it, or the last one left — and never the `+`:
            // selecting that would make a tab when the person meant to see one.
            let remaining = tabIDs.filter { $0 != id }
            let position = (tabIDs.firstIndex(of: id) ?? 0)
            // The tab that comes forward is read on the way in, like any other
            // switch to it — and `selectTab` sets the focus itself, rather than
            // waiting for a delegate callback that may be late.
            selectTab(remaining[min(position, remaining.count - 1)])
        } else {
            window.performClose(nil)
        }
    }

    /// The real tabs, in strip order.
    ///
    /// The `+` is an item in the strip but not a tab, and counting it as one makes
    /// "next tab" land on the button that makes a tab — which then makes one,
    /// silently, when the person meant to switch.
    private var tabIDs: [TabID] {
        tabView.tabViewItems.compactMap { $0.identifier as? TabID }
    }

    private func reorderTab(_ item: NSTabViewItem, to destinationIndex: Int) {
        guard item !== plusItem, let id = item.identifier as? TabID else { return }
        reorderTab(id, to: destinationIndex)
    }

    func reorderTab(_ id: TabID, to destinationIndex: Int) {
        guard let item = tabs[id]?.item, tabIDs.count > 1 else { return }
        let currentIndex = tabView.indexOfTabViewItem(item)
        guard currentIndex >= 0, currentIndex != destinationIndex else { return }

        let selectedTab = focusedTab
        tabView.removeTabViewItem(item)
        let insertionIndex = min(max(destinationIndex, 0), tabIDs.count)
        tabView.insertTabViewItem(item, at: insertionIndex)
        selectTab(selectedTab)
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
        if window.toolbar?.items.contains(where: { $0.itemIdentifier == ToolbarItemID.find }) != true {
            window.toolbar?.insertItem(withItemIdentifier: ToolbarItemID.find, at: 0)
        }
        focusedView?.startFind(query: findSearchField.stringValue)
        window.makeFirstResponder(findSearchField)
        findSearchField.selectText(nil)
    }

    private func cancelFind() {
        findSearchField.stringValue = ""
        focusedView?.endFind()
        window.makeFirstResponder(focusedView)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === findSearchField else { return }
        focusedView?.updateFind(query: field.stringValue)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarItemID.find]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarItemID.find]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == ToolbarItemID.find else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Find"
        item.paletteLabel = "Find in Terminal"
        item.toolTip = "Search terminal output"
        item.view = findSearchField
        item.visibilityPriority = .high
        return item
    }

    /// Bring a tab to the front.
    ///
    /// The tab view's own selection is asked to do the same, but its delegate
    /// callback is not guaranteed to run synchronously, so the focus is set here
    /// first. A method that only sets the focus and waits for the callback is a
    /// method that shows the wrong tab when the callback is late.
    func selectTab(_ id: TabID) {
        focusedTab = id
        markRead(id)
        tabView.selectTabViewItem(withIdentifier: id)
    }

    @discardableResult
    func split(_ axis: PaneLayout.Axis) -> Bool {
        tabs[focusedTab]?.split(axis) ?? false
    }

    func focus(_ pane: PaneID) {
        tabs[focusedTab]?.focus(pane)
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

    // MARK: - NSTabViewDelegate

    func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        // The `+` is not a tab and never becomes one. Clicking it makes a tab
        // via the strip's mouseDown, so it is never selected: not by a click, and
        // not when the tab view tries to select it on its own as the last tab
        // closes, which would leave a new tab behind and the window open.
        tabViewItem !== plusItem
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let id = tabViewItem?.identifier as? TabID else { return }
        focusedTab = id
        markRead(id)
        tabs[id]?.host = self
        window.makeFirstResponder(tabs[id]?.focusedView)
        // The title belongs to the tab in front of the person, which is not
        // necessarily the tab that last printed something.
        refreshTitle()
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
    /// The dot lives in the label rather than beside it because the strip is a
    /// plain `NSTabView` and its label is the one piece of a tab it lets us
    /// paint. Composing it here — and only here — is what keeps a rename from
    /// silently clearing the mark.
    private func updateLabel(for id: TabID) {
        guard let tab = tabs[id] else { return }
        tab.item?.label = unread.contains(id) ? "\(tab.displayName) •" : tab.displayName
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
    /// NSTabView has no menu of its own and no way to ask for one per item, so
    /// the strip is asked directly, and the question is about the tab that was
    /// clicked rather than the one in front — a person right-clicks a tab to act
    /// on that tab.
    private func showTabMenu(for item: NSTabViewItem) {
        let menu = NSMenu()
        menu.addItem(tabMenuItem("Rename…", action: #selector(renameTabFromMenu(_:)), for: item))
        menu.addItem(.separator())
        menu.addItem(tabMenuItem("Close Tab", action: #selector(closeTabFromMenu(_:)), for: item))
        menu.addItem(tabMenuItem("Close Tabs to the Left", action: #selector(closeTabsLeftFromMenu(_:)), for: item))
        menu.addItem(tabMenuItem("Close Tabs to the Right", action: #selector(closeTabsRightFromMenu(_:)), for: item))
        menu.addItem(tabMenuItem("Close Other Tabs", action: #selector(closeOtherTabsFromMenu(_:)), for: item))
        menu.addItem(tabMenuItem("Close All Tabs", action: #selector(closeAllTabsFromMenu(_:)), for: item))

        // Where the click was, not the window's centre: a right-click on the
        // leftmost tab must not open a menu at the far right.
        let location = tabView.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil)
        menu.popUp(positioning: nil, at: location, in: tabView)
    }

    private func tabMenuItem(_ title: String, action: Selector, for item: NSTabViewItem) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.representedObject = item
        entry.target = self
        return entry
    }

    @objc private func renameTabFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? NSTabViewItem,
              let id = item.identifier as? TabID,
              let tab = tabs[id] else { return }
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
        guard let item = sender.representedObject as? NSTabViewItem,
              let id = item.identifier as? TabID else { return }
        selectTab(id)
        closeFocusedTab()
    }

    @objc private func closeTabsLeftFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? NSTabViewItem,
              let id = item.identifier as? TabID,
              let position = tabIDs.firstIndex(of: id) else { return }
        closeTabs(Array(tabIDs[..<position]))
    }

    @objc private func closeTabsRightFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? NSTabViewItem,
              let id = item.identifier as? TabID,
              let position = tabIDs.firstIndex(of: id) else { return }
        closeTabs(Array(tabIDs[(position + 1)...]))
    }

    @objc private func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? NSTabViewItem,
              let id = item.identifier as? TabID else { return }
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

    /// The number of tabs. The strip's `+` is an item in the strip but not a tab,
    /// so it is not counted — a test that counted items would be counting the
    /// button that makes them.
    var tabCount: Int { tabs.count }

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
