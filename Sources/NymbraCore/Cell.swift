/// One cell of the grid.
///
/// A cell is usually a single scalar, which needs no allocation. Grapheme
/// clusters (combining marks, ZWJ emoji) are the exception and take a `String`,
/// so the common path stays allocation-free as invariant 2 requires.
public struct Cell: Equatable {
    public enum Content: Equatable {
        case empty
        case scalar(Unicode.Scalar)
        /// A base scalar plus combining marks, or a ZWJ sequence.
        case cluster(String)
    }

    public var content: Content
    public var attributes: Attributes

    /// True for the *second* cell of a double-width character. It holds no
    /// content of its own: the scalar lives in the cell to its left, and
    /// rendering must skip it. Kept explicit so that overwriting half of a wide
    /// character is detectable.
    public var isWideContinuation: Bool

    public init(
        content: Content = .empty,
        attributes: Attributes = Attributes(),
        isWideContinuation: Bool = false
    ) {
        self.content = content
        self.attributes = attributes
        self.isWideContinuation = isWideContinuation
    }

    /// True for a cell with no character of its own (a blank, or the trailing
    /// half of a wide character).
    public var isBlank: Bool {
        if case .empty = content { return true }
        return false
    }

    /// The scalar this cell contributes, or a space for a blank. Wide
    /// continuations contribute nothing, which is what keeps them from being
    /// measured twice — they are skipped in reflow before this is ever called.
    public var scalarOrBlank: Unicode.Scalar {
        switch content {
        case .empty: return " "
        case .scalar(let scalar): return scalar
        case .cluster(let cluster): return cluster.unicodeScalars.first ?? " "
        }
    }

    /// What this cell contributes to a rendered line. A wide continuation
    /// contributes nothing, because its scalar is already in the previous cell.
    public var text: String {
        switch content {
        case .empty: return isWideContinuation ? "" : " "
        case .scalar(let scalar): return String(scalar)
        case .cluster(let cluster): return cluster
        }
    }
}
