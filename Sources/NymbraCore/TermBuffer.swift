/// A deliberately naive screen buffer.
///
/// This is scaffolding for the real VT parser, not the real thing. It stores
/// raw bytes per line and decodes only at draw time, so multi-byte UTF-8
/// survives even though no emulation happens. Escape sequences are discarded
/// so that ordinary output looks clean.
///
/// Known gaps, all intentional for now: no cursor, no SGR colour, no alt
/// screen, no scroll regions, no wrapping at the column limit, no scrollback
/// that survives a resize.
public final class TermBuffer {
    /// Lines of raw bytes. Always at least one (possibly empty) line.
    public private(set) var lines: [[UInt8]] = [[]]

    private let historyLimit: Int

    /// Escape-sequence state machine.
    ///
    /// The three sequence families terminate differently, which is the classic
    /// place to get this wrong:
    ///   - CSI (`ESC [`) ends at the first byte in `0x40...0x7E`
    ///   - OSC (`ESC ]`) ends at BEL or ST (`ESC \`) — it may contain *any*
    ///     other byte, including ones that look like CSI finals
    ///   - charset designators (`ESC (` / `ESC )`) are exactly two bytes
    private enum Escape {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
        case charset
    }

    private var state: Escape = .ground

    public init(historyLimit: Int = 10_000) {
        self.historyLimit = historyLimit
    }

    /// Feed a chunk of shell output.
    public func feed(_ bytes: [UInt8]) {
        for byte in bytes { advance(byte) }
    }

    private func advance(_ byte: UInt8) {
        switch state {
        case .ground:
            handleGround(byte)
        case .escape:
            switch byte {
            case 0x5B: state = .csi          // '['
            case 0x5D: state = .osc          // ']'
            case 0x28, 0x29: state = .charset // '(' or ')'
            default: state = .ground         // two-byte escape (e.g. ESC =)
            }
        case .csi:
            if byte >= 0x40 && byte <= 0x7E { state = .ground }
        case .osc:
            if byte == 0x07 { state = .ground }          // BEL
            else if byte == 0x1B { state = .oscEscape }  // possible ST
        case .oscEscape:
            state = .ground                              // ESC \ = ST
        case .charset:
            state = .ground
        }
    }

    private func handleGround(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            state = .escape
        case 0x0A:
            lines.append([])
            trim()
        case 0x0D:
            break                       // CR: no column tracking yet
        case 0x09:
            let pad = 8 - (lines[lines.count - 1].count % 8)
            lines[lines.count - 1].append(contentsOf: [UInt8](repeating: 0x20, count: pad))
        case 0x07, 0x00:
            break                       // bell / NUL
        case 0x08:
            if !lines[lines.count - 1].isEmpty { lines[lines.count - 1].removeLast() }
        default:
            if byte >= 0x20 { lines[lines.count - 1].append(byte) }
        }
    }

    private func trim() {
        if lines.count > historyLimit {
            lines.removeFirst(lines.count - historyLimit)
        }
    }

    /// The last `rows` lines, oldest first — what a view should draw.
    public func visible(_ rows: Int) -> [[UInt8]] {
        let start = max(0, lines.count - rows)
        return Array(lines[start...])
    }

    /// Decode one stored line to a string.
    public static func decode(_ line: [UInt8]) -> String {
        String(decoding: line, as: UTF8.self)
    }
}
