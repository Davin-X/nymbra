import NymbraCore

private final class Recorder {
    let screen = Screen(rows: 24, cols: 80)
    lazy var parser = Parser(screen: screen)
    var responses: [String] = []
    var bells = 0
    var marks: [ShellMark] = []

    init() {
        parser.onResponse = { [weak self] bytes in
            self?.responses.append(String(decoding: bytes, as: UTF8.self))
        }
        parser.onBell = { [weak self] in self?.bells += 1 }
        parser.onShellMark = { [weak self] in self?.marks.append($0) }
    }

    func feed(_ text: String) { parser.feed(text) }
    func feed(_ bytes: [UInt8]) { parser.feed(bytes) }
    func row(_ index: Int) -> String { screen.rowText(index) }
}

/// Deterministic PRNG, so a fuzz failure is reproducible.
private struct RNG {
    var state: UInt64

    mutating func byte() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8((state >> 33) & 0xFF)
    }

    mutating func upto(_ upper: Int) -> Int { Int(byte()) % max(1, upper) }
}

/// The parser: sequence families, their termination rules, and totality.
func parserSuite(_ h: Harness) {
    h.suite("Parser")

    // MARK: OSC

    do {
        let t = Recorder()
        t.feed("\u{1B}]0;title\u{07}body")
        h.equal(t.row(0), "body", "OSC ends at BEL")
    }

    // Regression: an earlier version ended OSC at the first byte >= 0x40, so a
    // title containing a letter leaked into the output.
    do {
        let t = Recorder()
        t.feed("\u{1B}]0;My Title\u{07}body")
        h.equal(t.row(0), "body", "an OSC payload may contain any letter")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}]8;;https://example.com\u{1B}\\link")
        h.equal(t.row(0), "link", "OSC ends at ST (ESC backslash)")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}]0;hello\u{07}")
        h.equal(t.screen.title, "hello", "OSC 0 sets the window title")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}]2;renamed\u{1B}\\")
        h.equal(t.screen.title, "renamed", "OSC 2 sets the window title, ST terminated")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}]52;c;aGVsbG8=\u{07}safe")
        h.equal(t.row(0), "safe", "OSC 52 (clipboard) is swallowed, never acted on")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}]0;unterminated")
        h.equal(t.row(0), "", "an unterminated OSC consumes the rest of the input")
    }

    // MARK: OSC 133 (shell marks)

    do {
        let t = Recorder()
        t.feed("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}ls\u{1B}]133;C\u{07}file\u{1B}]133;D;0\u{07}")
        h.equal(t.marks, [.promptStart, .commandStart, .commandExecuted, .commandFinished(0)],
                "a whole command's marks arrive in order, with its exit status")
        h.equal(t.row(0), "$ lsfile", "no shell mark reaches the screen")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}]133;D\u{07}")
        h.equal(t.marks, [.commandFinished(nil)],
                "a finish with no status is not assumed to have succeeded")
        t.feed("\u{1B}]133;D;130\u{1B}\\")
        h.equal(t.marks.last, .commandFinished(130), "the status survives an ST-terminated mark")
        t.feed("\u{1B}]133;D;\u{07}")
        h.equal(t.marks.last, .commandFinished(nil), "an empty status is no status")
        t.feed("\u{1B}]133;D;not-a-number\u{07}")
        h.equal(t.marks.last, .commandFinished(nil), "a status that is not a number is not invented")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}]133;Z\u{07}x")
        h.equal(t.marks, [], "an unrecognised shell mark is dropped, not guessed at")
        h.equal(t.row(0), "x", "an unrecognised shell mark is not drawn")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}]1337;A\u{07}x")
        h.equal(t.marks, [], "a code that merely starts with 133 is not OSC 133")
        h.equal(t.row(0), "x", "an unrelated OSC code still does not draw itself")
    }

    // MARK: CSI

    do {
        let t = Recorder()
        t.feed("\u{1B}[31mred\u{1B}[0m")
        h.equal(t.row(0), "red", "CSI sequences are consumed, not printed")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[2Jmid")
        h.equal(t.row(0), "mid", "an intermediate-free CSI dispatches")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[1;2 qignored")
        h.equal(t.row(0), "ignored", "an unimplemented CSI with intermediates is ignored")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[!pX")
        h.equal(t.row(0), "X", "DECSTR is accepted")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[3 q")
        h.equal(t.screen.cursor.style, .underlineBlink, "DECSCUSR 3 is a blinking underline")
        t.feed("\u{1B}[4 q")
        h.equal(t.screen.cursor.style, .underline, "DECSCUSR 4 is a steady underline")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[99999999999mX")
        h.equal(t.screen.cell(row: 0, col: 0).attributes, Attributes(),
                "an absurd parameter is clamped, not a crash")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[38;5;300mX")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.foreground, .indexed(255),
                "an out-of-range palette index is clamped")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[38:2:0:255:0:1mX")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.foreground, .rgb(r: 255, g: 0, b: 1),
                "the colon form with a colour-space slot is decoded")
    }

    do {
        // CAN (0x18) aborts whatever is in flight.
        let t = Recorder()
        t.feed("\u{1B}[31\u{18}plain")
        h.equal(t.row(0), "plain", "CAN aborts a CSI in flight")
        h.equal(t.screen.cell(row: 0, col: 0).attributes.foreground, .default,
                "and the aborted sequence has no effect")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[?25")
        t.feed("lX")
        h.equal(t.row(0), "X", "a sequence may be split across reads")
        h.expect(!t.screen.cursor.visible, "and state carries over between chunks")
    }

    do {
        // C0 controls execute immediately, even mid-sequence.
        let t = Recorder()
        t.feed("\u{1B}[3\u{0A}1mX")
        h.equal(t.row(1), "X", "LF inside a sequence still executes")
        h.equal(t.screen.cell(row: 1, col: 0).attributes.foreground, .indexed(1),
                "and the sequence still completes")
    }

    do {
        // An intermediate is followed by the final byte, which is consumed as
        // part of the sequence — so the byte after '!' disappears.
        let t = Recorder()
        t.feed("\u{1B}[1;2;3!xrest")
        h.equal(t.row(0), "rest", "the byte after an intermediate is consumed as the final byte")
    }

    // MARK: ESC

    do {
        let t = Recorder()
        t.feed("a\u{1B}Db")
        h.equal(t.row(0), "a", "IND moves to the next line")
        h.equal(t.row(1), " b", "without returning to column zero")
    }

    do {
        let t = Recorder()
        t.feed("ab\u{1B}Ec")
        h.equal(t.row(1), "c", "NEL moves to the next line and back to column zero")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}(Btext")
        h.equal(t.row(0), "text", "a charset designator consumes exactly one byte")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[3g\u{1B}[5G\u{1B}H\u{1B}[1Ga\tb")
        h.equal(t.row(0), "a   b", "HTS sets a stop that tab advances to")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}#8\u{1B}c\u{1B}=ok")
        h.equal(t.row(0), "ok", "DECALN plus RIS leaves a usable screen")
    }

    // MARK: DCS, SOS, PM, APC

    do {
        let t = Recorder()
        t.feed("\u{1B}P1;2;3zpayload\u{1B}\\after")
        h.equal(t.row(0), "after", "a DCS body is swallowed through ST")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}_hidden\u{1B}\\after")
        h.equal(t.row(0), "after", "an APC string is swallowed through ST")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}Xhidden\u{1B}\\after")
        h.equal(t.row(0), "after", "a SOS string is swallowed through ST")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}^hidden\u{1B}\\after")
        h.equal(t.row(0), "after", "a PM string is swallowed through ST")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}Pq#0;2;0;0;0\u{1B}\\")
        h.equal(t.row(0), "", "a sixel header is ignored without printing")
    }

    // MARK: Reports

    do {
        let t = Recorder()
        t.feed("\u{1B}[5n")
        h.equal(t.responses, ["\u{1B}[0n"], "DSR 5 reports that the terminal is ready")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[3;7H\u{1B}[6n")
        h.equal(t.responses, ["\u{1B}[3;7R"], "DSR 6 reports the cursor position, 1-based")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[?1;2;3c")
        h.equal(t.responses, ["\u{1B}[?1;2c"], "primary DA answers modestly (VT100 + AVO)")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[>c")
        h.equal(t.responses, ["\u{1B}[>1;0;0c"], "secondary DA is answered")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[99n")
        h.equal(t.responses.count, 0, "an unknown DSR request is not answered")
    }

    do {
        let t = Recorder()
        t.feed("\u{07}text")
        h.equal(t.bells, 1, "BEL is reported")
        h.equal(t.row(0), "text", "and prints nothing")
    }

    // MARK: UTF-8

    do {
        let t = Recorder()
        t.feed([0xE2, 0x86])
        t.feed([0x92])
        h.equal(t.row(0), "\u{2192}", "a multi-byte scalar split across reads reassembles")
    }

    do {
        let t = Recorder()
        t.feed("\u{1B}[1m\u{1B}[0m\u{2192}ok")
        h.equal(t.row(0), "\u{2192}ok", "multi-byte UTF-8 is not confused with control bytes")
    }

    do {
        let t = Recorder()
        t.feed([0xE2, 0x86])
        t.feed("\u{1B}[0m")
        h.equal(t.row(0), "\u{FFFD}", "a truncated multi-byte scalar becomes U+FFFD")
    }

    do {
        let t = Recorder()
        t.feed([0x80, 0x41])
        h.equal(t.row(0), "\u{FFFD}A", "a stray continuation byte becomes U+FFFD")
    }

    // MARK: Totality

    do {
        // The parser must survive anything. A terminal reads bytes it did not
        // author, including bytes returned over ssh.
        let t = Recorder()
        var rng = RNG(state: 0x9E37_79B9_7F4A_7C15)
        for _ in 0..<400 {
            let count = 1 + rng.upto(512)
            var chunk = [UInt8]()
            chunk.reserveCapacity(count)
            for _ in 0..<count { chunk.append(rng.byte()) }
            t.feed(chunk)
        }
        h.expect(true, "400 rounds of random bytes did not crash")
        h.expect(t.screen.cursor.row >= 0 && t.screen.cursor.row < t.screen.rows,
                 "cursor row stayed in bounds")
        h.expect(t.screen.cursor.col >= 0 && t.screen.cursor.col < t.screen.cols,
                 "cursor col stayed in bounds")
        h.expect(t.screen.scrollTop >= 0 && t.screen.scrollTop < t.screen.scrollBottom,
                 "scroll margins stayed ordered")
        h.expect(t.screen.scrollBottom < t.screen.rows, "bottom margin stayed in bounds")
        h.expect(t.screen.scrollback.count <= t.screen.scrollbackLimit, "scrollback stayed bounded")
        t.feed("still alive")
        h.expect(t.row(t.screen.cursor.row).hasSuffix("still alive"),
                 "and the screen is still usable afterwards")
    }
}
