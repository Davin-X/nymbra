import AppKit
import Foundation
import NymbraCore

/// One window: a PTY, the screen model it feeds, and the view that draws it.
///
/// A window is the unit that settings apply to, which is what makes the settings
/// window's preview "applies to every open terminal as you make the change"
/// rather than "restart and hope".
final class TerminalWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view: TermView
    let terminal: Terminal

    private var configuration: Configuration

    /// Whether the red button has been used. The window object outlives closing —
    /// `isReleasedWhenClosed` is off, because this class owns it — so "closed" has
    /// to be remembered rather than inferred from `window.isVisible`, which is also
    /// false for a window that has merely been minimised.
    private(set) var isClosed = false

    /// Called when the shell exits, so the application can tidy up.
    var onExit: (() -> Void)?

    /// The terminal is passed in rather than spawned here so that the window owns
    /// a shell it did not have to make: who starts a shell, and when, is
    /// `AppController`'s decision, and it is the same decision for the first
    /// window and every one after it.
    init(configuration: Configuration, terminal: Terminal) {
        self.configuration = configuration
        self.terminal = terminal

        let frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        self.view = TermView(frame: frame, screen: terminal.screen, configuration: configuration)
        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.delegate = self
        window.title = "Nymbra"
        window.contentView = view
        window.setContentSize(frame.size)
        window.center()
        // The window is owned by this object (and by the application's list of
        // windows), so closing it must not also release it.
        window.isReleasedWhenClosed = false

        view.onInput = { [weak self] bytes in self?.terminal.send(bytes) }
        view.onResize = { [weak self] size in self?.terminal.resize(size) }
        terminal.onUpdate = { [weak self] in
            guard let self else { return }
            self.view.needsDisplay = true
            // OSC 0 and OSC 2 set the title, which is how `vim` and `ssh` tell
            // the window what they are doing.
            let title = self.terminal.screen.title
            if !title.isEmpty { self.window.title = title }
        }
        terminal.onBell = { NSSound.beep() }
        terminal.onExit = { [weak self] in
            self?.window.title = "Nymbra \u{2014} shell exited"
            self?.onExit?()
        }

        // The window's real grid is only known now, so tell the shell about it
        // before the first byte of output is read.
        terminal.resize(view.grid)
        terminal.start()

        window.makeFirstResponder(view)
    }

    /// Apply new settings, live. The font may have changed, which changes the
    /// grid, so the shell is told the new size as well.
    func apply(_ configuration: Configuration) {
        self.configuration = configuration
        view.apply(configuration)
        terminal.resize(view.grid)
    }

    func makeKeyAndOrderFront() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    // MARK: - Closing

    /// Ask before ending work. Only when a *command* is running: closing a window
    /// that is sitting at a prompt is not worth a dialogue, and a terminal that
    /// asks every time trains people to click through the one that mattered.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard configuration.behaviour.confirmBeforeClosingRunningSession,
              terminal.isRunning,
              terminal.hasForegroundJob else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Close this window?"
        alert.informativeText = "A command is still running here. Closing the window ends it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        terminal.terminate()
    }
}
