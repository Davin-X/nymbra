import AppKit
import CoreText
import Foundation
import NymbraCore

/// Font resolution, in one place.
///
/// The terminal grid and the settings preview must resolve a font the same way,
/// or the preview is a polite word for "something else". The fallback matters as
/// much as the lookup: a family that does not exist is substituted silently by
/// CoreText, often with something that is not monospaced, which would break the
/// grid outright.
enum Fonts {

    /// The font for a configuration, falling back to Menlo when the named family
    /// does not resolve.
    static func resolve(_ configuration: Configuration) -> CTFont {
        let family = configuration.appearance.fontFamily
        let size = CGFloat(configuration.appearance.fontSize)

        let requested = CTFontCreateWithName(family as CFString, size, nil)
        let resolved = CTFontCopyFamilyName(requested) as String
        guard resolved.caseInsensitiveCompare(family) != .orderedSame else { return requested }

        FileHandle.standardError.write(
            Data("nymbra: no font family \"\(family)\"; using Menlo\n".utf8)
        )
        return CTFontCreateWithName("Menlo" as CFString, size, nil)
    }

    /// The bold face, or the regular one when there is no bold face to be had.
    static func bold(_ font: CTFont) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
    }

    /// The advance width of `M`, which every glyph in a monospaced font shares.
    /// The grid is measured from this rather than assumed.
    static func advanceWidth(of font: CTFont) -> CGFloat {
        var character: UniChar = 0x4D
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }

    /// The line height: ascent, descent and leading, rounded to a whole pixel so
    /// rows do not drift by fractions of a point down a long screen.
    static func lineHeight(of font: CTFont) -> CGFloat {
        (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded()
    }

    /// Monospaced font families, for the settings window's picker.
    ///
    /// Filtering by the mono-space trait rather than by a hardcoded list means a
    /// font the user installed for their editor shows up too — which is the
    /// whole point of a font picker in a terminal.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        var families: Set<String> = ["Menlo", "Monaco", "Courier"]

        for family in manager.availableFontFamilies {
            guard let members = manager.availableMembers(ofFontFamily: family) else { continue }
            let isMonospaced = members.contains { member in
                guard let name = member.first as? String, let font = NSFont(name: name, size: 12) else {
                    return false
                }
                return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            }
            if isMonospaced { families.insert(family) }
        }
        return families.sorted()
    }
}
