import AppKit
import Foundation
import NymbraCore

/// One window: a layout of panes, each with a shell of its own.
///
/// The window owns the layout and the panes, and is the single place that knows
/// how to make one — the first pane and every pane after it go through the same
/// `makePane`, which is only possible because shells are started with
/// `posix_spawn` rather than `forkpty` (ADR-0007). Before that, the first shell
/// had to be spawned before AppKit started, so a window could not make another
/// pane at all.
///
/// A window is also the unit that settings apply to, which is what makes the
/// settings window's preview "applies to every open terminal as you make the
/// change" rather than "restart and hope".
final class TerminalWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let container: PaneContainerView

    /// Every pane, by identity. Not private: `--split-test` reads it, and the
    /// alternative would be a second set of accessors that exist only for tests.
    private(set) var panes: [PaneID: Pane] = [:]
    private(set) var layout: PaneLayout
    private(set) var focusedPane: PaneID

    /// The identity of the shell the window starts with.
    private static let firstPane = PaneID(0)

    private var configuration: Configuration

    /// The next identity to hand out, and deliberately not the pane count: the
    /// first version of this started at 0 while the first pane was already pane 0,
    /// so the first split asked for an identity that existed, was refused, and did
    /// nothing at all. Keeping the counter tied to `firstPane` is the point of that
    /// being a constant.
    private var nextPaneID = TerminalWindow.firstPane.raw + 1

    /// Whether the red button has been used. The window object outlives closing —
    /// `isReleasedWhenClosed` is off, because this class owns it — so "closed" has
    /// to be remembered rather than inferred from `window.isVisible`, which is also
    /// false for a window that has merely been minimised.
    private(set) var isClosed = false

    /// A shell that will not start *after* the window is up. The first pane's
    /// failure is thrown from `init` instead, because there is no window yet to
    /// report it in.
    var onSpawnFailure: ((Error) -> Void)?

    /// The view the keyboard is in: what Copy, Paste and Select All act on.
    var focusedView: TermView? { panes[focusedPane]?.view }

    init(configuration: Configuration) throws {
        self.configuration = configuration

        let first = TerminalWindow.firstPane
        self.layout = PaneLayout(first)
        self.focusedPane = first

        let frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        self.container = PaneContainerView(frame: frame)
        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.delegate = self
        window.title = "Nymbra"
        window.contentView = container
        window.setContentSize(frame.size)
        window.center()
        // The window is owned by this object (and by the application's list of
        // windows), so closing it must not also release it.
        window.isReleasedWhenClosed = false

        container.dividerColour = Theme(configuration).divider
        container.onFocusRequest = { [weak self] pane in self?.focus(pane) }
        container.onDividerMoved = { [weak self] divider, position in
            self?.moveDivider(divider, to: position)
        }

        let firstPane = try makePane(id: first)
        panes[first] = firstPane
        applyLayout()
        // The grid is only known now, so the shell is told about it before the
        // first byte of output is read.
        firstPane.terminal.resize(firstPane.view.grid)
        firstPane.terminal.start()
        updateTitle()
        window.makeFirstResponder(firstPane.view)
    }

    // MARK: - Making panes

    /// A shell on a PTY, and the view that draws it.
    ///
    /// The terminal is not started here: a new pane is started after the layout
    /// has given its view its real size, so the shell's first prompt is formatted
    /// for the width it will actually have rather than for the window's.
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
            // OSC 0 and OSC 2 set the title, which is how `vim` and `ssh` tell the
            // window what they are doing.
            self?.updateTitle()
        }
        terminal.onBell = { NSSound.beep() }
        terminal.onExit = { [weak self] in self?.paneExited(id) }
        return pane
    }

    /// Hand the container the views and the layout, and make it place them *now*.
    /// A shell that is told a size it is not drawn at is a shell whose output wraps
    /// in the wrong place until the next resize.
    private func applyLayout() {
        container.setPanes(panes.mapValues { $0.view }, arrangement: layout)
        container.layoutSubtreeIfNeeded()
    }

    /// Split the focused pane, putting the new shell on the right or below it.
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
            // Cannot happen — the id is new and the focused pane is in the layout
            // — but a shell that is never shown is a shell that never ends.
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

    /// A new shell that fills the window: every existing pane ends, like closing
    /// a tab and opening another. The window stays; only the shell changes.
    @discardableResult
    func newTab() -> Bool {
        let id = PaneID(nextPaneID)
        nextPaneID += 1

        let pane: Pane
        do {
            pane = try makePane(id: id)
        } catch {
            onSpawnFailure?(error)
            return false
        }

        // Every existing pane ends: this window now has one shell, full window.
        for (_, oldPane) in panes {
            oldPane.terminal.terminate()
        }
        panes.removeAll()

        layout = PaneLayout(id)
        panes[id] = pane
        applyLayout()
        pane.terminal.resize(pane.view.grid)
        pane.terminal.start()
        focus(id)
        return true
    }

    /// Take the keyboard, and show where it is: with more than one pane on screen,
    /// "where does my typing go?" has to be answerable at a glance.
    func focus(_ pane: PaneID) {
        guard let target = panes[pane] else { return }
        focusedPane = pane
        for (id, candidate) in panes {
            candidate.view.isFocused = (id == pane)
        }
        container.needsDisplay = true
        window.makeFirstResponder(target.view)
        updateTitle()
    }

    func focusNextPane() {
        if let next = layout.next(after: focusedPane) { focus(next) }
    }

    func focusPreviousPane() {
        if let previous = layout.previous(before: focusedPane) { focus(previous) }
    }

    /// Move the keyboard to the pane in a direction, by geometry: the one a person
    /// means by "the pane to the right".
    func focusPane(towards direction: PaneLayout.Direction) {
        let size = (width: Double(container.bounds.width), height: Double(container.bounds.height))
        if let next = layout.neighbour(of: focusedPane, towards: direction, in: size) {
            focus(next)
        }
    }

    // MARK: - Closing

    /// Close the focused pane. Returns false when it is the last one: there is then
    /// nothing left to draw in this window, and the caller's job is to close the
    /// window instead.
    @discardableResult
    func closeFocusedPane() -> Bool {
        close(focusedPane)
    }

    @discardableResult
    func close(_ pane: PaneID) -> Bool {
        guard layout.count > 1, let closing = panes[pane] else { return false }
        guard confirmClosing(pane: pane) else { return false }

        // Focus moves before the pane goes, while the layout can still say which
        // way is *next*: afterwards there is nothing to ask.
        let next = layout.next(after: pane) ?? layout.previous(before: pane)
        guard layout.close(pane) else { return false }

        panes.removeValue(forKey: pane)
        if closing.view === window.firstResponder { window.makeFirstResponder(nil) }
        closing.terminal.terminate()
        applyLayout()
        if let next, panes[next] != nil { focus(next) }
        return true
    }

    /// A shell has exited. Its pane goes with it, so a window running four
    /// programs does not keep three dead panes and a live one. The last pane is
    /// different: the window stays, showing the output, which is what a person
    /// wants after a build fails.
    private func paneExited(_ pane: PaneID) {
        guard !isClosed else { return }
        guard layout.count > 1 else {
            window.title = "Nymbra \u{2014} shell exited"
            return
        }

        let next = layout.next(after: pane) ?? layout.previous(before: pane)
        guard layout.close(pane) else { return }
        panes.removeValue(forKey: pane)
        applyLayout()
        if let next, panes[next] != nil { focus(next) }
    }

    /// A divider was dragged. The layout is a value, so the new position goes into
    /// it and the views are placed from the updated layout — there is no second
    /// copy of the geometry to keep in step.
    ///
    /// Internal rather than private because `--split-test` drives it directly: a
    /// drag is the arithmetic plus a mouse, and the arithmetic is the part that
    /// can be wrong.
    func moveDivider(_ divider: PaneLayout.Divider, to position: Double) {
        let size = (width: Double(container.bounds.width), height: Double(container.bounds.height))
        layout.move(divider, to: position, in: size)
        applyLayout()
    }

    // MARK: - The window itself

    func makeKeyAndOrderFront() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(focusedView)
    }

    /// The focused pane names the window: with several shells in one window, the
    /// title has to say which one is in front, and the subtitle has to say how many
    /// there are.
    private func updateTitle() {
        let title = panes[focusedPane]?.title ?? ""
        window.title = title.isEmpty ? "Nymbra" : title
        window.subtitle = layout.count > 1 ? "\(layout.count) panes" : ""
    }

    /// Apply new settings, live. Every pane, because the font may have changed and
    /// each pane's grid follows its own frame — `TermView.apply` tells its own
    /// shell the new size, so no pane is left being drawn at a size its shell does
    /// not know about.
    func apply(_ configuration: Configuration) {
        self.configuration = configuration
        container.dividerColour = Theme(configuration).divider
        for pane in panes.values { pane.view.apply(configuration) }
    }

    // MARK: - NSWindowDelegate

    /// Ask before ending work. Any pane, because closing the window ends all of
    /// them — and only when a *command* is running: a window sitting at a prompt is
    /// not worth a dialogue, and a terminal that asks every time trains people to
    /// click through the one that mattered.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard configuration.behaviour.confirmBeforeClosingRunningSession,
              panes.values.contains(where: { $0.terminal.isRunning && $0.terminal.hasForegroundJob })
        else { return true }
        return confirm(what: "Close this window?",
                       detail: "A command is still running here. Closing the window ends it.")
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

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        for pane in panes.values { pane.terminal.terminate() }
    }
}
