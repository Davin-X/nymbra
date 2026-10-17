import Foundation
import NymbraCore

/// Pane layout: the arithmetic behind splits.
///
/// This suite exists because every interesting thing a split can do wrong is
/// invisible on a first look. A pane that is one point too narrow leaves a hairline
/// of the wrong colour; a divider dragged to the edge makes a pane vanish with no
/// way to bring it back; a layout with a hole in it still draws two terminals that
/// each look perfectly fine. None of that is visible in a screenshot, and all of
/// it is decided by the numbers asserted here.
func paneLayoutSuite(_ h: Harness) {
    h.suite("panes")

    let a = PaneID(0)
    let b = PaneID(1)
    let c = PaneID(2)
    let d = PaneID(3)
    let size = (width: 1000.0, height: 600.0)

    /// The panes tile `size` exactly: no gap other than the dividers, no overlap,
    /// and nothing outside the window. This is the property the whole milestone
    /// rests on, so it is a function rather than a paragraph.
    func tilesExactly(_ layout: PaneLayout, in size: (width: Double, height: Double),
                      _ what: String) {
        let divider = PaneLayout.defaultDivider
        let placed = layout.placed(in: size)
        h.equal(placed.count, layout.count, "\(what): every pane is placed")

        for one in placed {
            let frame = one.frame
            h.expect(frame.width > 0 && frame.height > 0,
                     "\(what): \(one.pane) has a real size")
            h.expect(frame.x >= -0.001 && frame.y >= -0.001
                     && frame.maxX <= size.width + 0.001 && frame.maxY <= size.height + 0.001,
                     "\(what): \(one.pane) is inside the window")

            // Every edge must meet the window or a neighbour, with exactly one
            // divider between them. A hairline of unclaimed space shows up here as
            // an edge that lines up with nothing — which is the bug this whole
            // function exists to catch, because it draws as a sliver of the wrong
            // colour and nothing else notices.
            let others = placed.filter { $0.pane != one.pane }.map(\.frame)
            func meets(_ value: Double, the window: Double, or align: (PaneFrame) -> Double) -> Bool {
                abs(value - window) < 0.001 || others.contains { abs(value - align($0)) < 0.001 }
            }
            h.expect(meets(frame.x, the: 0) { $0.maxX + divider },
                     "\(what): \(one.pane)'s left edge meets the window or a neighbour")
            h.expect(meets(frame.maxX, the: size.width) { $0.x - divider },
                     "\(what): \(one.pane)'s right edge meets the window or a neighbour")
            h.expect(meets(frame.y, the: 0) { $0.maxY + divider },
                     "\(what): \(one.pane)'s top edge meets the window or a neighbour")
            h.expect(meets(frame.maxY, the: size.height) { $0.y - divider },
                     "\(what): \(one.pane)'s bottom edge meets the window or a neighbour")
        }

        for (index, one) in placed.enumerated() {
            for other in placed[(index + 1)...] {
                let overlapWidth = min(one.frame.maxX, other.frame.maxX) - max(one.frame.x, other.frame.x)
                let overlapHeight = min(one.frame.maxY, other.frame.maxY) - max(one.frame.y, other.frame.y)
                h.expect(overlapWidth <= 0.001 || overlapHeight <= 0.001,
                         "\(what): \(one.pane) and \(other.pane) do not overlap")
            }
        }
    }

    // MARK: - One pane

    let single = PaneLayout(a)
    h.equal(single.panes, [a], "one pane, and it is the one it was made with")
    h.equal(single.placed(in: size).first?.frame,
            PaneFrame(x: 0, y: 0, width: 1000, height: 600),
            "a single pane fills the window")
    _ = d
    tilesExactly(single, in: size, "one pane")
    var lastPane = single
    h.expect(!lastPane.close(a), "the last pane cannot be closed")
    h.equal(lastPane.count, 1, "and a refused close changes nothing")

    // MARK: - Splitting

    var two = single
    h.expect(two.split(a, axis: .sideBySide, adding: b), "a pane can be split side by side")
    h.equal(two.panes, [a, b], "the new pane is second, which is to the right")
    tilesExactly(two, in: size, "two side by side")

    let sideBySide = two.placed(in: size)
    h.equal(sideBySide[0].frame.width, sideBySide[1].frame.width,
            "a fresh split is equal halves")
    h.equal(sideBySide[1].frame.x, sideBySide[0].frame.width + PaneLayout.defaultDivider,
            "and the divider is the whole gap between them")

    var duplicate = two
    h.expect(!duplicate.split(a, axis: .sideBySide, adding: b),
             "a pane already in the layout cannot be added again")
    h.equal(duplicate.panes, [a, b], "and a refused split changes nothing")
    h.expect(!duplicate.split(PaneID(99), axis: .sideBySide, adding: PaneID(98)),
             "and a pane that is not in the layout cannot be split")

    var stacked = single
    h.expect(stacked.split(a, axis: .stacked, adding: b), "a pane can be split stacked")
    let above = stacked.placed(in: size)[0]
    h.equal(above.frame.height, 299.5, "a stacked split divides the height, not the width")
    h.equal(above.frame.width, 1000, "and each half keeps the full width")
    tilesExactly(stacked, in: size, "two stacked")

    // MARK: - Four panes
    //
    // The acceptance criterion for the milestone, in numbers: split twice, in two
    // directions, and every pane is still exactly where it should be.

    var four = PaneLayout(a)
    four.split(a, axis: .sideBySide, adding: b)
    four.split(a, axis: .stacked, adding: c)
    four.split(b, axis: .stacked, adding: d)
    h.equal(four.panes, [a, c, b, d], "tree order is left to right, top to bottom")
    tilesExactly(four, in: size, "four panes")

    let grid = Dictionary(uniqueKeysWithValues: four.placed(in: size).map { ($0.pane, $0.frame) })
    h.equal(grid[a]?.y, 0, "the top-left pane is at the top")
    h.equal(grid[c]?.x, 0, "and the bottom-left pane is at the left")
    h.equal(grid[b]?.x, grid[d]?.x, "the two right-hand panes share their left edge")
    h.expect((grid[d]?.y ?? 0) > (grid[b]?.y ?? 0), "the lower-right pane is below the upper-right one")

    // MARK: - Closing

    var closing = four
    h.expect(closing.close(c), "a pane can be closed")
    h.equal(closing.panes, [a, b, d], "and is gone from the layout")
    tilesExactly(closing, in: size, "three panes after a close")

    var oneLeft = two
    h.expect(oneLeft.close(b), "closing one of two panes is allowed")
    h.equal(oneLeft.panes, [a], "which leaves one")
    h.equal(oneLeft.placed(in: size).first?.frame,
            PaneFrame(x: 0, y: 0, width: 1000, height: 600),
            "and the survivor takes the whole window, with no divider left behind")

    h.expect(!oneLeft.close(a), "the last pane still cannot be closed")

    // The sibling takes the space and the *other* splits keep their proportions:
    // closing a pane is not a reason for the rest of the window to move.
    var kept = four
    if let divider = kept.divider(nearX: 500, y: 300, in: size) {
        kept.move(divider, to: 250, in: size)
    }
    let before = kept.placed(in: size)
    let leftBefore = before.first { $0.pane == a }?.frame
    h.expect(kept.close(d), "a pane at the end of the tree can be closed")
    let after = kept.placed(in: size)
    h.equal(after.first { $0.pane == a }?.frame, leftBefore,
            "closing a pane elsewhere does not move this one")
    h.equal(after.first { $0.pane == b }?.frame.height, 600,
            "and the surviving pane in the closed one's column takes the height")
    tilesExactly(kept, in: size, "panes after closing one of four")

    // MARK: - Trees, and trees that lie

    h.expect(PaneLayout(root: .pane(a)) != nil, "a tree with one leaf is valid")
    h.expect(PaneLayout(root: .split(axis: .sideBySide, fraction: 0.5,
                                     first: .pane(a), second: .pane(a))) == nil,
             "a tree that names the same pane twice is refused")
    h.expect(PaneLayout(root: .split(axis: .sideBySide, fraction: 0.5,
                                     first: .pane(a), second: .pane(b))) != nil,
             "a tree with two distinct panes is accepted")

    // MARK: - Focus order

    h.equal(four.next(after: a), c, "next follows reading order")
    h.equal(four.next(after: d), a, "and wraps at the end")
    h.equal(four.previous(before: a), d, "previous wraps the other way")
    h.equal(single.next(after: a), nil, "one pane has no next")

    // MARK: - Directional navigation

    h.equal(four.neighbour(of: a, towards: .right, in: size), b, "right from the top-left pane")
    h.equal(four.neighbour(of: b, towards: .left, in: size), a, "and back to the left")
    h.equal(four.neighbour(of: a, towards: .down, in: size), c, "down from the top-left pane")
    h.equal(four.neighbour(of: b, towards: .down, in: size), d, "down from the top-right pane")
    h.equal(four.neighbour(of: c, towards: .up, in: size), a, "up from the bottom-left pane")
    h.equal(four.neighbour(of: d, towards: .right, in: size), nil, "nothing to the right of the right column")
    h.equal(four.neighbour(of: a, towards: .up, in: size), nil, "nothing above the top row")
    h.equal(four.neighbour(of: a, towards: .left, in: size), nil, "nothing to the left of the left column")

    // An uneven layout, so the answer cannot come from the shape being symmetric:
    // one tall pane on the left, two stacked on the right.
    var uneven = PaneLayout(a)
    uneven.split(a, axis: .sideBySide, adding: b)
    uneven.split(b, axis: .stacked, adding: c)
    h.equal(uneven.neighbour(of: b, towards: .down, in: size), c,
            "below the upper-right pane is the lower-right one")
    h.equal(uneven.neighbour(of: c, towards: .left, in: size), a,
            "left of a short pane is the tall pane beside it")
    h.equal(uneven.neighbour(of: a, towards: .down, in: size), nil,
            "and nothing is below a pane that spans the whole height")
    h.equal(uneven.neighbour(of: a, towards: .right, in: size), b,
            "right of the tall pane is the nearer of the two stacked ones")

    // MARK: - Dividers

    h.equal(two.divider(nearX: 500, y: 300, in: size)?.axis, .sideBySide,
            "a divider is found where the gap is")
    h.equal(two.divider(nearX: 500, y: 300, in: size)?.path, .some([]), "a single split is the root")
    h.equal(two.divider(nearX: 100, y: 300, in: size), nil,
            "and not where a pane is, away from the line")
    h.equal(stacked.divider(nearX: 500, y: 300, in: size)?.axis, .stacked,
            "a stacked split's divider is horizontal")

    // The nested divider wins at a T-junction, because that is the line the
    // pointer is on.
    let junction = four.divider(nearX: 500, y: 300, in: size)
    h.expect(junction != nil, "there is a divider at the centre of a four-pane grid")
    h.equal(junction?.axis, .sideBySide, "and it is the vertical one, which is the one the pointer is nearest")

    // Enumeration is what a cursor rectangle is built from — a one-point line
    // cannot be hit by hand, so it has to be able to say where it is without being
    // pointed at.
    let strips = two.dividers(in: size)
    h.equal(strips.count, 1, "two panes have one divider")
    h.equal(strips.first?.divider, two.divider(nearX: 500, y: 300, in: size),
            "and enumerating dividers agrees with finding one by point")
    h.expect(abs((strips.first?.strip.width ?? 0) - PaneLayout.defaultDivider) < 0.001,
             "the strip is exactly the width of the divider")
    h.expect(abs((strips.first?.strip.height ?? 0) - 600) < 0.001,
             "and runs the full height of the split")
    h.equal(four.dividers(in: size).count, 3, "four panes have three dividers")
    h.equal(four.dividers(in: size).filter { $0.divider.axis == .stacked }.count, 2,
            "two of them horizontal")

    // Moving one: the fraction follows the pointer, and the panes still tile.
    var moving = two
    if let divider = moving.divider(nearX: 500, y: 300, in: size) {
        moving.move(divider, to: 750, in: size)
    }
    let moved = moving.placed(in: size)
    h.expect(abs(moved[0].frame.width - 750) < 0.01,
             "the divider moved to where it was dragged")
    h.expect(abs(moved[1].frame.x - 751) < 0.01, "and the second pane starts after the divider")
    tilesExactly(moving, in: size, "after moving a divider")

    // Dragged to the edge, and past it: a pane may not be squeezed out of
    // existence, because a pane with no pixels has no way back.
    var squeezed = two
    if let divider = squeezed.divider(nearX: 500, y: 300, in: size) {
        squeezed.move(divider, to: -400, in: size)
    }
    let afterDrag = squeezed.placed(in: size)
    h.expect(afterDrag[0].frame.width >= PaneLayout.minimumPaneExtent - 0.001,
             "a divider cannot be dragged past the minimum pane size")
    h.expect(afterDrag[1].frame.width > PaneLayout.minimumPaneExtent,
             "and the other pane is still there")
    tilesExactly(squeezed, in: size, "after a drag to the edge")

    // A window too small for even one minimum: the panes share what there is
    // rather than one of them going negative.
    var tiny = two
    tilesExactly(tiny, in: (width: 60, height: 40), "a window smaller than two panes")

    // MARK: - Hit testing

    h.equal(four.pane(atX: 10, y: 10, in: size), a, "a point in the top-left pane is that pane")
    h.equal(four.pane(atX: 990, y: 590, in: size), d, "and a point in the bottom-right one is that one")
    h.equal(four.pane(atX: 1000, y: 300, in: size), nil, "a point outside the window is no pane")
    h.equal(two.pane(atX: 500, y: 300, in: size), nil, "a point on a divider is no pane")

    // MARK: - It is a value, not a shared thing
    //
    // Panes have independent shells, so the layouts that describe them must not
    // share state either: changing a copy must not touch the original.

    var original = two
    var copy = original
    copy.close(b)
    h.equal(original.panes, [a, b], "editing a copy of a layout leaves the original alone")
    h.equal(copy.panes, [a], "and the copy is what changed")
    tilesExactly(original, in: size, "the original layout")
}
