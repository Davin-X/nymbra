import AppKit
import NymbraCore

final class TerminalTab {
    let container: PaneContainerView
    private(set) var panes: [PaneID: Pane] = [:]
    private(set) var layout: PaneLayout
    private(set) var focusedPane: PaneID
    private static let firstPane = PaneID(0)
    private var configuration: Configuration
    private var nextPaneID = TerminalTab.firstPane.raw + 1
    var onSpawnFailure: ((Error) -> Void)?
    var focusedView: TermView? { panes[focusedPane]?.view }

    /// The strip's item for this tab, so it can name itself.
    ///
    /// Set in `attach`, once. A tab that never got attached (a spawn that failed
    /// before the view existed) has none, and then it is simply silent.
    weak var item: NSTabViewItem?

    /// A name the person gave this tab, which is what the strip and the window
    /// then call it. `nil` means "whatever the shell says it is".
    var customTitle: String? {
        didSet { item?.label = displayName }
    }

    /// The name this tab is known by, in the strip and anywhere else.
    var displayName: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        let title = panes[focusedPane]?.title ?? ""
        return title.isEmpty ? "Nymbra" : title
    }

    init(configuration: Configuration) throws {
        self.configuration = configuration
        let first = TerminalTab.firstPane
        self.layout = PaneLayout(first)
        self.focusedPane = first
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        self.container = PaneContainerView(frame: frame)
        container.dividerColour = Theme(configuration).divider
        container.onFocusRequest = { [weak self] pane in self?.focus(pane) }
        container.onDividerMoved = { [weak self] divider, position in
            self?.moveDivider(divider, to: position)
        }
        let firstPane = try makePane(id: first)
        panes[first] = firstPane
        applyLayout()
        firstPane.terminal.resize(firstPane.view.grid)
        firstPane.terminal.start()
        updateTitle()
    }

    private func makePane(id: PaneID) throws -> Pane {
        let terminal = try Terminal(size: GridSize(rows: 24, cols: 80),
                                    shell: configuration.shell.path)
        let view = TermView(frame: container.bounds,
                            screen: terminal.screen,
                            configuration: configuration)
        let pane = Pane(id: id, terminal: terminal, view: view)
        view.onInput = { [weak terminal] bytes in terminal?.send(bytes) }
        view.onResize = { [weak terminal] size in terminal?.resize(size) }
        view.onFocus = { [weak self] in self?.focus(id) }
        terminal.onUpdate = { [weak self, weak view] in
            guard let view else { return }
            view.needsDisplay = true
            self?.updateTitle()
        }
        terminal.onBell = { NSSound.beep() }
        terminal.onExit = { [weak self] in self?.paneExited(id) }
        return pane
    }

    private func applyLayout() {
        container.setPanes(panes.mapValues { $0.view }, arrangement: layout)
        container.layoutSubtreeIfNeeded()
    }

    @discardableResult
    func split(_ axis: PaneLayout.Axis) -> Bool {
        let id = PaneID(nextPaneID)
        nextPaneID += 1
        let pane: Pane
        do {
            pane = try makePane(id: id)
        } catch {
            onSpawnFailure?(error)
            return false
        }
        guard layout.split(focusedPane, axis: axis, adding: id) else {
            pane.terminal.terminate()
            return false
        }
        panes[id] = pane
        applyLayout()
        pane.terminal.resize(pane.view.grid)
        pane.terminal.start()
        focus(id)
        return true
    }

    // MARK: - Focus

    func focus(_ pane: PaneID) {
        guard let target = panes[pane] else { return }
        focusedPane = pane
        for (id, candidate) in panes {
            candidate.view.isFocused = (id == pane)
        }
        container.needsDisplay = true
        host?.window.makeFirstResponder(target.view)
        updateTitle()
    }

    func focusNextPane() {
        if let next = layout.next(after: focusedPane) { focus(next) }
    }

    func focusPreviousPane() {
        if let previous = layout.previous(before: focusedPane) { focus(previous) }
    }

    func focusPane(towards direction: PaneLayout.Direction) {
        let size = (width: Double(container.bounds.width), height: Double(container.bounds.height))
        if let next = layout.neighbour(of: focusedPane, towards: direction, in: size) {
            focus(next)
        }
    }

    // MARK: - Closing

    @discardableResult
    func closeFocusedPane() -> Bool {
        close(focusedPane)
    }

    @discardableResult
    func close(_ pane: PaneID) -> Bool {
        guard layout.count > 1, let closing = panes[pane] else { return false }
        guard confirmClosing(pane: pane) else { return false }
        let next = layout.next(after: pane) ?? layout.previous(before: pane)
        guard layout.close(pane) else { return false }
        panes.removeValue(forKey: pane)
        if closing.view === host?.window.firstResponder { host?.window.makeFirstResponder(nil) }
        closing.terminal.terminate()
        applyLayout()
        if let next, panes[next] != nil { focus(next) }
        return true
    }

    private func paneExited(_ pane: PaneID) {
        guard layout.count > 1 else {
            host?.refreshTitle()
            return
        }
        let next = layout.next(after: pane) ?? layout.previous(before: pane)
        guard layout.close(pane) else { return }
        panes.removeValue(forKey: pane)
        applyLayout()
        if let next, panes[next] != nil { focus(next) }
    }

    func moveDivider(_ divider: PaneLayout.Divider, to position: Double) {
        let size = (width: Double(container.bounds.width), height: Double(container.bounds.height))
        layout.move(divider, to: position, in: size)
        applyLayout()
    }

    func apply(_ configuration: Configuration) {
        self.configuration = configuration
        container.dividerColour = Theme(configuration).divider
        for pane in panes.values { pane.view.apply(configuration) }
    }

    /// Ask the window for its title.
    ///
    /// Called on every screen update, by any tab, whether or not it is the one
    /// showing. Whose title the window carries is the window's business, not
    /// this tab's: a background tab printing a new one must not move the window's
    /// out from under the person reading the tab they chose.
    private func updateTitle() {
        host?.refreshTitle()
        item?.label = displayName
    }

    /// The commands still in the foreground here, which is what closing ends.
    ///
    /// The shell is the session leader and its own process group, and a child job
    /// takes the foreground group, so this is only ever non-empty where job
    /// control works. A shell without it answers empty, which is the honest
    /// answer rather than a bug — and it is why the confirmation is a courtesy
    /// rather than a guarantee.
    var runningJobs: [PaneID] {
        panes.values
            .filter { $0.terminal.isRunning && $0.terminal.hasForegroundJob }
            .map(\.id)
    }

    /// What to say about them. One command and three are different sentences.
    var closeDetail: String {
        switch runningJobs.count {
        case 0:
            return ""
        case 1:
            return "A command is still running here. Closing ends it."
        default:
            return "\(runningJobs.count) commands are still running here. Closing ends them."
        }
    }

    /// Ask before ending what is still running here.
    ///
    /// `false` means the person said no, and nothing is closed — not the tab, not
    /// the pane. When the setting is off, or nothing is running, the answer is yes
    /// without a word, because a question nobody can answer is a hang.
    func confirmClose(what: String) -> Bool {
        guard configuration.behaviour.confirmBeforeClosingRunningSession,
              !runningJobs.isEmpty else { return true }
        return confirm(what: what, detail: closeDetail)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClose(what: "Close this tab?")
    }

    private func confirmClosing(pane: PaneID) -> Bool {
        guard configuration.behaviour.confirmBeforeClosingRunningSession,
              runningJobs.contains(pane) else { return true }
        return confirm(what: "Close this pane?",
                       detail: "A command is still running here. Closing the pane ends it.")
    }

    /// The window this tab is in: who it asks for a title, and who asks it for one.
    /// A tab has no title of its own — the window's title is the window's business,
    /// and this is the reference that lets it be.
    weak var host: TerminalWindow?
}

/// One tab's identity inside a window.
public struct TabID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "tab-\(raw)" }
}