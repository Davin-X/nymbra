/// A colour as the terminal protocols express it.
///
/// Indexed colours 0...15 are the system colours, 16...231 a 6×6×6 cube and
/// 232...255 a greyscale ramp. Resolving an index to RGB is the renderer's job,
/// not the model's.
public enum Colour: Equatable, Hashable {
    /// Whatever the terminal is configured to use — not a colour in itself.
    case `default`
    case indexed(UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
}

/// The underline styles ECMA-48 defines, which SGR 4:x selects.
public enum UnderlineStyle: Int, Equatable, Hashable, CaseIterable {
    case none = 0
    case single = 1
    case double = 2
    case curly = 3
    case dotted = 4
    case dashed = 5
}

/// The graphic rendition applied to a cell: SGR state, nothing more.
///
/// Deliberately a value type: cells carry a copy, so changing the pen never
/// retroactively alters what has already been drawn.
public struct Attributes: Equatable, Hashable {
    public var foreground: Colour = .default
    public var background: Colour = .default
    public var underlineColour: Colour = .default
    public var bold = false
    public var faint = false
    public var italic = false
    public var underline: UnderlineStyle = .none
    public var blink = false
    public var inverse = false
    public var conceal = false
    public var strike = false

    public init() {}
}
