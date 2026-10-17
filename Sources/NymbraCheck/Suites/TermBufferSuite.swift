import NymbraCore

/// Behaviour of the screen buffer, as it exists today.
///
/// These encode the *current* contract, including its deliberate limitations,
/// so that the VT parser rewrite has to make them pass or explicitly replace
/// them rather than silently change behaviour.
func termBufferSuite(_ h: Harness) {
    h.suite("TermBuffer")

    func text(_ buffer: TermBuffer, rows: Int = 50) -> [String] {
        buffer.visible(rows).map(TermBuffer.decode)
    }

    do {
        let b = TermBuffer()
        b.feed(Array("hello".utf8))
        h.equal(text(b), ["hello"], "plain text stays on one line")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("one\ntwo".utf8))
        h.equal(text(b), ["one", "two"], "newline starts a new line")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("abc\rdef".utf8))
        h.equal(text(b), ["abcdef"], "CR is ignored until we track columns")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("ab\tX".utf8))
        h.equal(text(b), ["ab      X"], "tab pads to the next multiple of eight")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("abc\u{08}".utf8))
        h.equal(text(b), ["ab"], "backspace removes the last byte")
    }

    do {
        let b = TermBuffer()
        b.feed([0x08, 0x08])
        h.equal(text(b), [""], "backspace on an empty line is harmless")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("\u{1B}[31mred\u{1B}[0m".utf8))
        h.equal(text(b), ["red"], "CSI sequences are swallowed")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("\u{1B}]0;title\u{07}body".utf8))
        h.equal(text(b), ["body"], "OSC sequences are swallowed (BEL terminator)")
    }

    // Regression: an earlier version ended OSC at the first byte >= 0x40,
    // so a title containing a letter leaked "itle" into the output.
    do {
        let b = TermBuffer()
        b.feed(Array("\u{1B}]0;My Title\u{07}body".utf8))
        h.equal(text(b), ["body"], "OSC payload may contain letters")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("\u{1B}]8;;https://example.com\u{1B}\\link".utf8))
        h.equal(text(b), ["link"], "OSC sequences are swallowed (ST terminator)")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("\u{1B}(Btext".utf8))
        h.equal(text(b), ["text"], "charset designators consume exactly one byte")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("→ λ ✓".utf8))
        h.equal(text(b), ["→ λ ✓"], "multi-byte UTF-8 survives")
    }

    do {
        let b = TermBuffer()
        b.feed(Array("1\n2\n3\n4\n5".utf8))
        h.equal(b.visible(2).map(TermBuffer.decode), ["4", "5"], "visible returns the tail")
    }

    do {
        let b = TermBuffer(historyLimit: 10)
        b.feed(Array((1...50).map { "\($0)\n" }.joined().utf8))
        h.expect(b.lines.count <= 10, "history is bounded (got \(b.lines.count))")
    }
}
