import Foundation

/// One pane's identity inside a window.
///
/// An opaque value rather than an array index: a layout rearranges itself when a
/// pane is closed, and an index that means pane 2 before a close and pane 1 after
/// it is how a view ends up drawing another pane's screen.
public struct PaneID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int

    public init(_ raw: Int) {
        self.raw = raw
    }

    public var description: String { "pane-\(raw)" }
}

/// A rectangle in container coordinates, with y growing *downward* from the top
/// left — the direction terminal rows grow. The view that uses these is flipped,
/// so the arithmetic here needs no flip of its own.
public struct PaneFrame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= x && pointX < maxX && pointY >= y && pointY < maxY
    }
}

/// The arrangement of panes in one window: a binary tree of splits, each holding
/// two children, either of which may be a split itself.
///
/// This is arithmetic rather than UI, so it lives in the UI-free core and is
/// asserted headlessly. The properties worth asserting are exactly the ones that
/// are hard to see and easy to get wrong: that the panes tile the window exactly,
/// with no gap and no overlap; that closing a pane hands its space to its
/// sibling; that a divider cannot be dragged until a pane disappears; and that
/// focus moves to the pane a person would expect.
///
/// One pane is not a special case anywhere in here — a window with a single pane
/// is a layout whose root is a leaf, which is what makes "the last pane" fall out
/// of the arithmetic instead of needing a rule.
public struct PaneLayout: Equatable, Sendable {
    public enum Axis: Equatable, Sendable {
        /// A vertical divider: one pane left, one right. In the menu, "Split Right".
        case sideBySide
        /// A horizontal divider: one pane above, one below. In the menu, "Split Down".
        case stacked
    }

    /// Which half of a split, used to name a divider's position in the tree while
    /// it is being dragged.
    public enum Side: Equatable, Sendable {
        case first
        case second
    }

    public indirect enum Node: Equatable, Sendable {
        case pane(PaneID)
        case split(axis: Axis, fraction: Double, first: Node, second: Node)
    }

    public struct PlacedPane: Equatable, Sendable {
        public let pane: PaneID
        public let frame: PaneFrame
    }

    /// A divider, and enough to move it: which split it belongs to, which way it
    /// runs, and where it currently is. Returned by `divider(nearX:y:in:)` so a
    /// drag can be started from a mouse event without the view knowing the tree's
    /// shape, and so `--split-test` can drag one without a mouse at all.
    public struct Divider: Equatable, Sendable {
        public let path: [Side]
        public let axis: Axis
        /// Where the divider begins, in container points along its axis.
        public let position: Double
    }

    public enum Direction: Sendable {
        case left, right, up, down
    }

    /// The smallest a pane may be drawn before a divider stops moving, in points.
    /// Without a floor, a drag can leave a pane zero points wide: it disappears,
    /// and so does the way to get it back.
    public static let minimumPaneExtent: Double = 80

    /// The space between panes, in points.
    public static let defaultDivider: Double = 1

    public private(set) var root: Node

    public init(_ pane: PaneID) {
        root = .pane(pane)
    }

    /// Build a layout from a tree, refusing one that names the same pane twice:
    /// two leaves with one identity is how one shell's output gets drawn in two
    /// places, and it cannot be undone later because nothing can tell the two
    /// apart.
    public init?(root: Node) {
        var seen = Set<PaneID>()
        guard PaneLayout.isUnique(root, seen: &seen), !seen.isEmpty else { return nil }
        self.root = root
    }

    private static func isUnique(_ node: Node, seen: inout Set<PaneID>) -> Bool {
        switch node {
        case let .pane(id):
            return seen.insert(id).inserted
        case let .split(_, _, first, second):
            return isUnique(first, seen: &seen) && isUnique(second, seen: &seen)
        }
    }

    // MARK: - The panes

    /// Every pane, in the order a person reads them: left to right, top to bottom.
    /// That order is what "next pane" means, and it is why it is derived here
    /// rather than kept as a list that has to be kept in step with the tree.
    public var panes: [PaneID] {
        var result: [PaneID] = []
        PaneLayout.collect(root, into: &result)
        return result
    }

    public var count: Int { panes.count }

    public func contains(_ pane: PaneID) -> Bool { panes.contains(pane) }

    /// Split `pane` in two, putting `new` on the right or below it. The two halves
    /// start equal.
    @discardableResult
    public mutating func split(_ pane: PaneID, axis: Axis, adding new: PaneID) -> Bool {
        guard contains(pane), !contains(new) else { return false }
        root = PaneLayout.inserting(pane, axis: axis, new: new, into: root)
        return true
    }

    private static func inserting(_ pane: PaneID, axis: Axis, new: PaneID, into node: Node) -> Node {
        switch node {
        case let .pane(id) where id == pane:
            return .split(axis: axis, fraction: 0.5, first: .pane(id), second: .pane(new))
        case .pane:
            return node
        case let .split(nodeAxis, fraction, first, second):
            return .split(axis: nodeAxis,
                          fraction: fraction,
                          first: inserting(pane, axis: axis, new: new, into: first),
                          second: inserting(pane, axis: axis, new: new, into: second))
        }
    }

    /// Close a pane. Its sibling takes the space, so the remaining panes still
    /// tile the window exactly rather than leaving a hole.
    ///
    /// Refuses the last pane: a window with no pane in it is not a window, and
    /// the caller's job is then to close the window instead.
    @discardableResult
    public mutating func close(_ pane: PaneID) -> Bool {
        guard count > 1, contains(pane) else { return false }
        root = PaneLayout.removing(pane, from: root) ?? root
        return true
    }

    private static func removing(_ pane: PaneID, from node: Node) -> Node? {
        switch node {
        case let .pane(id):
            return id == pane ? nil : node
        case let .split(axis, fraction, first, second):
            switch (removing(pane, from: first), removing(pane, from: second)) {
            case (nil, nil): return nil
            case let (nil, survivor?): return survivor
            case let (survivor?, nil): return survivor
            case let (first?, second?):
                return .split(axis: axis, fraction: fraction, first: first, second: second)
            }
        }
    }

    private static func collect(_ node: Node, into result: inout [PaneID]) {
        switch node {
        case let .pane(id):
            result.append(id)
        case let .split(_, _, first, second):
            collect(first, into: &result)
            collect(second, into: &result)
        }
    }

    // MARK: - Geometry
    //
    // One pair of functions turns a split into two rectangles and the gap between
    // them. Everything else — drawing, hit testing, finding a divider, navigation
    // — is built from them, so the off-by-one-divider arithmetic exists in exactly
    // one place.

    /// Where each pane is drawn inside a container of `size` points.
    public func placed(in size: (width: Double, height: Double),
                       divider: Double = PaneLayout.defaultDivider) -> [PlacedPane] {
        var result: [PlacedPane] = []
        let bounds = PaneFrame(x: 0, y: 0,
                               width: max(0, size.width),
                               height: max(0, size.height))
        PaneLayout.place(root, in: bounds, divider: divider, into: &result)
        return result
    }

    private static func place(_ node: Node, in frame: PaneFrame, divider: Double,
                              into result: inout [PlacedPane]) {
        switch node {
        case let .pane(id):
            result.append(PlacedPane(pane: id, frame: frame))
        case let .split(axis, fraction, first, second):
            let halves = divide(axis: axis, fraction: fraction, frame: frame, divider: divider)
            place(first, in: halves.first, divider: divider, into: &result)
            place(second, in: halves.second, divider: divider, into: &result)
        }
    }

    private static func divide(axis: Axis, fraction: Double, frame: PaneFrame,
                               divider: Double) -> (first: PaneFrame, second: PaneFrame, gap: Double) {
        switch axis {
        case .sideBySide:
            let available = max(0, frame.width - divider)
            let firstWidth = available * clamped(fraction, in: available)
            return (PaneFrame(x: frame.x, y: frame.y, width: firstWidth, height: frame.height),
                    PaneFrame(x: frame.x + firstWidth + divider, y: frame.y,
                              width: max(0, available - firstWidth), height: frame.height),
                    frame.x + firstWidth)
        case .stacked:
            let available = max(0, frame.height - divider)
            let firstHeight = available * clamped(fraction, in: available)
            return (PaneFrame(x: frame.x, y: frame.y, width: frame.width, height: firstHeight),
                    PaneFrame(x: frame.x, y: frame.y + firstHeight + divider,
                              width: frame.width, height: max(0, available - firstHeight)),
                    frame.y + firstHeight)
        }
    }

    /// The fraction actually used, kept away from the ends so no pane is squeezed
    /// out of existence. Applied when drawing rather than only when dragging, so a
    /// window that is later made very small still tiles exactly.
    private static func clamped(_ fraction: Double, in available: Double) -> Double {
        guard available > 0 else { return 0 }
        // Half each when even the minimum would not fit: two small panes are
        // better than one that has been pushed off the edge.
        let minimum = min(minimumPaneExtent, available / 2)
        let low = minimum / available
        return min(max(fraction, low), 1 - low)
    }

    /// The pane drawn at a point, or `nil` for a divider or a point outside.
    public func pane(atX x: Double, y: Double,
                     in size: (width: Double, height: Double),
                     divider: Double = PaneLayout.defaultDivider) -> PaneID? {
        placed(in: size, divider: divider).first { $0.frame.contains(x: x, y: y) }?.pane
    }

    // MARK: - Dividers

    /// The divider near a point, if the point is within `tolerance` of one.
    ///
    /// The nearest wins, and a nested divider beats the outer one it sits inside:
    /// at a T-junction a person is aiming at the line under the pointer, not at
    /// the longest one through it.
    public func divider(nearX x: Double, y: Double,
                        in size: (width: Double, height: Double),
                        divider thickness: Double = PaneLayout.defaultDivider,
                        tolerance: Double = 3) -> Divider? {
        var best: Divider?
        var bestDistance = tolerance
        let bounds = PaneFrame(x: 0, y: 0, width: max(0, size.width), height: max(0, size.height))
        PaneLayout.findDividers(root, in: bounds, path: [], thickness: thickness,
                                x: x, y: y, tolerance: tolerance,
                                best: &best, bestDistance: &bestDistance)
        return best
    }

    /// Every divider, with the strip it occupies: the line and nothing else. For
    /// the places that need to know where the dividers are without a mouse
    /// position to start from — cursor rectangles, mainly, since a one-point line
    /// cannot be hit by hand and has to advertise itself some other way.
    public func dividers(in size: (width: Double, height: Double),
                         thickness: Double = PaneLayout.defaultDivider)
        -> [(divider: Divider, strip: PaneFrame)] {
        var result: [(divider: Divider, strip: PaneFrame)] = []
        let bounds = PaneFrame(x: 0, y: 0, width: max(0, size.width), height: max(0, size.height))
        PaneLayout.collectDividers(root, in: bounds, path: [], thickness: thickness, into: &result)
        return result
    }

    private static func collectDividers(_ node: Node, in frame: PaneFrame, path: [Side],
                                        thickness: Double,
                                        into result: inout [(divider: Divider, strip: PaneFrame)]) {
        guard case let .split(axis, fraction, first, second) = node else { return }
        let halves = divide(axis: axis, fraction: fraction, frame: frame, divider: thickness)
        switch axis {
        case .sideBySide:
            result.append((Divider(path: path, axis: axis, position: halves.gap),
                           PaneFrame(x: halves.gap, y: frame.y,
                                     width: thickness, height: frame.height)))
        case .stacked:
            result.append((Divider(path: path, axis: axis, position: halves.gap),
                           PaneFrame(x: frame.x, y: halves.gap,
                                     width: frame.width, height: thickness)))
        }
        collectDividers(first, in: halves.first, path: path + [.first], thickness: thickness,
                        into: &result)
        collectDividers(second, in: halves.second, path: path + [.second], thickness: thickness,
                        into: &result)
    }

    private static func findDividers(_ node: Node, in frame: PaneFrame, path: [Side],
                                     thickness: Double, x: Double, y: Double, tolerance: Double,
                                     best: inout Divider?, bestDistance: inout Double) {
        guard case let .split(axis, fraction, first, second) = node else { return }
        let halves = divide(axis: axis, fraction: fraction, frame: frame, divider: thickness)

        let alongAxis = axis == .sideBySide ? x : y
        let alongCross = axis == .sideBySide ? y : x
        let crossStart = axis == .sideBySide ? frame.y : frame.x
        let crossEnd = axis == .sideBySide ? frame.maxY : frame.maxX
        let distance = abs(alongAxis - halves.gap)

        if distance <= tolerance, alongCross >= crossStart, alongCross <= crossEnd,
           distance < bestDistance {
            best = Divider(path: path, axis: axis, position: halves.gap)
            bestDistance = distance
        }

        // Deeper dividers are examined after this one, and only replace it by
        // being closer, so a T-junction resolves to the nested line.
        findDividers(first, in: halves.first, path: path + [.first], thickness: thickness,
                     x: x, y: y, tolerance: tolerance, best: &best, bestDistance: &bestDistance)
        findDividers(second, in: halves.second, path: path + [.second], thickness: thickness,
                     x: x, y: y, tolerance: tolerance, best: &best, bestDistance: &bestDistance)
    }

    /// Move a divider to a point, as a drag does. The moved position is kept
    /// inside the same limits the drawing uses, so a drag cannot store a fraction
    /// that would squeeze a pane away later.
    public mutating func move(_ divider: Divider, to position: Double,
                              in size: (width: Double, height: Double),
                              thickness: Double = PaneLayout.defaultDivider) {
        guard let frame = frame(at: divider.path, in: size, divider: thickness) else { return }
        let origin = divider.axis == .sideBySide ? frame.x : frame.y
        let extent = divider.axis == .sideBySide ? frame.width : frame.height
        let available = max(0, extent - thickness)
        guard available > 0 else { return }

        let target = min(max(position, origin), origin + available)
        let fraction = PaneLayout.clamped((target - origin) / available, in: available)
        root = PaneLayout.replacing(root, at: divider.path) { node in
            guard case let .split(axis, _, first, second) = node else { return node }
            return .split(axis: axis, fraction: fraction, first: first, second: second)
        }
    }

    private func frame(at path: [Side], in size: (width: Double, height: Double),
                       divider: Double) -> PaneFrame? {
        var node = root
        var current = PaneFrame(x: 0, y: 0, width: max(0, size.width), height: max(0, size.height))
        for side in path {
            guard case let .split(axis, fraction, first, second) = node else { return nil }
            let halves = PaneLayout.divide(axis: axis, fraction: fraction, frame: current,
                                           divider: divider)
            switch side {
            case .first:
                node = first
                current = halves.first
            case .second:
                node = second
                current = halves.second
            }
        }
        return current
    }

    private static func replacing(_ node: Node, at path: [Side],
                                  _ transform: (Node) -> Node) -> Node {
        guard let side = path.first else { return transform(node) }
        guard case let .split(axis, fraction, first, second) = node else { return node }
        let rest = Array(path.dropFirst())
        switch side {
        case .first:
            return .split(axis: axis, fraction: fraction,
                          first: replacing(first, at: rest, transform), second: second)
        case .second:
            return .split(axis: axis, fraction: fraction,
                          first: first, second: replacing(second, at: rest, transform))
        }
    }

    // MARK: - Focus

    /// The next pane in reading order, wrapping. `⌘]`, and what "next" means in
    /// the menu.
    public func next(after pane: PaneID) -> PaneID? {
        guard let index = panes.firstIndex(of: pane), count > 1 else { return nil }
        return panes[(index + 1) % count]
    }

    public func previous(before pane: PaneID) -> PaneID? {
        guard let index = panes.firstIndex(of: pane), count > 1 else { return nil }
        return panes[(index - 1 + count) % count]
    }

    /// The pane next to `pane` in a direction, chosen by geometry: the pane that
    /// is beyond it on that side and overlaps it most. Neighbours that overlap win
    /// over ones that merely are in that direction, which is what makes moving
    /// around a two-by-two grid feel right.
    public func neighbour(of pane: PaneID, towards direction: Direction,
                          in size: (width: Double, height: Double),
                          divider: Double = PaneLayout.defaultDivider) -> PaneID? {
        let placed = placed(in: size, divider: divider)
        guard let origin = placed.first(where: { $0.pane == pane })?.frame else { return nil }

        var best: (pane: PaneID, touching: Bool, distance: Double, overlap: Double)?
        for candidate in placed where candidate.pane != pane {
            guard let relation = PaneLayout.relation(from: origin, to: candidate.frame,
                                                     towards: direction) else { continue }
            let better: Bool
            if let current = best {
                better = (relation.touching && !current.touching)
                    || (relation.touching == current.touching
                        && (relation.distance < current.distance - 0.5
                            || (abs(relation.distance - current.distance) <= 0.5
                                && relation.overlap > current.overlap)))
            } else {
                better = true
            }
            if better {
                best = (candidate.pane, relation.touching, relation.distance, relation.overlap)
            }
        }
        return best?.pane
    }

    /// How a candidate frame sits relative to the origin, in one direction.
    /// `nil` when it is not on that side at all.
    ///
    /// The half-point slack is for stacked arithmetic: panes that meet at a
    /// divider are a fraction of a point apart after rounding, and a plain `<`
    /// would call a neighbour across a two-point gap "not adjacent".
    private static func relation(from origin: PaneFrame, to candidate: PaneFrame,
                                 towards direction: Direction) -> (touching: Bool,
                                                                  distance: Double,
                                                                  overlap: Double)? {
        let overlapX = min(origin.maxX, candidate.maxX) - max(origin.x, candidate.x)
        let overlapY = min(origin.maxY, candidate.maxY) - max(origin.y, candidate.y)

        switch direction {
        case .right:
            guard candidate.x >= origin.maxX - 0.5 else { return nil }
            return (overlapY > 0, candidate.x - origin.maxX, overlapY)
        case .left:
            guard candidate.maxX <= origin.x + 0.5 else { return nil }
            return (overlapY > 0, origin.x - candidate.maxX, overlapY)
        case .down:
            guard candidate.y >= origin.maxY - 0.5 else { return nil }
            return (overlapX > 0, candidate.y - origin.maxY, overlapX)
        case .up:
            guard candidate.maxY <= origin.y + 0.5 else { return nil }
            return (overlapX > 0, origin.y - candidate.maxY, overlapX)
        }
    }
}
