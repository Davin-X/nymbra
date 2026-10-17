import Foundation

/// The cell grid a terminal shows: the two numbers a PTY is told about.
///
/// These two are trivially swappable, and swapping them is silent. The shell is
/// handed a "width" that is really a height, formats its output for it, and then
/// every wide line wraps half-way through a column — `eza`, `ls -l`, `git log`,
/// anything column-aligned. The output looks like a rendering fault while the
/// real fault is a size that was never agreed on.
///
/// Passing one labelled value across the seam is what makes the transposition
/// unrepresentable rather than merely unlikely. See
/// [ARCHITECTURE invariant 8](docs/ARCHITECTURE.md).
public struct GridSize: Equatable, Sendable {
    public let rows: Int
    public let cols: Int

    /// A grid of at least one row and one column: a shell told it has zero
    /// columns has nowhere to write, and tools that size columns from the
    /// terminal divide by them.
    public init(rows: Int, cols: Int) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
    }

    /// The grid that fits a view `width` × `height`, allowing `paddingX` and
    /// `paddingY` around the cells and a cell size of `cellWidth` × `cellHeight`.
    ///
    /// This is the same arithmetic the renderer uses to place every glyph, so a
    /// grid that fits here is a grid that fits on screen.
    public init(
        fittingWidth width: Double,
        height: Double,
        paddingX: Double,
        paddingY: Double,
        cellWidth: Double,
        cellHeight: Double
    ) {
        self.init(
            rows: GridSize.dimension(height - paddingY * 2, cellHeight),
            cols: GridSize.dimension(width - paddingX * 2, cellWidth)
        )
    }

    /// No real terminal is wider or taller than this; the cap is here so a
    /// nonsensical measurement cannot become a nonsensical allocation.
    private static let maximumDimension = 10_000

    /// How many whole cells fit, clamped to at least one. A cell measured as zero
    /// (a font that failed to load) is treated as "one cell", not as an infinity.
    private static func dimension(_ available: Double, _ cell: Double) -> Int {
        guard available.isFinite, cell.isFinite, cell > 0 else { return 1 }
        let count = available / cell
        guard count.isFinite else { return 1 }
        return Int(min(max(count, 1), Double(maximumDimension)))
    }
}
