import Foundation
import NymbraCore

/// The grid, asserted arithmetically.
///
/// This suite exists because `ll` (an `eza` alias) came out sliced in half —
/// every entry on two rows, the year split from the month — and the cause was
/// not the renderer at all: the view reported its grid to the shell as
/// `(cols, rows)` while the consumer read it as `(rows, cols)`, so the shell
/// formatted its long listing for a width equal to the window's *height*.
///
/// The fix makes the pair a single labelled value. What is left to assert is the
/// arithmetic that produces it, and the one property a transposed grid loses: in
/// a window that is wider than it is tall, there are more columns than rows.
func gridSuite(_ h: Harness) {
    h.suite("grid")

    // MARK: A normal window

    // 1000x640 at a nominal 8x16 cell with the view's own padding: 122 columns of
    // 8 fit in the 980 that is left, and 39 rows of 16 fit in the 624.
    let laptop = GridSize(
        fittingWidth: 1000, height: 640,
        paddingX: 10, paddingY: 8,
        cellWidth: 8, cellHeight: 16
    )
    h.equal(laptop.cols, 122, "a 1000-wide window at 8px per column fits 122 columns")
    h.equal(laptop.rows, 39, "a 640-high window at 16px per row fits 39 rows")
    h.expect(laptop.cols > laptop.rows,
             "a window wider than it is tall has more columns than rows, not fewer")

    // MARK: The transposition itself

    // The two numbers are distinct values with distinct meanings; the whole point
    // of the type is that swapping them produces a *different* grid rather than
    // an equivalent one.
    h.expect(GridSize(rows: 39, cols: 122) != GridSize(rows: 122, cols: 39),
             "a grid and its transpose are not equal, so a swap cannot pass unnoticed")
    h.equal(GridSize(rows: 39, cols: 122).cols, 122, "the columns are the columns")
    h.equal(GridSize(rows: 39, cols: 122).rows, 39, "the rows are the rows")

    // MARK: Degenerate windows

    // Narrower than the padding: there is still one usable cell, because a shell
    // told it has zero columns has nowhere to write and divides by the width.
    let none = GridSize(
        fittingWidth: 4, height: 4,
        paddingX: 10, paddingY: 8,
        cellWidth: 8, cellHeight: 16
    )
    h.equal(none.rows, 1, "a window smaller than its own padding still has one row")
    h.equal(none.cols, 1, "a window smaller than its own padding still has one column")

    h.equal(GridSize(rows: 0, cols: 0), GridSize(rows: 1, cols: 1),
            "a zero-sized grid is clamped to one cell")
    h.equal(GridSize(rows: -5, cols: 3), GridSize(rows: 1, cols: 3),
            "a negative row count is clamped, not propagated")

    // A font that measured as zero must not become an infinite grid.
    let zeroCell = GridSize(
        fittingWidth: 1000, height: 640,
        paddingX: 0, paddingY: 0,
        cellWidth: 0, cellHeight: 0
    )
    h.equal(zeroCell, GridSize(rows: 1, cols: 1),
            "a zero-width cell is treated as one cell, not as an infinity")

    // MARK: Bounds

    // A nonsensical measurement is capped rather than turned into an allocation.
    let absurd = GridSize(
        fittingWidth: 1e9, height: 1e9,
        paddingX: 0, paddingY: 0,
        cellWidth: 1, cellHeight: 1
    )
    h.expect(absurd.cols <= 10_000, "an absurd width is capped (\(absurd.cols) columns)")
    h.expect(absurd.rows <= 10_000, "an absurd height is capped (\(absurd.rows) rows)")

    // MARK: The model takes the same fields

    // The grid only reaches a shell through `Screen.resize`. Its fields are
    // labelled too, but the transposition originally arrived here through a
    // caller, so the destination is pinned as well.
    let screen = Screen(rows: 24, cols: 80)
    screen.resize(rows: laptop.rows, cols: laptop.cols)
    h.equal(screen.rows, 39, "the model's rows are the grid's rows")
    h.equal(screen.cols, 122, "the model's columns are the grid's columns")
}
