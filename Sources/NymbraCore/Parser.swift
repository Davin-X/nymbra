/// The byte-level VT parser.
///
/// One state machine handles every sequence family, because they share the
/// entry rules and differ only in how they terminate:
///
/// | family | introduced by | ends at |
/// |---|---|---|
/// | escape | `ESC` | one final byte in `0x30...0x7E` |
/// | CSI | `ESC [` | one final byte in `0x40...0x7E` |
/// | OSC | `ESC ]` | `BEL` or `ST` (`ESC \`) |
/// | DCS | `ESC P` | `ST` |
/// | SOS/PM/APC | `ESC X`, `ESC ^`, `ESC _` | `ST` |
/// | charset | `ESC (` … | exactly one further byte |
///
/// C0 controls execute immediately in *any* state (that is why `^C` and `^G`
/// still work mid-sequence) except inside a string, where they are payload. The
/// parser is total: any byte sequence, valid or hostile, leaves the screen in a
/// defined state (invariant 3 in docs/ARCHITECTURE.md).
///
/// Written from ECMA-48 and the xterm control-sequence reference, not from
/// another emulator's source. See ADR-0001.
public final class Parser {

    public enum State: Equatable {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        case oscStringEscape
        case dcsEntry
        case dcsParam
        case dcsIntermediate
        case dcsPassthrough
        case dcsPassthroughEscape
        case dcsIgnore
        case sosPmApcString
        case sosPmApcEscape
    }

    public private(set) var state: State = .ground
    private let screen: Screen

    /// Bytes the terminal must send back to the shell (device status reports,
    /// device attributes). Wired to the PTY by `Terminal`.
    public var onResponse: (([UInt8]) -> Void)?
    /// A `BEL` was received.
    public var onBell: (() -> Void)?

    private var intermediates: [UInt8] = []
    private var privateMarkers: [UInt8] = []
    private var params = ParamBuilder()
    private var stringBuffer: [UInt8] = []
    private var utf8: [UInt8] = []

    public init(screen: Screen) {
        self.screen = screen
    }

    // MARK: - Entry points

    public func feed(_ bytes: [UInt8]) {
        for byte in bytes { advance(byte) }
    }

    public func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    // MARK: - State machine

    private func advance(_ byte: UInt8) {
        if byte == 0x1B {
            handleEscape()
            return
        }

        if byte < 0x20 || byte == 0x7F {
            switch state {
            case .oscString:
                if byte == 0x07 { dispatchString() }
                return                       // other C0 bytes are payload
            case .dcsPassthrough, .sosPmApcString:
                return                       // payload, not executable
            default:
                break
            }
            if byte == 0x18 || byte == 0x1A {   // CAN / SUB abort any sequence
                collectClear()
                state = .ground
                return
            }
            execute(byte)
            return
        }

        switch state {
        case .ground: ground(byte)
        case .escape: escape(byte)
        case .escapeIntermediate:
            if byte >= 0x20 && byte <= 0x2F {
                intermediates.append(byte)
            } else {
                escDispatch(byte, intermediates: intermediates)
                collectClear()
                state = .ground
            }
        case .csiEntry, .csiParam, .csiIntermediate, .csiIgnore: csi(byte)
        case .oscString: stringBuffer.append(byte)
        case .oscStringEscape: oscEscape(byte)
        case .dcsEntry, .dcsParam, .dcsIntermediate, .dcsPassthrough, .dcsIgnore: dcs(byte)
        case .dcsPassthroughEscape:
            if byte == 0x5C { collectClear(); state = .ground }
            else { collectClear(); state = .escape; advance(byte) }
        case .sosPmApcString:
            break                            // swallowed
        case .sosPmApcEscape:
            if byte == 0x5C { state = .ground }
            else { state = .escape; advance(byte) }
        }
    }

    private func handleEscape() {
        switch state {
        case .oscString: state = .oscStringEscape
        case .dcsPassthrough: state = .dcsPassthroughEscape
        case .sosPmApcString: state = .sosPmApcEscape
        default:
            flushUTF8()
            collectClear()
            state = .escape
        }
    }

    private func ground(_ byte: UInt8) {
        utf8.append(byte)
        let needed = Parser.utf8Length(utf8[0])
        if needed == 0 {
            utf8.removeAll()
            screen.put("\u{FFFD}")
            return
        }
        if utf8.count < needed { return }
        let bytes = utf8
        utf8.removeAll()
        screen.put(Parser.decode(bytes) ?? "\u{FFFD}")
    }

    private func escape(_ byte: UInt8) {
        switch byte {
        case 0x5B:                                   // '['  CSI
            collectClear()
            state = .csiEntry
        case 0x5D:                                   // ']'  OSC
            stringBuffer.removeAll()
            state = .oscString
        case 0x50:                                   // 'P'  DCS
            collectClear()
            state = .dcsEntry
        case 0x58, 0x5E, 0x5F:                       // SOS, PM, APC
            state = .sosPmApcString
        case 0x20...0x2F:                            // intermediate
            intermediates.append(byte)
            state = .escapeIntermediate
        case 0x30...0x7E:                            // final
            escDispatch(byte, intermediates: intermediates)
            collectClear()
            state = .ground
        default:
            state = .ground
        }
    }

    private func csi(_ byte: UInt8) {
        switch state {
        case .csiIgnore:
            if byte >= 0x40 && byte <= 0x7E { collectClear(); state = .ground }

        case .csiIntermediate:
            if byte >= 0x20 && byte <= 0x2F {
                intermediates.append(byte)
            } else if byte >= 0x40 && byte <= 0x7E {
                dispatchCSI(byte)
            } else {
                state = .csiIgnore
            }

        default:                                     // csiEntry, csiParam
            if byte >= 0x30 && byte <= 0x39 {
                params.digit(Int(byte - 0x30))
                state = .csiParam
            } else if byte == 0x3B {
                params.semicolon()
                state = .csiParam
            } else if byte == 0x3A {
                params.colon()
                state = .csiParam
            } else if byte >= 0x3C && byte <= 0x3F {
                if state == .csiEntry { privateMarkers.append(byte) } else { state = .csiIgnore }
            } else if byte >= 0x20 && byte <= 0x2F {
                intermediates.append(byte)
                state = .csiIntermediate
            } else if byte >= 0x40 && byte <= 0x7E {
                dispatchCSI(byte)
            } else {
                state = .csiIgnore
            }
        }
    }

    private func dispatchCSI(_ final: UInt8) {
        let groups = params.finish()
        csiDispatch(final, params: groups, intermediates: intermediates, privateMarkers: privateMarkers)
        collectClear()
        state = .ground
    }

    private func dcs(_ byte: UInt8) {
        switch state {
        case .dcsEntry, .dcsParam, .dcsIntermediate:
            // We implement no DCS sequence, so consume parameters and
            // intermediates and fall into passthrough.
            if byte >= 0x40 && byte <= 0x7E {
                state = .dcsPassthrough
            } else if byte >= 0x20 && byte <= 0x3F {
                break
            } else {
                state = .dcsIgnore
            }
        case .dcsIgnore:
            if byte >= 0x40 && byte <= 0x7E { state = .ground }
        default:
            break                                    // passthrough: data discarded
        }
    }

    private func oscEscape(_ byte: UInt8) {
        if byte == 0x5C {
            dispatchString()                         // ST
        } else {
            // Not ST: the OSC is abandoned and this byte starts a new sequence.
            stringBuffer.removeAll()
            collectClear()
            state = .escape
            advance(byte)
        }
    }

    private func collectClear() {
        intermediates.removeAll()
        privateMarkers.removeAll()
        params.reset()
    }

    // MARK: - Controls

    private func execute(_ byte: UInt8) {
        switch byte {
        case 0x07:
            onBell?()
        case 0x08:
            screen.backspace()
        case 0x09:
            screen.tab()
        case 0x0A, 0x0B, 0x0C:
            screen.lineFeed()
        case 0x0D:
            screen.carriageReturn()
        case 0x0E:
            screen.setShiftOut(true)                 // SO
        case 0x0F:
            screen.setShiftOut(false)                // SI
        default:
            break                                    // NUL, DEL, others
        }
    }

    // MARK: - ESC dispatch

    private func escDispatch(_ final: UInt8, intermediates: [UInt8]) {
        if let first = intermediates.first {
            switch first {
            case 0x28, 0x29:                         // ESC ( x / ESC ) x
                let charset: Screen.Charset = (final == 0x30) ? .decSpecialGraphics : .ascii
                screen.designateCharset(first == 0x28 ? 0 : 1, charset)
            case 0x23 where final == 0x38:           // ESC # 8
                screen.alignmentTest()
            default:
                break
            }
            return
        }

        switch final {
        case 0x37: screen.saveCursor()                                  // DECSC
        case 0x38: screen.restoreCursor()                               // DECRC
        case 0x44: screen.lineFeed()                                    // IND
        case 0x45: screen.carriageReturn(); screen.lineFeed()           // NEL
        case 0x4D: screen.reverseIndex()                                // RI
        case 0x48: screen.setTabStop()                                  // HTS
        case 0x63: screen.reset()                                       // RIS
        default: break                                                  // DECKPAM/PNM etc.
        }
    }

    // MARK: - CSI dispatch

    private func csiDispatch(
        _ final: UInt8,
        params: [[Int?]],
        intermediates: [UInt8],
        privateMarkers: [UInt8]
    ) {
        func value(_ index: Int, _ fallback: Int) -> Int {
            guard index < params.count,
                  let first = params[index].first,
                  let number = first else { return fallback }
            return number
        }
        func allValues() -> [Int] {
            params.compactMap { $0.first.flatMap { $0 } }
        }

        let isPrivate = privateMarkers.contains(0x3F)   // '?'

        // Sequences that carry intermediates, which are otherwise unimplemented.
        if intermediates == [0x21], final == 0x70 {     // CSI ! p  DECSTR
            screen.reset()
            return
        }
        if intermediates == [0x20], final == 0x71 {     // CSI SP q DECSCUSR
            if let style = Screen.CursorStyle(decscusr: value(0, 0)) { screen.setCursorStyle(style) }
            return
        }
        guard intermediates.isEmpty else { return }

        switch final {
        case 0x40: screen.insertChars(value(0, 1))                              // ICH
        case 0x41: screen.cursorUp(value(0, 1))                                 // CUU
        case 0x42: screen.cursorDown(value(0, 1))                               // CUD
        case 0x43: screen.cursorForward(value(0, 1))                            // CUF
        case 0x44: screen.cursorBack(value(0, 1))                               // CUB
        case 0x45: screen.nextLine(value(0, 1))                                 // CNL
        case 0x46: screen.previousLine(value(0, 1))                             // CPL
        case 0x47: screen.setColumn(value(0, 1))                                // CHA
        case 0x48, 0x66:                                                        // CUP, HVP
            screen.setCursorPosition(row: value(0, 1), col: value(1, 1))
        case 0x49:                                                              // CHT
            for _ in 0..<value(0, 1) { screen.tab() }
        case 0x4A: screen.eraseInDisplay(value(0, 0))                           // ED
        case 0x4B: screen.eraseInLine(value(0, 0))                              // EL
        case 0x4C: screen.insertLines(value(0, 1))                              // IL
        case 0x4D: screen.deleteLines(value(0, 1))                              // DL
        case 0x50: screen.deleteChars(value(0, 1))                              // DCH
        case 0x53: screen.scrollUp(value(0, 1))                                 // SU
        case 0x54: screen.scrollDown(value(0, 1))                               // SD
        case 0x58: screen.eraseChars(value(0, 1))                               // ECH
        case 0x5A:                                                              // CBT
            for _ in 0..<value(0, 1) { screen.backTab() }
        case 0x60: screen.setColumn(value(0, 1))                                // HPA
        case 0x61: screen.cursorForward(value(0, 1))                            // HPR
        case 0x63: reportDeviceAttributes(private: isPrivate)                   // DA
        case 0x64: screen.setRow(value(0, 1))                                   // VPA
        case 0x65: screen.cursorDown(value(0, 1))                               // VPR
        case 0x67: screen.clearTabStop(value(0, 0))                             // TBC
        case 0x68:                                                              // SM / DECSET
            for mode in allValues() {
                if isPrivate { screen.setMode(mode, true) } else { screen.setStandardMode(mode, true) }
            }
        case 0x6C:                                                              // RM / DECRST
            for mode in allValues() {
                if isPrivate { screen.setMode(mode, false) } else { screen.setStandardMode(mode, false) }
            }
        case 0x6D: screen.applySGR(params)                                      // SGR
        case 0x6E: reportStatus(private: isPrivate, request: value(0, 0))       // DSR
        case 0x72: screen.setScrollRegion(top: value(0, 1), bottom: value(1, screen.rows))  // DECSTBM
        case 0x73: if !isPrivate { screen.saveCursor() }                        // SCOSC
        case 0x75: screen.restoreCursor()                                       // SCORC
        default: break
        }
    }

    // MARK: - Reports

    private func reportDeviceAttributes(private isPrivate: Bool) {
        // Advertised deliberately modestly: we claim VT100 + advanced video,
        // not the full xterm capability set. Honesty here costs nothing and
        // avoids programs enabling protocols we do not implement.
        respond(isPrivate
            ? [0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x32, 0x63]                          // ESC [ ? 1 ; 2 c
            : [0x1B, 0x5B, 0x3E, 0x31, 0x3B, 0x30, 0x3B, 0x30, 0x63])             // ESC [ > 1 ; 0 ; 0 c
    }

    private func reportStatus(private isPrivate: Bool, request: Int) {
        switch request {
        case 5:
            respond([0x1B, 0x5B, 0x30, 0x6E])                                     // ESC [ 0 n
        case 6:
            let row = screen.cursor.row + 1
            let col = screen.cursor.col + 1
            let report = isPrivate ? "\u{1B}[?\(row);\(col)R" : "\u{1B}[\(row);\(col)R"
            respond(Array(report.utf8))
        default:
            break
        }
    }

    private func respond(_ bytes: [UInt8]) {
        onResponse?(bytes)
    }

    // MARK: - String sequences

    private func dispatchString() {
        defer {
            stringBuffer.removeAll()
            collectClear()
            state = .ground
        }
        // Everything is `Ps ; Pt`. We act on the title and deliberately ignore
        // the rest: no clipboard writes (OSC 52), no colour changes (OSC 4/10),
        // no hyperlinks yet (OSC 8), no shell marks yet (OSC 133, M3).
        guard let separator = stringBuffer.firstIndex(of: 0x3B) else { return }
        let command = String(decoding: stringBuffer[..<separator], as: UTF8.self)
        let payload = String(decoding: stringBuffer[stringBuffer.index(after: separator)...], as: UTF8.self)
        switch command {
        case "0", "2": screen.title = payload
        default: break
        }
    }

    // MARK: - UTF-8

    private func flushUTF8() {
        guard !utf8.isEmpty else { return }
        let bytes = utf8
        utf8.removeAll()
        screen.put(Parser.decode(bytes) ?? "\u{FFFD}")
    }

    private static func utf8Length(_ first: UInt8) -> Int {
        if first < 0x80 { return 1 }
        if first >= 0xC2 && first <= 0xDF { return 2 }
        if first >= 0xE0 && first <= 0xEF { return 3 }
        if first >= 0xF0 && first <= 0xF4 { return 4 }
        return 0
    }

    private static func decode(_ bytes: [UInt8]) -> Unicode.Scalar? {
        if bytes.count == 1 { return Unicode.Scalar(UInt32(bytes[0])) }
        return String(decoding: bytes, as: UTF8.self).unicodeScalars.first
    }
}

/// Builds the parameter list of a CSI sequence.
///
/// `1;2m` becomes `[[1], [2]]` and `38:2::255:0:0m` becomes `[[38, 2, nil, 255, 0, 0]]`,
/// so colon sub-parameters survive without a second representation.
private struct ParamBuilder {
    private var groups: [[Int?]] = []
    private var sub: [Int?] = []
    private var value: Int?
    private var touched = false

    mutating func reset() {
        groups = []
        sub = []
        value = nil
        touched = false
    }

    mutating func digit(_ number: Int) {
        value = min((value ?? 0) * 10 + number, 999_999)
        touched = true
    }

    mutating func semicolon() {
        sub.append(value)
        value = nil
        groups.append(sub)
        sub = []
        touched = true
    }

    mutating func colon() {
        sub.append(value)
        value = nil
        touched = true
    }

    mutating func finish() -> [[Int?]] {
        if touched || !sub.isEmpty || value != nil {
            sub.append(value)
            groups.append(sub)
            sub = []
        }
        let result = groups
        groups = []
        touched = false
        return result
    }
}

public extension Array where Element == [Int?] {
    /// Read parameter `index`, taking its first sub-parameter. `fallback` is
    /// returned for a missing or empty parameter, which is what "a param of 0
    /// means the default" requires.
    func value(_ index: Int, sub: Int = 0, or fallback: Int) -> Int {
        guard index < count else { return fallback }
        let group = self[index]
        guard sub < group.count, let number = group[sub] else { return fallback }
        return number
    }
}
