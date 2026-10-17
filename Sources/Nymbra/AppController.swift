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
    ///
    /// The PTY is passed in because it must be spawned before AppKit starts
    /// (ADR-0002); this is also why there is no "New Window" yet — a second
    /// shell at runtime needs `posix_spawn` rather than `forkpty`, which is the
    /// next milestone's work rather than a thing to get subtly wrong now.
    func start(terminal: Terminal) {
        AppMenu.install(controller: self, configuration: configuration)

        let window = TerminalWindow(configuration: configuration, terminal: terminal)
        window.onExit = { [weak self, weak window] in
            guard let self, let window else { return }
            self.noteExit(of: window)
        }
        windows.append(window)
        window.makeKeyAndOrderFront()
    }

    /// The window a command should act on: the key one, or the last one standing.
    private var activeWindow: TerminalWindow? {
        if let key = NSApp.keyWindow, let match = windows.first(where: { $0.window === key }) {
            return match
        }
        return windows.last
    }

    private func noteExit(of window: TerminalWindow) {
        // The window stays open showing the final output, which is what a person
        // wants after a build fails. It just stops being a live session.
        _ = window
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
        activeWindow?.view.copySelectionToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        activeWindow?.view.pasteFromPasteboard()
    }

    @objc func selectAll(_ sender: Any?) {
        activeWindow?.view.selectEverything()
    }

    @objc func clearBuffer(_ sender: Any?) {
        activeWindow?.view.clearBuffer()
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
