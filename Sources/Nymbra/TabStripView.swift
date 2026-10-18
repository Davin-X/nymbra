import AppKit

/// The tab view, with a right-click that means something.
///
/// `NSTabView` draws its strip but offers no menu for it and no way to ask for one
/// per item, so the strip is asked directly: `tabViewItem(at:)` is the public
/// answer to which tab is under the pointer. A click anywhere else in the view —
/// which is to say on a terminal — is left alone, because a right-click there is
/// the terminal's business, not the strip's.
///
/// The strip's `+` is the one item that is not a tab, and it is the one item
/// that is never selected: selecting it would show an empty page. Clicking it
/// makes a tab instead, handled below, so the `+` stays where it is and the tab
/// it made takes the selection.
final class TabStripView: NSTabView {
    /// A right-click landed on a tab: this is the one it landed on.
    var onTabRightClick: ((NSTabViewItem) -> Void)?

    /// The item in the strip that is not a tab. Held here so a click on it can
    /// be told apart from a click on a real tab without asking the window.
    var plusItem: NSTabViewItem?

    /// A click on the `+`. It is not a selection, so it is not a delegate
    /// callback: the tab view's own selection machinery has no notion of a button.
    var onAddTab: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item = tabViewItem(at: point), item === plusItem {
            onAddTab?()
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let item = tabViewItem(at: convert(event.locationInWindow, from: nil))
        guard let item else {
            super.rightMouseDown(with: event)
            return
        }
        onTabRightClick?(item)
    }
}
