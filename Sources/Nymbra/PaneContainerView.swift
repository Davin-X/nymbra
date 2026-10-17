import AppKit
import NymbraCore

/// The view that holds the panes and the lines between them.
///
/// It owns no sessions and no layout state of its own: it is handed a layout and
/// a view per pane, puts the views where the layout says, fills the gaps between
/// them, and turns mouse events back into requests — which pane was clicked,
/// where a divider was dragged to. Everything that can be got wrong about the
/// arithmetic lives in `PaneLayout`, where it is asserted without a window. What
/// is left here reports rather than decides, which is why it is short.
final class PaneContainerView: NSView {
    /// A click landed in a pane, or the keyboard moved into one.
    var onFocusRequest: ((PaneID) -> Void)?
    /// A divider is being dragged, to this position in points along its axis.
    var onDividerMoved: ((PaneLayout.Divider, Double) -> Void)?

    /// The line between panes. Set from the theme, so a preset that changes every
    /// other colour changes the seam too.
    var dividerColour: CGColor = CGColor(gray: 0.5, alpha: 1) {
        didSet { needsDisplay = true }
    }

    /// The arrangement in force, set by the window on every change. The views are
    /// placed from it in `layout()` — AppKit's layout pass, not ours, so a resize
    /// and a reshuffle go through the same code.
    ///
    /// Named `arrangement` and not `layout` because `layout()` is the method
    /// AppKit calls to do exactly this, and a property cannot share its name.
    var arrangement = PaneLayout(PaneID(0)) {
        didSet {
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private var paneViews: [PaneID: TermView] = [:]
    private var draggedDivider: PaneLayout.Divider?

    /// y grows downward, the direction the rows of a terminal grow, so the frames
    /// from `PaneLayout` are used exactly as they come.
    override var isFlipped: Bool { true }

    // MARK: - Laying out

    /// Put these views at the positions this layout gives them. Views for panes
    /// that no longer exist are removed here and nowhere else, so there is one
    /// answer to "what is on screen".
    func setPanes(_ views: [PaneID: TermView], arrangement: PaneLayout) {
        for (id, view) in views where paneViews[id] !== view {
            addSubview(view)
        }
        for (id, view) in paneViews where views[id] !== view {
            view.removeFromSuperview()
        }
        paneViews = views
        self.arrangement = arrangement
    }

    override func layout() {
        super.layout()
        for placed in arrangement.placed(in: containerSize) {
            paneViews[placed.pane]?.frame = NSRect(x: placed.frame.x,
                                                   y: placed.frame.y,
                                                   width: placed.frame.width,
                                                   height: placed.frame.height)
        }
    }

    private var containerSize: (width: Double, height: Double) {
        (width: Double(bounds.width), height: Double(bounds.height))
    }

    /// The panes' frames as they are on screen, which is what a drag and a click
    /// have to agree with. AppKit's layout pass is not guaranteed to have run
    /// since the last change, so it is forced first.
    var placedPanes: [PaneLayout.PlacedPane] {
        layoutSubtreeIfNeeded()
        return arrangement.placed(in: containerSize)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The whole background is the divider colour. The panes cover everything
        // except the gaps between them, so one fill draws every line at once and
        // no line can be drawn at an offset from the frames it separates — which
        // is the sort of thing that shows up as a one-pixel seam and nowhere else.
        ctx.setFillColor(dividerColour)
        ctx.fill(bounds)
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A one-point line cannot be hit by hand, so anywhere close to one belongs
        // to the line rather than to the pane underneath it. Without this the grab
        // area is a single point and dragging a divider is not possible in
        // practice, only in principle.
        let local = superview == nil ? point : convert(point, from: superview)
        if bounds.contains(local), divider(at: local) != nil { return self }
        return super.hitTest(point)
    }

    private func divider(at point: NSPoint) -> PaneLayout.Divider? {
        arrangement.divider(nearX: Double(point.x), y: Double(point.y), in: containerSize)
    }

    /// A divider says what it does with the pointer, because it is too thin to
    /// look like a control.
    override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        for (divider, strip) in arrangement.dividers(in: containerSize) {
            let cursor: NSCursor = divider.axis == .sideBySide ? .resizeLeftRight : .resizeUpDown
            let slack: CGFloat = 3
            addCursorRect(NSRect(x: strip.x - slack, y: strip.y - slack,
                                 width: strip.width + slack * 2,
                                 height: strip.height + slack * 2),
                          cursor: cursor)
        }
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        draggedDivider = divider(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let divider = draggedDivider else { return }
        // The divider's identity — which split it belongs to — is what the layout
        // needs; its old position is not, and is stale after the first move of the
        // drag, since the layout is a value that has already been replaced.
        let point = convert(event.locationInWindow, from: nil)
        let position = divider.axis == .sideBySide ? Double(point.x) : Double(point.y)
        onDividerMoved?(divider, position)
    }

    override func mouseUp(with event: NSEvent) {
        draggedDivider = nil
    }
}
