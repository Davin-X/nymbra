import AppKit
import Foundation
import NymbraCore

/// One window: a set of tabs, each with its own layout of panes.
///
/// The window owns the tab view and the tabs. Only the focused tab's container
/// view is in the window hierarchy — NSTabView swaps them as the person switches
/// tabs. Splits live inside a tab; a new tab gets a fresh full-window shell.
///
/// All shell spawning goes through `posix_spawn` (ADR-0007), so a second tab —
/// like a second window or a split — can be started after AppKit is running.
final class TerminalWindow: NSObject, NSWindowDelegate, NSTabViewDelegate {
    let window: NSWindow
    let tabView: TabStripView

    /// Every tab, by identity. The focused tab's container is the one in the
    /// window hierarchy.
    private var tabs: [TabID: TerminalTab] = [:]
    private(set) var focusedTab: TabID

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
        tabView.selectTabViewItem(withIdentifier: id)
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

        let index = tabView.indexOfTabViewItem(withIdentifier: id)
        if index >= 0 {
            tabView.removeTabViewItem(tabView.tabViewItems[index])
        }

        if !tabs.isEmpty {
            // The tab that was next to it, or the last one left — and never the `+`:
            // selecting that would make a tab when the person meant to see one.
            let remaining = tabIDs.filter { $0 != id }
            let position = (tabIDs.firstIndex(of: id) ?? 0)
            focusedTab = remaining[min(position, remaining.count - 1)]
            tabView.selectTabViewItem(withIdentifier: focusedTab)
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

    func selectNextTab() {
        let ids = tabIDs
        guard ids.count > 1, let index = ids.firstIndex(of: focusedTab) else { return }
        focusedTab = ids[(index + 1) % ids.count]
        tabView.selectTabViewItem(withIdentifier: focusedTab)
    }

    func selectPreviousTab() {
        let ids = tabIDs
        guard ids.count > 1, let index = ids.firstIndex(of: focusedTab) else { return }
        focusedTab = ids[(index - 1 + ids.count) % ids.count]
        tabView.selectTabViewItem(withIdentifier: focusedTab)
    }

    /// Bring a tab to the front.
    ///
    /// The tab view's own selection is asked to do the same, but its delegate
    /// callback is not guaranteed to run synchronously, so the focus is set here
    /// first. A method that only sets the focus and waits for the callback is a
    /// method that shows the wrong tab when the callback is late.
    func selectTab(_ id: TabID) {
        focusedTab = id
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
        tabs[id]?.host = self
        window.makeFirstResponder(tabs[id]?.focusedView)
        // The title belongs to the tab in front of the person, which is not
        // necessarily the tab that last printed something.
        refreshTitle()
    }

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
        tab.item?.label = tab.displayName
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
