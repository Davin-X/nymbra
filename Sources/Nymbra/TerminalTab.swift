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
        window?.makeFirstResponder(target.view)
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
        if closing.view === window?.firstResponder { window?.makeFirstResponder(nil) }
        closing.terminal.terminate()
        applyLayout()
        if let next, panes[next] != nil { focus(next) }
        return true
    }

    private func paneExited(_ pane: PaneID) {
        guard layout.count > 1 else {
            window?.title = "Nymbra \u{2014} shell exited"
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

    private func updateTitle() {
        let title = panes[focusedPane]?.title ?? ""
        window?.title = title.isEmpty ? "Nymbra" : title
        window?.subtitle = layout.count > 1 ? "\(layout.count) panes" : ""
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard configuration.behaviour.confirmBeforeClosingRunningSession,
              panes.values.contains(where: { $0.terminal.isRunning && $0.terminal.hasForegroundJob })
        else { return true }
        return confirm(what: "Close this tab?",
                       detail: "A command is still running here. Closing the tab ends it.")
    }

    private func confirmClosing(pane: PaneID) -> Bool {
        guard configuration.behaviour.confirmBeforeClosingRunningSession,
              let candidate = panes[pane],
              candidate.terminal.isRunning,
              candidate.terminal.hasForegroundJob
        else { return true }
        return confirm(what: "Close this pane?",
                       detail: "A command is still running here. Closing the pane ends it.")
    }

    private func confirm(what: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    weak var window: NSWindow?
}

/// One tab's identity inside a window.
public struct TabID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "tab-\(raw)" }
}