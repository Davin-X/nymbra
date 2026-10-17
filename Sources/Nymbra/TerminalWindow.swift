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
    let tabView: NSTabView

    /// Every tab, by identity. The focused tab's container is the one in the
    /// window hierarchy.
    private var tabs: [TabID: TerminalTab] = [:]
    private(set) var focusedTab: TabID

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
        self.tabView = NSTabView(frame: frame)
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
        tabView.tabViewType = .noTabsNoBorder

        let first = TerminalWindow.firstTab
        let tab = try TerminalTab(configuration: configuration)
        tabs[first] = tab
        addTabItem(tab, id: first)
        tabView.selectTabViewItem(at: 0)
        window.makeFirstResponder(tab.focusedView)
    }

    /// Add a tab's container view as an NSTabViewItem and wire the back-reference.
    private func addTabItem(_ tab: TerminalTab, id: TabID) {
        tab.window = window
        let item = NSTabViewItem(identifier: id)
        item.label = "Nymbra"
        item.view = tab.container
        tabView.addTabViewItem(item)
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
        addTabItem(tab, id: id)
        tabView.selectTabViewItem(withIdentifier: id)
        return true
    }

    /// Close the focused tab. When it is the last one, the window closes.
    func closeFocusedTab() {
        guard let tab = tabs[focusedTab] else { return }
        let id = focusedTab
        for pane in tab.panes.values { pane.terminal.terminate() }
        tabs.removeValue(forKey: id)
        let index = tabView.indexOfTabViewItem(withIdentifier: id)
        guard index >= 0 else { return }
        tabView.removeTabViewItem(tabView.tabViewItems[index])

        if !tabs.isEmpty {
            let nextIndex = min(index, tabView.numberOfTabViewItems - 1)
            if nextIndex >= 0 { tabView.selectTabViewItem(at: nextIndex) }
        } else {
            window.performClose(nil)
        }
    }

    func selectNextTab() {
        let count = tabView.numberOfTabViewItems
        guard count > 1 else { return }
        let index = tabView.indexOfTabViewItem(withIdentifier: focusedTab)
        guard index >= 0 else { return }
        tabView.selectTabViewItem(at: (index + 1) % count)
    }

    func selectPreviousTab() {
        let count = tabView.numberOfTabViewItems
        guard count > 1 else { return }
        let index = tabView.indexOfTabViewItem(withIdentifier: focusedTab)
        guard index >= 0 else { return }
        tabView.selectTabViewItem(at: (index - 1 + count) % count)
    }

    // MARK: - Pane operations (delegate to the focused tab)

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

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let id = tabViewItem?.identifier as? TabID else { return }
        focusedTab = id
        tabs[id]?.window = window
        window.makeFirstResponder(tabs[id]?.focusedView)
    }

    // MARK: - The window itself

    func makeKeyAndOrderFront() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(focusedView)
    }

    private func updateTitle() {
        guard let tab = tabs[focusedTab] else { return }
        let title = tab.panes[tab.focusedPane]?.title ?? ""
        window.title = title.isEmpty ? "Nymbra" : title
        window.subtitle = tab.layout.count > 1 ? "\(tab.layout.count) panes" : ""
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        tabs[focusedTab]?.windowShouldClose(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        for tab in tabs.values {
            for pane in tab.panes.values { pane.terminal.terminate() }
        }
    }
}
