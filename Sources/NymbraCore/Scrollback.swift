/// The lines that have scrolled off the top of the primary screen, oldest first.
///
/// A ring buffer rather than an array: once the history is full, every new line
/// would otherwise shift every line before it (`removeFirst` on ten thousand
/// rows, once per line printed). Here a full buffer overwrites its oldest slot
/// and moves its head, so appending is O(1) however long the history is.
///
/// It is a `RandomAccessCollection` indexed from 0 (oldest), so callers read it
/// exactly as they read the array it replaced.
public struct Scrollback: RandomAccessCollection, MutableCollection {
    public typealias Element = [Cell]

    private var storage: [[Cell]] = []
    /// Where the oldest line lives in `storage`. Non-zero only once full.
    private var head = 0

    /// Every line ever appended, including those since dropped. Monotonic, so a
    /// viewport scrolled up into history can tell how far the content under it
    /// moved between two looks — see `TermView.screenDidUpdate`.
    public private(set) var appendedCount = 0

    public init() {}

    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }

    public subscript(position: Int) -> [Cell] {
        get { storage[physical(position)] }
        set { storage[physical(position)] = newValue }
    }

    private func physical(_ index: Int) -> Int {
        precondition(index >= 0 && index < storage.count, "scrollback index out of range")
        let raw = head + index
        return raw < storage.count ? raw : raw - storage.count
    }

    /// Add a line, dropping the oldest ones so no more than `limit` are kept.
    public mutating func append(_ line: [Cell], limit: Int) {
        appendedCount &+= 1
        guard limit > 0 else {
            removeAll()
            return
        }
        if storage.count < limit {
            // Growing: only possible while the buffer is linear (head == 0),
            // unless the limit was raised after it filled — straighten it first.
            if head != 0 { linearize() }
            storage.append(line)
            return
        }
        if storage.count > limit {
            // The limit was lowered: keep the newest `limit - 1`, then add.
            linearize()
            storage.removeFirst(storage.count - limit + 1)
            storage.append(line)
            return
        }
        // Full: overwrite the oldest line, which is now the newest.
        storage[head] = line
        head = head + 1 == storage.count ? 0 : head + 1
    }

    public mutating func removeAll() {
        storage.removeAll()
        head = 0
    }

    private mutating func linearize() {
        guard head != 0 else { return }
        storage = Array(storage[head...] + storage[..<head])
        head = 0
    }
}
