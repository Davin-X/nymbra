import AppKit
import CoreText
import Foundation
import NymbraCore
import NymbraInput

// The settings window's own controls: buttons, switches and cards drawn to
// the interface concept rather than taken from AppKit's stock set.

/// The panel accent from the interface concept (`--accent: #a99aff`). Used
/// directly rather than `controlAccentColor`, because the system accent follows
/// the user's macOS setting and would not match the design.
let nymbraAccent = NSColor(red: 0.663, green: 0.604, blue: 1.0, alpha: 1.0)

// MARK: - Custom Button Classes

/// A button with hover tracking for the settings window close button
final class CloseButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(red: 0.341, green: 0.380, blue: 0.475, alpha: 1.0).cgColor  // #373a4c
        contentTintColor = .white
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
    }
}

/// Footer buttons with custom styling and hover effects
final class FooterButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private let isPrimary: Bool

    init(title: String, target: AnyObject?, action: Selector?, isPrimary: Bool = false) {
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = isPrimary ? 0 : 1
        layer?.borderColor = NSColor(red: 0.231, green: 0.255, blue: 0.322, alpha: 1.0).cgColor  // #3b4152
        layer?.backgroundColor = (isPrimary
            ? NSColor(red: 0.663, green: 0.604, blue: 1.0, alpha: 1.0)
            : NSColor(red: 0.141, green: 0.161, blue: 0.212, alpha: 1.0)).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 24, height: max(28, size.height + 12))
    }

    /// The title is drawn from an attributed string so its colour is the colour
    /// the panel asks for, rather than whatever the system's dark-mode button
    /// style happens to choose.
    func configureTitle(_ text: String, font: NSFont, color: NSColor) {
        self.titleFont = font
        self.titleColor = color
        self.font = font
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    private var titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private var titleColor = NSColor.labelColor

    private func applyTitleColor(_ color: NSColor) {
        titleColor = color
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: titleFont,
            .foregroundColor: color,
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if isPrimary {
            layer?.backgroundColor = NSColor(red: 0.737, green: 0.690, blue: 1.0, alpha: 1.0).cgColor  // #bcb0ff
        } else {
            layer?.backgroundColor = NSColor(red: 0.188, green: 0.212, blue: 0.282, alpha: 1.0).cgColor  // #303648
            applyTitleColor(.white)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if isPrimary {
            layer?.backgroundColor = NSColor(red: 0.663, green: 0.604, blue: 1.0, alpha: 1.0).cgColor  // #a99aff
            applyTitleColor(NSColor(red: 0.090, green: 0.078, blue: 0.141, alpha: 1.0))  // #171424
        } else {
            layer?.backgroundColor = NSColor(red: 0.141, green: 0.161, blue: 0.212, alpha: 1.0).cgColor  // #242936
            applyTitleColor(NSColor(red: 0.796, green: 0.816, blue: 0.863, alpha: 1.0))  // #cbd0dc
        }
    }
}

/// A navigation button with active state styling
final class NavButton: NSButton {
    private let iconLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private var isActiveButton = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(icon: String, title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = ""
        bezelStyle = .regularSquare
        isBordered = false
        alignment = .left
        setAccessibilityLabel(title)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false

        iconLabel.stringValue = icon
        iconLabel.font = .systemFont(ofSize: 18)
        iconLabel.alignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconLabel)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLabel.widthAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setActive(_ active: Bool) {
        isActiveButton = active
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    private func updateAppearance() {
        let iconColor: NSColor
        let textColor: NSColor
        let background: NSColor
        if isActiveButton {
            background = nymbraAccent.withAlphaComponent(0.16)
            iconColor = nymbraAccent
            textColor = NSColor(red: 0.902, green: 0.882, blue: 1.0, alpha: 1.0)  // #e6e1ff
        } else if isHovered {
            background = NSColor(red: 0.133, green: 0.149, blue: 0.196, alpha: 1.0)  // #222632
            iconColor = NSColor(red: 0.788, green: 0.812, blue: 0.871, alpha: 1.0)  // #c9cfde
            textColor = .white
        } else {
            background = .clear
            iconColor = NSColor(red: 0.659, green: 0.690, blue: 0.765, alpha: 1.0)  // #a8b0c3
            // The sidebar is the only way between pages, so its resting labels
            // carry the weight of a navigation control rather than a caption.
            textColor = NSColor(red: 0.804, green: 0.835, blue: 0.902, alpha: 1.0)  // #cdd5e6
        }
        layer?.backgroundColor = background.cgColor
        iconLabel.textColor = iconColor
        titleLabel.textColor = textColor
        titleLabel.font = .systemFont(ofSize: 13.5, weight: isActiveButton ? .semibold : .medium)
    }
}

/// A pill toggle with a sliding knob, drawn the way the interface concept shows
/// it, rather than the system checkbox that `NSButton`'s switch style produces.
final class ToggleSwitch: NSButton {
    private let knob = CALayer()

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        setButtonType(.toggle)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 9
        knob.cornerRadius = 6
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)
        updateAppearance()
    }

    override var state: NSControl.StateValue {
        didSet { updateAppearance() }
    }

    override func layout() {
        super.layout()
        updateAppearance()
    }

    private func updateAppearance() {
        let on = state == .on
        layer?.backgroundColor = (on ? nymbraAccent
                                     : NSColor(red: 0.255, green: 0.278, blue: 0.345, alpha: 1.0)).cgColor
        let knobSize: CGFloat = 12
        let x = on ? max(3, bounds.width - knobSize - 3) : 3
        knob.frame = CGRect(x: x, y: (bounds.height - knobSize) / 2, width: knobSize, height: knobSize)
        knob.cornerRadius = knobSize / 2
    }
}

/// A pane's stack, flipped so its content starts at the top of the pane. A
/// non-flipped document view inside an `NSScrollView` is laid out from the
/// bottom, which would otherwise leave the empty space at the top.
final class PaneStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// A small button with custom padding (for "Default", "Validate", etc.)
final class SmallButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .regularSquare
        isBordered = true
        font = .systemFont(ofSize: 14)
        contentTintColor = NSColor(red: 0.796, green: 0.816, blue: 0.863, alpha: 1.0)  // #cbd0dc
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(red: 0.231, green: 0.255, blue: 0.322, alpha: 1.0).cgColor  // #3b4152
        layer?.backgroundColor = NSColor(red: 0.141, green: 0.161, blue: 0.212, alpha: 1.0).cgColor  // #242936
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 16, height: size.height + 8)
    }
}

/// A card that knows when the pointer is over it. The gallery cards use this to
/// lift their border and background on hover, which is what makes a row of tiles
/// feel like a control rather than a screenshot.
class HoverCardButton: NSButton {
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            hoverChanged?()
        }
    }

    var hoverChanged: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The card's labels are children of the button. Without this, a click on the
    /// text lands in the label and never reaches the button's action — which
    /// makes a gallery of cards look alive only at its edges.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}

final class ShortcutCaptureButton: NSButton {}

final class ThemeCardView: HoverCardButton {
    enum SelectionState {
        case selected
        case modified
        case unselected
    }

    let preset: Configuration.Colours.Preset
    var selectionState: SelectionState = .unselected {
        didSet { needsDisplay = true }
    }

    init(preset: Configuration.Colours.Preset, target: AnyObject?, action: Selector?) {
        self.preset = preset
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel("\(preset.rawValue) theme")
        toolTip = "Use the \(preset.rawValue) theme"
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        hoverChanged = { [weak self] in self?.needsDisplay = true }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 96),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The tiles draw from the top down so the swatch strip sits above the name,
    /// as the concept shows, rather than depending on the button's flipped state.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette(preset: preset, overrides: [:])
        let cardRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let card = NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10)
        Self.nsColor(palette.background).setFill()
        card.fill()

        if selectionState == .selected {
            nymbraAccent.withAlphaComponent(0.10).setFill()
            card.fill()
        } else if isHovered {
            NSColor(white: 1.0, alpha: 0.045).setFill()
            card.fill()
        }

        let border: NSColor
        switch selectionState {
        case .selected:
            border = nymbraAccent
        case .modified:
            border = .systemOrange
        case .unselected:
            border = isHovered
                ? NSColor(red: 0.408, green: 0.376, blue: 0.514, alpha: 1.0)  // #686083
                : NSColor(white: 1.0, alpha: 0.12)
        }
        border.setStroke()
        card.lineWidth = selectionState == .unselected ? 1 : 2
        card.stroke()

        // The swatch strip: a framed patch of the palette rather than four loose
        // lozenges, so the tile reads as a theme at a glance.
        let strip = NSRect(x: cardRect.minX + 9,
                           y: cardRect.minY + 9,
                           width: cardRect.width - 18,
                           height: 42)
        let stripPath = NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6)
        Self.nsColor(Palette.blend(palette.background, with: palette.foreground, amount: 0.045)).setFill()
        stripPath.fill()
        NSColor(white: 1.0, alpha: 0.09).setStroke()
        stripPath.lineWidth = 1
        stripPath.stroke()

        for (index, name) in ["red", "green", "yellow", "blue"].enumerated() {
            guard let colour = palette.colour(named: name) else { continue }
            let swatch = NSBezierPath(roundedRect: NSRect(
                x: strip.minX + 7 + CGFloat(index) * 16,
                y: strip.maxY - 7 - 12,
                width: 12,
                height: 12
            ), xRadius: 3.5, yRadius: 3.5)
            Self.nsColor(colour).setFill()
            swatch.fill()
        }

        let title = (preset == .highContrast ? "High contrast" : preset.rawValue.capitalized) as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: Self.nsColor(palette.foreground),
        ]
        title.draw(in: NSRect(x: cardRect.minX + 10,
                              y: strip.maxY + 8,
                              width: cardRect.width - 20,
                              height: 15),
                   withAttributes: titleAttributes)

        let badge: String?
        let badgeColor: NSColor
        switch selectionState {
        case .selected:
            badge = "✓"
            badgeColor = nymbraAccent
        case .modified:
            badge = "Modified"
            badgeColor = .systemOrange
        case .unselected:
            badge = nil
            badgeColor = .clear
        }
        if let badge {
            let text = badge as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: badgeColor,
            ]
            let width = text.size(withAttributes: attributes).width
            text.draw(at: NSPoint(x: cardRect.maxX - 10 - width, y: strip.maxY + 10),
                      withAttributes: attributes)
        }
    }

    private static func nsColor(_ rgb: Palette.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1)
    }
}

// MARK: - Small helpers

extension Array {
    /// A subscript that answers with nothing rather than trapping. Used for
    /// mapping a popup's index back to a value, where a stale index is a state
    /// the user can reach and a crash is not an acceptable answer.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
