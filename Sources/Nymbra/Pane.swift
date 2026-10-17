import AppKit
import NymbraCore

/// One terminal in a window: a shell, the screen model it feeds, and the view
/// that draws it.
///
/// The three travel together because they *are* one thing — a pane is not "a view
/// plus some state", it is a shell and the window onto it — and because keeping
/// them in one object is what makes the milestone's acceptance criterion
/// checkable: four panes are four of these, with nothing shared between them.
final class Pane {
    let id: PaneID
    let terminal: Terminal
    let view: TermView

    init(id: PaneID, terminal: Terminal, view: TermView) {
        self.id = id
        self.terminal = terminal
        self.view = view
    }

    /// What the window calls itself when this pane has the keyboard. Empty until
    /// something sets a title, so the caller decides what to fall back to — the
    /// window's title is not the model's business.
    var title: String { terminal.screen.title }
}
