import AppKit

/// The application-level decisions AppKit asks about.
///
/// This is two methods, and it exists because of a bug: closing the window with
/// the red button ended the shell and left Nymbra running with no window and no
/// way back. Clicking the Dock icon did nothing — the application was alive,
/// visibly so, and unable to show a terminal — and the only route to a new shell
/// was to quit and start again.
///
/// Both methods were previously absent, which is not the same as "the defaults
/// are fine": the default for reopening is to do nothing when there is nothing
/// to reopen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    /// Closing the last window ends the session, not the application — which is
    /// what a terminal should do, and only reasonable because reopening works.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A Dock click, or `open` on the bundle, brings back a window: the one that
    /// is still open, or a new one if they are all gone.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            controller.reopenWindow()
        }
        return true
    }
}
