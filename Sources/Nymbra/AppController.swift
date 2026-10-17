import AppKit
import Foundation
import NymbraCore
import NymbraInput

/// The application's spine: the windows, the settings, and the commands that
/// both the menu bar and the settings window are built from.
///
/// Keeping this in one object is what makes "the theme in the menu" and "the
/// theme in the settings window" and "the theme being drawn" the same value
/// rather than three that agree by luck.
final class AppController: NSObject {
    private(set) var configuration: Configuration

    private var windows: [TerminalWindow] = []
    private var settingsController: SettingsWindowController?
    private var pendingSave: DispatchWorkItem?

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    /// Install the menu bar and put the first window up.
    func start() {
        AppMenu.install(controller: self, configuration: configuration)
        _ = makeWindow()
    }

    /// Make a window, with a shell of its own.
    ///
    /// Every window owns an independent `Terminal`. That is only possible because
    /// shells are started with `posix_spawn` rather than `forkpty` (ADR-0007):
    /// `forkpty` forks the application, so the first window used to have to be
    /// spawned before AppKit started — which is why there was no "New Window" to
    /// speak of, and why closing the last window was a dead end.
    @discardableResult
    func makeWindow() -> TerminalWindow? {
        discardClosedWindows()

        let window: TerminalWindow
        do {
            window = try TerminalWindow(configuration: configuration)
        } catch {
            cannotStartShell(error)
            return nil
        }

        // A split can fail after the window is up, and a shell that will not start
        // is the one failure that leaves nothing on screen to explain itself.
        window.onSpawnFailure = { [weak self] error in self?.cannotStartShell(error) }
        windows.append(window)
        window.makeKeyAndOrderFront()
        return window
    }

    /// Bring a window forward, or make one if there is none left.
    ///
    /// This is what a Dock click and `open` on the bundle go through. A closed
    /// window is skipped rather than revived: its shell was terminated when it
    /// closed, so what is behind it is a still picture, not a session.
    @discardableResult
    func reopenWindow() -> TerminalWindow? {
        discardClosedWindows()
        guard let window = windows.last else {
            return makeWindow()
        }
        window.makeKeyAndOrderFront()
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    /// A closed window is dropped only from here — never from inside
    /// `windowWillClose`, where releasing the last reference would deallocate a
    /// window in the middle of closing it.
    private func discardClosedWindows() {
        windows.removeAll { $0.isClosed }
    }

    /// The window a command should act on: the key one, or the last one standing.
    private var activeWindow: TerminalWindow? {
        if let key = NSApp.keyWindow, let match = windows.first(where: { $0.window === key }) {
            return match
        }
        return windows.last(where: { !$0.isClosed })
    }

    /// A shell that will not start leaves the application with nothing to show, so
    /// it is said out loud rather than written to a log nobody will read.
    private func cannotStartShell(_ error: Error) {
        FileHandle.standardError.write(Data("nymbra: \(error)\n".utf8))
        let alert = NSAlert()
        alert.messageText = "Cannot start a shell"
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func noteExit(of window: TerminalWindow) {
        // The window stays open showing the final output, which is what a person
        // wants after a build fails. It just stops being a live session.
        _ = window
    }

    /// Panes: the window keeps the keyboard, and the pane under it moves.
    ///
    /// Each of these is one line because the decision is not here — it is in
    /// `TerminalWindow`, which owns the layout and the shells, and in
    /// `PaneLayout`, where the arithmetic is asserted without a window.
    @objc func splitRight(_ sender: Any?) {
        activeWindow?.split(.sideBySide)
    }

    @objc func splitDown(_ sender: Any?) {
        activeWindow?.split(.stacked)
    }

    /// ⌘W. The pane the keyboard is in, and the window when it is the last one:
    /// "close the thing I am typing into" is what a person means by it, and with
    /// one pane on screen that is the window.
    @objc func closePane(_ sender: Any?) {
        guard let window = activeWindow else { return }
        if !window.closeFocusedPane() {
            window.window.performClose(nil)
        }
    }

    @objc func focusNextPane(_ sender: Any?) {
        activeWindow?.focusNextPane()
    }

    @objc func focusPreviousPane(_ sender: Any?) {
        activeWindow?.focusPreviousPane()
    }

    // MARK: - Settings

    /// Apply a configuration to every open terminal, then write it out.
    ///
    /// Applying first is the point: the preview in the settings window is a real
    /// terminal changing, not a mock-up.
    func apply(_ configuration: Configuration) {
        self.configuration = configuration
        for window in windows { window.apply(configuration) }
        scheduleSave()
    }

    /// Writes are debounced: dragging a font-size stepper or a colour well fires
    /// a change per pixel, and none of them deserves its own disk write.
    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func save() {
        do {
            try configuration.save()
        } catch {
            FileHandle.standardError.write(Data("nymbra: settings not saved: \(error)\n".utf8))
        }
    }

    // MARK: - Commands
    //
    // Each of these is a menu action. The menu item's key equivalent comes from
    // `Command.shortcut(for:overrides:)`, the same function the settings window
    // reads, so a shortcut cannot be advertised in one place and missing in the
    // other.

    @objc func newWindow(_ sender: Any?) {
        _ = makeWindow()
    }

    @objc func newTab(_ sender: Any?) {
        activeWindow?.newTab()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController(configuration: configuration) { [weak self] updated in
                self?.apply(updated)
            }
        }
        settingsController?.reload(from: configuration)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func copy(_ sender: Any?) {
        activeWindow?.focusedView?.copySelectionToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        activeWindow?.focusedView?.pasteFromPasteboard()
    }

    @objc func selectAll(_ sender: Any?) {
        activeWindow?.focusedView?.selectEverything()
    }

    @objc func clearBuffer(_ sender: Any?) {
        activeWindow?.focusedView?.clearBuffer()
    }

    @objc func increaseFontSize(_ sender: Any?) {
        changeFontSize(by: 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        changeFontSize(by: -1)
    }

    private func changeFontSize(by delta: Double) {
        var updated = configuration
        let range = Configuration.Appearance.fontSizeRange
        updated.appearance.fontSize = min(max(configuration.appearance.fontSize + delta, range.lowerBound),
                                          range.upperBound)
        guard updated.appearance.fontSize != configuration.appearance.fontSize else { return }
        apply(updated)
        // The window is not the source of this change, so it has to be told.
        settingsController?.reload(from: updated)
    }

    @objc func about(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "A terminal that pays attention.\nMIT licensed. Built from ECMA-48 and xterm's ctlseqs, with no borrowed code.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }

    @objc func openProjectPage(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/Davin-X/nymbra") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveal the settings file, so "where do these settings live?" has an
    /// answer a person can look at.
    @objc func revealSettingsFile(_ sender: Any?) {
        try? configuration.save()
        NSWorkspace.shared.activateFileViewerSelecting([Configuration.defaultURL])
    }
}
