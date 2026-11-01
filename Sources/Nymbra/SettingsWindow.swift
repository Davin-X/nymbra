import AppKit
import CoreText
import Foundation
import NymbraCore
import NymbraInput

/// The panel accent from the interface concept (`--accent: #a99aff`). Used
/// directly rather than `controlAccentColor`, because the system accent follows
/// the user's macOS setting and would not match the design.
private let nymbraAccent = NSColor(red: 0.663, green: 0.604, blue: 1.0, alpha: 1.0)

// MARK: - Custom Button Classes

/// A button with hover tracking for the settings window close button
private final class CloseButton: NSButton {
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
private final class FooterButton: NSButton {
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
private final class NavButton: NSButton {
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
private final class ToggleSwitch: NSButton {
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
private final class PaneStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// A small button with custom padding (for "Default", "Validate", etc.)
private final class SmallButton: NSButton {
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
private class HoverCardButton: NSButton {
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
///
/// Every control writes one field of `Configuration` and hands the whole thing
/// back, which the application applies to the open terminals and then saves.
/// There is no state here that is not in the configuration — which is what stops
/// the window and the file from disagreeing, and what makes the preview real
/// rather than a mock-up.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSSearchFieldDelegate,
    NSWindowDelegate {

    private var configuration: Configuration
    private let onChange: (Configuration) -> Void

    private let pageOrder = ["Appearance", "Keyboard", "Shell", "Behavior", "Advanced"]
    private var pageViews: [String: NSView] = [:]
    private var pageButtons: [String: NSButton] = [:]
    private var keyboardRows: [Command: NSView] = [:]
    private let pageHost = NSView()
    private let pageHeading = NSTextField(labelWithString: "Appearance")
    private let pageSubtitle = NSTextField(labelWithString: "Make your terminal comfortable to read.")
    private let preview = PreviewView()
    private let fontPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let cursorSegments = NSSegmentedControl(labels: ["Block", "Bar", "Underline"],
                                                    trackingMode: .selectOne,
                                                    target: nil,
                                                    action: nil)
    private let shortcutFilter = NSSearchField()
    private let shortcutFilterEmpty = NSTextField(labelWithString: "No matching commands.")
    private let blinkToggle = ToggleSwitch()
    private let scrollbackField = NSTextField()
    private let confirmToggle = ToggleSwitch()
    private let shellPopup = NSPopUpButton()
    private let shellPathField = NSTextField()
    private let shellNote = NSTextField(labelWithString: "")
    private let contrastLabel = NSTextField(labelWithString: "")
    // The gallery lives beside the colour controls rather than replacing them:
    // pick a preset with one click, then adjust individual colours freely.
    // A preset that arrives while overrides exist is "Modified" rather than
    // selected — the overrides are what the terminal actually shows.
    private var gallery: [ThemeCardView] = []
    private let galleryModifiedNote = NSTextField(labelWithString: "Modified — Revert to preset")
    private let galleryRevertButton = NSButton(title: "Revert", target: nil, action: nil)
    private var colourWells: [String: NSColorWell] = [:]
    private var promptStyleCards: [String: NSButton] = [:]
    private let promptApplyToggle = NSButton(checkboxWithTitle: "Apply in new zsh tabs",
                                             target: nil,
                                             action: nil)
    /// Called when the person asks for the chosen prompt in the tabs that are
    /// already open. Settings cannot reach the terminals itself, so the
    /// application installs this.
    var onApplyPrompt: ((Configuration) -> Void)?
    private var shortcutFields: [Command: ShortcutCaptureButton] = [:]
    private let shortcutWarning = NSTextField(labelWithString: "")
    private var shortcutMonitor: Any?

    init(configuration: Configuration, onChange: @escaping (Configuration) -> Void) {
        self.configuration = configuration
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nymbra Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.094, green: 0.106, blue: 0.141, alpha: 1.0)  // #181b24
        window.minSize = NSSize(width: 880, height: 620)
        super.init(window: window)
        window.delegate = self

        let content = makeContent()
        window.contentView = content
        // The content view must take its size from the window, not from the
        // intrinsic size of the controls inside it. Without a definite width, an
        // equality chain through the header (leading + intrinsic + trailing)
        // lets Auto Layout collapse the window's content to a narrow "strip".
        if let guide = window.contentLayoutGuide as? NSLayoutGuide {
            content.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
                content.topAnchor.constraint(equalTo: guide.topAnchor),
                content.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            ])
        }
        reload(from: configuration)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let panes: [(String, NSView)] = [
            ("Appearance", scrollable(appearancePane())),
            ("Keyboard", scrollable(keyboardPane())),
            ("Shell", scrollable(shellPane())),
            ("Behavior", scrollable(behaviourPane())),
            ("Advanced", scrollable(advancedPane())),
        ]
        pageViews = Dictionary(uniqueKeysWithValues: panes)

        // Sidebar: brand + navigation + bottom (version + settings file link)
        let brandMark = NSView()
        brandMark.wantsLayer = true
        brandMark.layer?.cornerRadius = 9
        brandMark.layer?.backgroundColor = NSColor(red: 0.106, green: 0.137, blue: 0.220, alpha: 1.0).cgColor  // #1b2338
        brandMark.layer?.borderWidth = 1
        brandMark.layer?.borderColor = NSColor(red: 0.169, green: 0.227, blue: 0.361, alpha: 1.0).cgColor  // #2b3a5c
        brandMark.layer?.shadowColor = NSColor.black.withAlphaComponent(0.025).cgColor
        brandMark.layer?.shadowOffset = CGSize(width: 0, height: 4)
        brandMark.layer?.shadowRadius = 14
        brandMark.layer?.shadowOpacity = 1
        brandMark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brandMark.widthAnchor.constraint(equalToConstant: 29),
            brandMark.heightAnchor.constraint(equalToConstant: 29),
        ])
        // Brand mark SVG: path m6 7 5 5-5 5 + rect at (14, 15.3) 4.5x2.3
        let brandMarkLayer = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6, y: 7))
        path.addLine(to: CGPoint(x: 11, y: 12))
        path.addLine(to: CGPoint(x: 6, y: 17))
        brandMarkLayer.path = path
        brandMarkLayer.strokeColor = NSColor(red: 0.431, green: 0.549, blue: 0.941, alpha: 1.0).cgColor  // #6e8cf0
        brandMarkLayer.lineWidth = 2.6
        brandMarkLayer.lineCap = .round
        brandMarkLayer.lineJoin = .round
        brandMarkLayer.fillColor = nil
        brandMarkLayer.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        brandMarkLayer.position = CGPoint(x: 14.5, y: 14.5)
        let rectLayer = CAShapeLayer()
        let rectPath = CGMutablePath()
        rectPath.addRoundedRect(in: CGRect(x: 14, y: 15.3, width: 4.5, height: 2.3), cornerWidth: 0.5, cornerHeight: 0.5)
        rectLayer.path = rectPath
        rectLayer.fillColor = NSColor(red: 0.851, green: 0.902, blue: 1.0, alpha: 1.0).cgColor  // #d9e6ff
        rectLayer.strokeColor = nil
        rectLayer.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        rectLayer.position = CGPoint(x: 14.5, y: 14.5)
        let svgContainer = CALayer()
        svgContainer.frame = CGRect(x: 0, y: 0, width: 29, height: 29)
        svgContainer.addSublayer(brandMarkLayer)
        svgContainer.addSublayer(rectLayer)
        brandMark.layer?.addSublayer(svgContainer)

        let brandName = NSTextField(labelWithString: "Nymbra")
        brandName.font = .systemFont(ofSize: 15, weight: .semibold)
        let brandCaption = NSTextField(labelWithString: "Settings")
        brandCaption.font = .systemFont(ofSize: 14)
        brandCaption.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3abbd
        let brandStack = NSStackView(views: [brandName, brandCaption])
        brandStack.orientation = .vertical
        brandStack.alignment = .leading
        brandStack.spacing = 1
        let brandRow = NSStackView(views: [brandMark, brandStack])
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 10

        let navLabel = sectionLabel("PREFERENCES")
        navLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let spacedTitle = NSAttributedString(string: "PREFERENCES", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor(red: 0.596, green: 0.627, blue: 0.706, alpha: 1.0),  // #98a0b4
            .kern: 1.1,
        ])
        navLabel.attributedStringValue = spacedTitle

        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 3
        let navIcons = ["Appearance": "◐", "Keyboard": "⌘", "Shell": "›_", "Behavior": "◷", "Advanced": "⚙"]
        for title in pageOrder {
            let button = NavButton(icon: navIcons[title] ?? "", title: title,
                                   target: self, action: #selector(pageSelected(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(title)
            button.widthAnchor.constraint(equalToConstant: 180).isActive = true
            pageButtons[title] = button
            navigation.addArrangedSubview(button)
        }

        // Sidebar bottom: version + settings file link
        let versionLabel = NSTextField(labelWithString: "Nymbra · pre-alpha")
        versionLabel.font = .systemFont(ofSize: 14)
        versionLabel.textColor = NSColor(red: 0.612, green: 0.643, blue: 0.714, alpha: 1.0)  // #9ca4b6
        let settingsFileButton = NSButton(title: "Show settings file ↗", target: self, action: #selector(revealSettingsFile(_:)))
        settingsFileButton.bezelStyle = .inline
        settingsFileButton.isBordered = false
        settingsFileButton.contentTintColor = NSColor(red: 0.761, green: 0.788, blue: 0.855, alpha: 1.0)  // #c2c9da
        settingsFileButton.font = .systemFont(ofSize: 14)
        settingsFileButton.alignment = .left
        let sidebarBottom = NSStackView(views: [versionLabel, settingsFileButton])
        sidebarBottom.orientation = .vertical
        sidebarBottom.alignment = .leading
        sidebarBottom.spacing = 4
        sidebarBottom.translatesAutoresizingMaskIntoConstraints = false
        // Add top border to sidebarBottom
        let sidebarBottomBorder = NSBox()
        sidebarBottomBorder.boxType = .separator
        sidebarBottomBorder.translatesAutoresizingMaskIntoConstraints = false
        sidebarBottom.addSubview(sidebarBottomBorder, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            sidebarBottomBorder.leadingAnchor.constraint(equalTo: sidebarBottom.leadingAnchor),
            sidebarBottomBorder.trailingAnchor.constraint(equalTo: sidebarBottom.trailingAnchor),
            sidebarBottomBorder.topAnchor.constraint(equalTo: sidebarBottom.topAnchor),
            sidebarBottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])

        let sidebarSpacer = NSView()
        sidebarSpacer.translatesAutoresizingMaskIntoConstraints = false
        sidebarSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        let sidebar = NSStackView(views: [brandRow, navLabel, navigation, sidebarSpacer, sidebarBottom])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.distribution = .fill
        sidebar.spacing = 0
        sidebar.setCustomSpacing(22, after: brandRow)
        sidebar.setCustomSpacing(6, after: navLabel)
        sidebar.setCustomSpacing(0, after: navigation)
        sidebar.setCustomSpacing(0, after: sidebarSpacer)
        sidebar.edgeInsets = NSEdgeInsets(top: 20, left: 12, bottom: 12, right: 12)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(red: 0.082, green: 0.094, blue: 0.125, alpha: 1.0).cgColor  // #151820
        sidebarBottom.widthAnchor.constraint(equalToConstant: 180).isActive = true
        // Right border on sidebar
        let sidebarRightBorder = NSBox()
        sidebarRightBorder.boxType = .separator
        sidebarRightBorder.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarRightBorder, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            sidebarRightBorder.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarRightBorder.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarRightBorder.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarRightBorder.widthAnchor.constraint(equalToConstant: 1),
        ])
        sidebarRightBorder.boxType = .separator

        pageHost.translatesAutoresizingMaskIntoConstraints = false
        for title in pageOrder {
            guard let view = pageViews[title] else { continue }
            pageHost.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: pageHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
            ])
            view.isHidden = true
        }

        pageHeading.font = .systemFont(ofSize: 20, weight: .semibold)
        pageHeading.attributedStringValue = NSAttributedString(
            string: "Appearance",
            attributes: [.kern: -0.38]
        )
        pageSubtitle.font = .systemFont(ofSize: 14)
        pageSubtitle.textColor = NSColor(red: 0.573, green: 0.600, blue: 0.667, alpha: 1.0)  // #9299aa
        let heading = NSStackView(views: [pageHeading, pageSubtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        heading.translatesAutoresizingMaskIntoConstraints = false

        // Settings head close button (×)
        let settingsCloseButton = CloseButton(title: "×", target: self, action: #selector(done(_:)))
        settingsCloseButton.bezelStyle = .inline
        settingsCloseButton.isBordered = false
        settingsCloseButton.font = .systemFont(ofSize: 17, weight: .medium)
        settingsCloseButton.contentTintColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
        settingsCloseButton.toolTip = "Close settings"
        settingsCloseButton.translatesAutoresizingMaskIntoConstraints = false
        settingsCloseButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        settingsCloseButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let headingWithClose = NSStackView(views: [heading, settingsCloseButton])
        headingWithClose.orientation = .horizontal
        headingWithClose.distribution = .fill
        headingWithClose.spacing = 8
        headingWithClose.translatesAutoresizingMaskIntoConstraints = false

        // Footer: save status + Reset + Done (primary)
        let saveStatus = NSTextField(labelWithString: "● Changes apply immediately")
        saveStatus.font = .systemFont(ofSize: 14)
        saveStatus.textColor = NSColor(red: 0.471, green: 0.859, blue: 0.631, alpha: 1.0)  // #78dba2 (--green)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        let resetFooterButton = FooterButton(title: "Reset…", target: self, action: #selector(resetAll(_:)), isPrimary: false)
        resetFooterButton.configureTitle("Reset…",
                                         font: .systemFont(ofSize: 14, weight: .medium),
                                         color: NSColor(red: 0.796, green: 0.816, blue: 0.863, alpha: 1.0))  // #cbd0dc
        resetFooterButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resetFooterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),
            resetFooterButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        let doneButton = FooterButton(title: "Done", target: self, action: #selector(done(_:)), isPrimary: true)
        doneButton.configureTitle("Done",
                                  font: .systemFont(ofSize: 14, weight: .semibold),
                                  color: NSColor(red: 0.090, green: 0.078, blue: 0.141, alpha: 1.0))  // #171424
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 66),
            doneButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        let footer = NSStackView(views: [saveStatus, footerSpacer, resetFooterButton, doneButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 9
        footer.translatesAutoresizingMaskIntoConstraints = false

        // A hairline above the footer, so the action row reads as a separate
        // surface from the scrolling page above it.
        let footerBorder = NSBox()
        footerBorder.boxType = .separator
        footerBorder.translatesAutoresizingMaskIntoConstraints = false

        let main = NSView()
        main.wantsLayer = true
        main.layer?.backgroundColor = NSColor(red: 0.094, green: 0.106, blue: 0.141, alpha: 1.0).cgColor  // #181b24
        main.addSubview(headingWithClose)
        main.addSubview(pageHost)
        main.addSubview(footerBorder)
        main.addSubview(footer)
        main.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(red: 0.094, green: 0.106, blue: 0.141, alpha: 1.0).cgColor  // #181b24
        root.addSubview(sidebar)
        root.addSubview(main)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 204),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            headingWithClose.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28),
            headingWithClose.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28),
            headingWithClose.topAnchor.constraint(equalTo: main.topAnchor, constant: 25),
            pageHost.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            pageHost.topAnchor.constraint(equalTo: headingWithClose.bottomAnchor, constant: 17),
            pageHost.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -11),
            footer.heightAnchor.constraint(equalToConstant: 32),
            footerBorder.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            footerBorder.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            footerBorder.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerBorder.heightAnchor.constraint(equalToConstant: 1),
        ])
        selectPage("Appearance")
        return root
    }

    @objc private func pageSelected(_ sender: NSButton) {
        guard let title = sender.identifier?.rawValue else { return }
        selectPage(title)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === shortcutFilter else { return }
        let query = shortcutFilter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var visibleCount = 0
        for (command, row) in keyboardRows {
            let isVisible = query.isEmpty
                || command.title.localizedCaseInsensitiveContains(query)
                || command.explanation.localizedCaseInsensitiveContains(query)
            row.isHidden = !isVisible
            if isVisible { visibleCount += 1 }
        }
        shortcutFilterEmpty.isHidden = visibleCount > 0
    }

    private func selectPage(_ title: String) {
        for (name, view) in pageViews {
            view.isHidden = name != title
        }
        for (name, button) in pageButtons {
            let isActive = name == title
            if let navButton = button as? NavButton {
                navButton.setActive(isActive)
            } else {
                button.contentTintColor = isActive ? nymbraAccent : .secondaryLabelColor
            }
        }
        pageHeading.stringValue = title
        pageSubtitle.stringValue = Self.pageDescription(title)
    }

    private static func pageDescription(_ title: String) -> String {
        switch title {
        case "Appearance": return "Make your terminal comfortable to read."
        case "Keyboard": return "Find commands and record shortcuts that work for you."
        case "Shell": return "Choose the shell used for new terminal sessions."
        case "Behavior": return "Tune your cursor, scrollback, and close warnings."
        case "Advanced": return "Fine-tune colours and manage your configuration."
        default: return ""
        }
    }

    private static func pageIcon(_ title: String) -> String {
        switch title {
        case "Appearance": return "textformat"
        case "Keyboard": return "keyboard"
        case "Shell": return "terminal"
        case "Behavior": return "slider.horizontal.3"
        case "Advanced": return "paintpalette"
        default: return "circle"
        }
    }

    /// A pane wrapped so a small window scrolls instead of clipping, and a
    /// large window gives the extra space to the content.
    private func scrollable(_ pane: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = pane
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // The pane stack is flipped, so it is laid out from the top down. It keeps
        // its own (intrinsic) height and simply scrolls when that is taller than
        // the clip view; it is deliberately *not* stretched to the clip view's
        // height, because stretching would spread the rows apart in a tall window.
        pane.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            pane.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            pane.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            pane.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func paneStack() -> NSStackView {
        let stack = PaneStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func row(_ text: String, _ control: NSView, hint: String? = nil) -> NSStackView {
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        let labelStack = NSStackView(views: [title])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 3
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let hint {
            let detail = NSTextField(labelWithString: hint)
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: 14)
            detail.lineBreakMode = .byWordWrapping
            detail.maximumNumberOfLines = 2
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labelStack.addArrangedSubview(detail)
        }

        let stack = NSStackView(views: [labelStack, control])
        stack.orientation = .horizontal
        stack.spacing = 16
        stack.alignment = .centerY
        stack.distribution = .fill
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @discardableResult
    private func addRow(_ title: String, control: NSView, hint: String? = nil,
                        to pane: NSStackView) -> NSStackView {
        let rowView = row(title, control, hint: hint)
        pane.addArrangedSubview(rowView)
        rowView.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true
        return rowView
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 14)
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 14)
        field.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3acc0
        return field
    }

    // A section heading with title and optional subtle description
    private func sectionHeading(_ title: String, description: String? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor(red: 0.875, green: 0.890, blue: 0.929, alpha: 1.0)  // #dfe3ed
        if let description {
            let descLabel = NSTextField(labelWithString: description)
            descLabel.font = .systemFont(ofSize: 12, weight: .regular)
            descLabel.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3acc0
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [titleLabel, spacer, descLabel])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.distribution = .fill
            stack.spacing = 8
            return stack
        }
        return titleLabel
    }

    // A card container with border and background (like .preview-card in concept)
    private func cardView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.094, alpha: 1.0).cgColor  // #0b0e18
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor(red: 0.208, green: 0.231, blue: 0.294, alpha: 1.0).cgColor  // #353b4b
        view.layer?.cornerRadius = 9
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// A grid whose columns share the available width equally. `NSGridView` sizes
    /// its columns to the widest cell, which left the tiles huddled at the left
    /// with a gap at the right once the window was resized; equal-width rows fill
    /// the pane and stay aligned at every width.
    private func equalWidthGrid(rows: [[NSView]], columns: Int, spacing: CGFloat = 10) -> NSStackView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .width
        grid.distribution = .fill
        grid.spacing = spacing
        grid.translatesAutoresizingMaskIntoConstraints = false

        for cells in rows {
            var padded = cells
            while padded.count < columns { padded.append(NSView()) }
            let row = NSStackView(views: padded)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = spacing
            row.translatesAutoresizingMaskIntoConstraints = false
            grid.addArrangedSubview(row)
            // A vertical stack does not stretch its rows on its own; the row is
            // anchored to the grid so every column shares the same width.
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        return grid
    }

    // An inline row with label + control, bottom border (like .inline-row in concept)
    private func inlineRow(title: String, help: String? = nil, control: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 3
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = NSColor(red: 0.847, green: 0.863, blue: 0.902, alpha: 1.0)  // #d8dce6
        labelStack.addArrangedSubview(titleLabel)

        if let help {
            let helpLabel = NSTextField(labelWithString: help)
            helpLabel.font = .systemFont(ofSize: 14)
            helpLabel.textColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
            helpLabel.lineBreakMode = .byWordWrapping
            helpLabel.maximumNumberOfLines = 2
            helpLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labelStack.addArrangedSubview(helpLabel)
        }

        // The label takes whatever the control does not: it must not be pinned to
        // a fixed width, or a longer help line is truncated mid-word.
        labelStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addSubview(labelStack)
        // The control is placed by the row's constraints, so its autoresizing mask
        // must not also dictate a position (which would leave a segmented control
        // sitting under its own label instead of at the trailing edge).
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labelStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            labelStack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 6),
            labelStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6),
            labelStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            control.leadingAnchor.constraint(greaterThanOrEqualTo: labelStack.trailingAnchor, constant: 12),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        // Bottom border
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(border, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            border.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])

        return container
    }

    // MARK: - Panes

    private func appearancePane() -> NSView {
        let pane = paneStack()

        // Live preview section with card
        pane.addArrangedSubview(sectionHeading("Live preview", description: "Uses the same palette and font as your terminal"))

        let previewCard = cardView()
        let previewStack = NSStackView()
        previewStack.orientation = .vertical
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(previewStack)
        NSLayoutConstraint.activate([
            previewStack.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor),
            previewStack.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor),
            previewStack.topAnchor.constraint(equalTo: previewCard.topAnchor),
            previewStack.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor),
        ])

        // Preview topline with traffic lights
        let topline = NSView()
        topline.translatesAutoresizingMaskIntoConstraints = false
        topline.heightAnchor.constraint(equalToConstant: 36).isActive = true
        topline.wantsLayer = true
        topline.layer?.borderWidth = 1
        topline.layer?.borderColor = NSColor(red: 0.153, green: 0.169, blue: 0.224, alpha: 1.0).cgColor  // #272b39
        for i in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = NSColor(red: 0.255, green: 0.275, blue: 0.329, alpha: 1.0).cgColor  // #414654
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            topline.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: topline.leadingAnchor, constant: 10 + CGFloat(i) * 10),
                dot.centerYAnchor.constraint(equalTo: topline.centerYAnchor),
            ])
        }
        let previewLabel = NSTextField(labelWithString: "~/src/nymbra — shell preview")
        previewLabel.font = .systemFont(ofSize: 14)
        previewLabel.textColor = NSColor(red: 0.537, green: 0.569, blue: 0.639, alpha: 1.0)  // #8991a3
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        topline.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: topline.leadingAnchor, constant: 46),
            previewLabel.centerYAnchor.constraint(equalTo: topline.centerYAnchor),
        ])
        previewStack.addArrangedSubview(topline)

        // Preview content - use the existing PreviewView but embedded
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewStack.addArrangedSubview(preview)

        pane.addArrangedSubview(previewCard)
        previewCard.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Font section
        pane.addArrangedSubview(sectionHeading("Font"))
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        fontPopup.translatesAutoresizingMaskIntoConstraints = false
        fontPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let fontRow = inlineRow(title: "Font family", help: "Monospaced fonts available on this Mac", control: fontPopup)
        pane.addArrangedSubview(fontRow)
        fontRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeTyped(_:))
        fontSizeField.alignment = .right
        fontSizeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        fontSizeField.textColor = NSColor(red: 0.875, green: 0.890, blue: 0.929, alpha: 1.0)  // #dfe3ec
        fontSizeField.isBordered = false
        fontSizeField.drawsBackground = false
        fontSizeField.focusRingType = .none
        fontSizeField.wantsLayer = true
        fontSizeField.layer?.cornerRadius = 6
        fontSizeField.layer?.borderWidth = 1
        fontSizeField.layer?.borderColor = NSColor(red: 0.216, green: 0.239, blue: 0.302, alpha: 1.0).cgColor  // #373d4d
        fontSizeField.layer?.backgroundColor = NSColor(red: 0.125, green: 0.141, blue: 0.188, alpha: 1.0).cgColor  // #202430
        fontSizeField.translatesAutoresizingMaskIntoConstraints = false
        fontSizeField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        fontSizeField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped(_:))
        fontSizeStepper.controlSize = .small
        fontSizeStepper.minValue = Configuration.Appearance.fontSizeRange.lowerBound
        fontSizeStepper.maxValue = Configuration.Appearance.fontSizeRange.upperBound
        fontSizeStepper.increment = 1
        let sizeControls = NSStackView(views: [fontSizeField, fontSizeStepper])
        sizeControls.orientation = .horizontal
        sizeControls.spacing = 6
        let sizeRow = inlineRow(title: "Font size", help: "Adjust terminal text from 6 to 72 pt", control: sizeControls)
        pane.addArrangedSubview(sizeRow)
        sizeRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Prompt style section
        pane.addArrangedSubview(sectionHeading("Prompt style",
                                                description: "Applied by Nymbra to new zsh tabs"))
        let promptGrid = promptStyleGrid()
        pane.addArrangedSubview(promptGrid)
        promptGrid.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Theme section
        pane.addArrangedSubview(sectionHeading("Theme", description: "Choose a palette; customize colours below"))
        let themeGrid = themeGalleryGrid()
        pane.addArrangedSubview(themeGrid)
        themeGrid.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Customize colours link
        let customizeRow = NSView()
        customizeRow.translatesAutoresizingMaskIntoConstraints = false
        customizeRow.wantsLayer = true
        customizeRow.layer?.borderWidth = 1
        customizeRow.layer?.borderColor = NSColor(red: 0.188, green: 0.212, blue: 0.275, alpha: 1.0).cgColor  // #303646
        customizeRow.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor  // #1d212c
        customizeRow.layer?.cornerRadius = 7
        let customizeStack = NSStackView()
        customizeStack.orientation = .horizontal
        customizeStack.distribution = .fill
        customizeStack.alignment = .centerY
        customizeStack.spacing = 12
        customizeStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        customizeStack.translatesAutoresizingMaskIntoConstraints = false
        customizeRow.addSubview(customizeStack)
        NSLayoutConstraint.activate([
            customizeStack.leadingAnchor.constraint(equalTo: customizeRow.leadingAnchor),
            customizeStack.trailingAnchor.constraint(equalTo: customizeRow.trailingAnchor),
            customizeStack.topAnchor.constraint(equalTo: customizeRow.topAnchor),
            customizeStack.bottomAnchor.constraint(equalTo: customizeRow.bottomAnchor),
        ])
        let customizeLabelStack = NSStackView()
        customizeLabelStack.orientation = .vertical
        customizeLabelStack.alignment = .leading
        customizeLabelStack.spacing = 2
        let customizeTitle = NSTextField(labelWithString: "Need more control?")
        customizeTitle.font = .systemFont(ofSize: 14, weight: .medium)
        customizeTitle.textColor = NSColor(red: 0.886, green: 0.898, blue: 0.929, alpha: 1.0)  // #e2e5ed
        let customizeHelp = NSTextField(labelWithString: "Adjust ANSI and interface colours individually.")
        customizeHelp.font = .systemFont(ofSize: 14)
        customizeHelp.textColor = NSColor(red: 0.553, green: 0.580, blue: 0.647, alpha: 1.0)  // #8d94a5
        customizeLabelStack.addArrangedSubview(customizeTitle)
        customizeLabelStack.addArrangedSubview(customizeHelp)
        let customizeButton = SmallButton(title: "Customize colours", target: self, action: #selector(selectAdvancedPage(_:)))
        customizeStack.addArrangedSubview(customizeLabelStack)
        customizeStack.addArrangedSubview(NSView()) // spacer
        customizeStack.addArrangedSubview(customizeButton)
        pane.addArrangedSubview(customizeRow)
        customizeRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        return pane
    }

    private func advancedPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionHeading("Colour overrides", description: "Optional fine-tuning for the selected theme"))

        galleryModifiedNote.textColor = NSColor(red: 0.522, green: 0.553, blue: 0.620, alpha: 1.0)  // #858c9e
        galleryModifiedNote.font = .systemFont(ofSize: 14)
        galleryModifiedNote.isHidden = true
        galleryRevertButton.target = self
        galleryRevertButton.action = #selector(revertColours(_:))
        galleryRevertButton.bezelStyle = .inline
        galleryRevertButton.isHidden = true
        let modifiedRow = NSStackView(views: [galleryModifiedNote, galleryRevertButton])
        modifiedRow.orientation = .horizontal
        modifiedRow.spacing = 8
        pane.addArrangedSubview(modifiedRow)

        pane.addArrangedSubview(sectionHeading("Palette"))

        // Create a bordered container for the palette grid
        let paletteContainer = NSView()
        paletteContainer.wantsLayer = true
        paletteContainer.layer?.borderWidth = 1
        paletteContainer.layer?.borderColor = NSColor(red: 0.188, green: 0.212, blue: 0.275, alpha: 1.0).cgColor  // #303646
        paletteContainer.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor  // #1d212c
        paletteContainer.layer?.cornerRadius = 8
        paletteContainer.translatesAutoresizingMaskIntoConstraints = false

        let paletteGrid = NSGridView(numberOfColumns: 4, rows: 0)
        paletteGrid.rowSpacing = 10
        paletteGrid.columnSpacing = 16
        paletteGrid.translatesAutoresizingMaskIntoConstraints = false
        paletteContainer.addSubview(paletteGrid)
        NSLayoutConstraint.activate([
            paletteGrid.leadingAnchor.constraint(equalTo: paletteContainer.leadingAnchor, constant: 16),
            paletteGrid.trailingAnchor.constraint(equalTo: paletteContainer.trailingAnchor, constant: -16),
            paletteGrid.topAnchor.constraint(equalTo: paletteContainer.topAnchor, constant: 16),
            paletteGrid.bottomAnchor.constraint(equalTo: paletteContainer.bottomAnchor, constant: -16),
        ])

        let names = Palette.interfaceNames + Palette.ansiNames
        for start in stride(from: 0, to: names.count, by: 4) {
            var cells: [NSView] = []
            for name in names[start..<min(start + 4, names.count)] {
                let well = NSColorWell()
                well.identifier = NSUserInterfaceItemIdentifier(name)
                well.target = self
                well.action = #selector(colourChanged(_:))
                well.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    well.widthAnchor.constraint(equalToConstant: 64),
                    well.heightAnchor.constraint(equalToConstant: 26)
                ])
                colourWells[name] = well

                let cell = NSStackView(views: [well, caption(name)])
                cell.orientation = .vertical
                cell.alignment = .leading
                cell.spacing = 3
                cells.append(cell)
            }
            paletteGrid.addRow(with: cells)
        }

        pane.addArrangedSubview(paletteContainer)
        paletteContainer.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        contrastLabel.font = .systemFont(ofSize: 14)
        contrastLabel.textColor = .secondaryLabelColor
        pane.addArrangedSubview(contrastLabel)

        pane.addArrangedSubview(sectionHeading("Configuration"))

        let revealConfigButton = SmallButton(title: "Show file ↗", target: self, action: #selector(revealSettingsFile(_:)))

        let revealRow = inlineRow(title: "Settings file", help: "Hand-editable JSON, stored locally on this Mac.", control: revealConfigButton)
        pane.addArrangedSubview(revealRow)
        revealRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        let resetButton = SmallButton(title: "Reset all…", target: self, action: #selector(resetAll(_:)))

        let resetRow = inlineRow(title: "Restore defaults", help: "Reset appearance, behavior, shortcuts, and shell.", control: resetButton)
        pane.addArrangedSubview(resetRow)
        resetRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        return pane
    }

    /// A visual preset picker whose swatches use Nymbra's actual palette data.
    private func themeGalleryGrid() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 10

        gallery.removeAll()
        var rows: [[NSView]] = []
        var cells: [NSView] = []
        for preset in Configuration.Colours.Preset.allCases {
            let card = ThemeCardView(preset: preset, target: self, action: #selector(themeCardClicked(_:)))
            gallery.append(card)
            cells.append(card)
            if cells.count == 4 {
                rows.append(cells)
                cells.removeAll()
            }
        }
        if !cells.isEmpty { rows.append(cells) }
        let grid = equalWidthGrid(rows: rows, columns: 4, spacing: 8)
        container.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    private func promptStyleGrid() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        promptApplyToggle.target = self
        promptApplyToggle.action = #selector(promptStyleApplyToggled(_:))
        promptApplyToggle.state = configuration.appearance.promptStyleApplied ? .on : .off
        promptApplyToggle.font = .systemFont(ofSize: 14, weight: .medium)
        promptApplyToggle.contentTintColor = NSColor(red: 0.749, green: 0.780, blue: 0.847, alpha: 1.0)  // #bfc7d8
        promptApplyToggle.toolTip = "Nymbra starts new zsh tabs with the selected prompt. "
            + "Shells that are already running keep the prompt they started with."
        container.addArrangedSubview(promptApplyToggle)

        var rows: [[NSView]] = []
        var cells: [NSView] = []
        promptStyleCards.removeAll()
        for style in PromptStyle.allCases {
            let id = style.rawValue
            let card = HoverCardButton()
            card.title = ""
            card.bezelStyle = .regularSquare
            card.isBordered = false
            card.wantsLayer = true
            card.layer?.cornerRadius = 10
            card.layer?.borderWidth = 1
            card.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor
            card.setButtonType(.momentaryChange)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.heightAnchor.constraint(equalToConstant: 100).isActive = true

            let cardStack = NSStackView()
            cardStack.orientation = .vertical
            cardStack.alignment = .leading
            cardStack.spacing = 4
            cardStack.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
            cardStack.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = NSTextField(labelWithString: style.title)
            nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
            nameLabel.textColor = NSColor(red: 0.886, green: 0.898, blue: 0.929, alpha: 1.0)  // #e2e5ed
            let descLabel = NSTextField(labelWithString: style.summary)
            descLabel.font = .systemFont(ofSize: 14)
            descLabel.textColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
            descLabel.maximumNumberOfLines = 2
            descLabel.lineBreakMode = .byWordWrapping
            let sampleLabel = NSTextField(labelWithString: "")
            sampleLabel.attributedStringValue = promptSample(style)
            sampleLabel.lineBreakMode = .byTruncatingTail
            sampleLabel.maximumNumberOfLines = 2
            sampleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            cardStack.addArrangedSubview(nameLabel)
            cardStack.addArrangedSubview(descLabel)
            cardStack.addArrangedSubview(sampleLabel)
            card.addSubview(cardStack)
            NSLayoutConstraint.activate([
                cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                cardStack.topAnchor.constraint(equalTo: card.topAnchor),
                cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            ])

            card.identifier = NSUserInterfaceItemIdentifier(id)
            card.target = self
            card.action = #selector(promptStyleSelected(_:))
            card.hoverChanged = { [weak self, weak card] in
                guard let self, let card else { return }
                self.stylePromptCard(card,
                                     selected: card.identifier?.rawValue == self.configuration.appearance.promptStyle)
            }
            promptStyleCards[id] = card
            stylePromptCard(card, selected: configuration.appearance.promptStyle == id)

            cells.append(card)
            if cells.count == 3 {
                rows.append(cells)
                cells.removeAll()
            }
        }
        if !cells.isEmpty { rows.append(cells) }

        let grid = equalWidthGrid(rows: rows, columns: 3, spacing: 10)
        container.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let applyNowButton = SmallButton(title: "Apply to current tab", target: self,
                                         action: #selector(applyPromptToCurrentTab(_:)))
        applyNowButton.font = .systemFont(ofSize: 11, weight: .medium)
        applyNowButton.contentTintColor = NSColor(red: 0.796, green: 0.816, blue: 0.863, alpha: 1.0)  // #cbd0dc
        let applyNowRow = NSStackView(views: [applyNowButton])
        applyNowRow.orientation = .horizontal
        applyNowRow.alignment = .leading
        container.addArrangedSubview(applyNowRow)

        let note = NSTextField(wrappingLabelWithString:
            "New zsh tabs wear the selected prompt. \"Apply to current tab\" sends it "
            + "to a shell that is sitting at its own prompt. Branch names come from git.")
        note.font = .systemFont(ofSize: 14)
        note.textColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        container.addArrangedSubview(note)

        return container
    }

    /// The text a gallery card shows for a style, drawn from the same model the
    /// preview draws from: a card that disagreed with the preview would be a
    /// preview of nothing. The runs keep their palette ink (and their filled
    /// block, where a Powerline-shaped prompt has one), so the card shows the
    /// style rather than a greyed-out description of it.
    private func promptSample(_ style: PromptStyle) -> NSAttributedString {
        let regular = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let sample = NSMutableAttributedString()
        for (lineIndex, runs) in PreviewView.promptLines(style, palette: previewPalette).enumerated() {
            if lineIndex > 0 {
                sample.append(NSAttributedString(string: "\n", attributes: [.font: regular]))
            }
            for run in runs {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: run.bold ? bold : regular,
                    .foregroundColor: Self.nsColor(run.ink),
                ]
                if let paper = run.paper {
                    attributes[.backgroundColor] = Self.nsColor(paper)
                }
                sample.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return sample
    }

    /// The palette the preview and the gallery cards draw with.
    private var previewPalette: Palette {
        Palette(preset: configuration.colours.preset, overrides: configuration.colours.overrides)
    }

    /// Paint a prompt-style card as chosen or not. The selected card carries the
    /// accent border the concept shows, so the current choice is never a guess.
    private func stylePromptCard(_ card: NSButton, selected: Bool) {
        let hovered = (card as? HoverCardButton)?.isHovered ?? false
        let border: NSColor
        if selected {
            border = nymbraAccent
        } else if hovered {
            border = NSColor(red: 0.408, green: 0.376, blue: 0.514, alpha: 1.0)  // #686083
        } else {
            border = NSColor(red: 0.204, green: 0.224, blue: 0.286, alpha: 1.0)  // #343949
        }
        let background: NSColor
        if selected {
            background = NSColor(red: 0.153, green: 0.141, blue: 0.227, alpha: 1.0)  // #27243a
        } else if hovered {
            background = NSColor(red: 0.141, green: 0.157, blue: 0.216, alpha: 1.0)  // #242837
        } else {
            background = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0)  // #1d212c
        }
        card.layer?.borderColor = border.cgColor
        card.layer?.backgroundColor = background.cgColor
    }

    private func behaviourPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionHeading("Terminal behavior", description: "Preferences apply to new and open terminals"))

        cursorSegments.target = self
        cursorSegments.action = #selector(cursorShapeChanged(_:))
        cursorSegments.segmentStyle = .rounded
        for index in 0..<cursorSegments.segmentCount {
            cursorSegments.setWidth(74, forSegment: index)
        }
        let cursorRow = inlineRow(title: "Cursor shape", help: "Programs can temporarily change the cursor.", control: cursorSegments)
        pane.addArrangedSubview(cursorRow)
        cursorRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        blinkToggle.target = self
        blinkToggle.action = #selector(blinkChanged(_:))
        blinkToggle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            blinkToggle.widthAnchor.constraint(equalToConstant: 31),
            blinkToggle.heightAnchor.constraint(equalToConstant: 18),
        ])
        let blinkRow = inlineRow(title: "Blinking cursor", help: "Only blinks in the focused pane.", control: blinkToggle)
        pane.addArrangedSubview(blinkRow)
        blinkRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        scrollbackField.target = self
        scrollbackField.action = #selector(scrollbackTyped(_:))
        scrollbackField.alignment = .right
        scrollbackField.translatesAutoresizingMaskIntoConstraints = false
        scrollbackField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let scrollbackRow = inlineRow(title: "Scrollback", help: "Maximum history retained above the screen.", control: scrollbackField)
        pane.addArrangedSubview(scrollbackRow)
        scrollbackRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        confirmToggle.target = self
        confirmToggle.action = #selector(confirmChanged(_:))
        confirmToggle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            confirmToggle.widthAnchor.constraint(equalToConstant: 31),
            confirmToggle.heightAnchor.constraint(equalToConstant: 18),
        ])
        let confirmRow = inlineRow(title: "Confirm before closing", help: "Warn when a command is still running.", control: confirmToggle)
        pane.addArrangedSubview(confirmRow)
        confirmRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        return pane
    }

    private func keyboardPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionHeading("Application shortcuts", description: "Click a shortcut and press a new combination. Other keys continue to your shell."))

        shortcutFilter.placeholderString = "⌕  Filter commands"
        shortcutFilter.sendsSearchStringImmediately = true
        shortcutFilter.delegate = self
        shortcutFilter.translatesAutoresizingMaskIntoConstraints = false
        shortcutFilter.wantsLayer = true
        shortcutFilter.layer?.cornerRadius = 6
        shortcutFilter.layer?.borderWidth = 1
        shortcutFilter.layer?.borderColor = NSColor(red: 0.204, green: 0.224, blue: 0.286, alpha: 1.0).cgColor  // #343949
        shortcutFilter.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor  // #1d212c
        shortcutFilter.cell?.backgroundStyle = .emphasized
        pane.addArrangedSubview(shortcutFilter)
        shortcutFilter.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        shortcutFilterEmpty.font = .systemFont(ofSize: 14)
        shortcutFilterEmpty.textColor = NSColor(red: 0.682, green: 0.706, blue: 0.761, alpha: 1.0)  // #aeb4c2
        shortcutFilterEmpty.isHidden = true
        pane.addArrangedSubview(shortcutFilterEmpty)

        keyboardRows.removeAll()

        // Create a bordered list container (like .shortcut-list in concept)
        let listContainer = NSView()
        listContainer.wantsLayer = true
        listContainer.layer?.borderWidth = 1
        listContainer.layer?.borderColor = NSColor(red: 0.188, green: 0.212, blue: 0.275, alpha: 1.0).cgColor  // #303646
        listContainer.layer?.cornerRadius = 8
        listContainer.translatesAutoresizingMaskIntoConstraints = false

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
        ])

        var first = true
        for (command, shortcut) in Command.bindings() {
            let field = ShortcutCaptureButton(title: shortcut?.display ?? "Record", target: self,
                                               action: #selector(shortcutRecordRequested(_:)))
            field.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            field.setAccessibilityLabel("\(command.title) shortcut")
            field.setAccessibilityHelp("Click, then press a modifier and key combination to record a shortcut.")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true
            shortcutFields[command] = field

            let restore = SmallButton(title: "Default", target: self, action: #selector(shortcutRestoreDefault(_:)))
            restore.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            restore.layer?.cornerRadius = 5

            let controls = NSStackView(views: [field, restore])
            controls.orientation = .horizontal
            controls.spacing = 6

            let rowView = NSView()
            rowView.translatesAutoresizingMaskIntoConstraints = false

            let infoStack = NSStackView()
            infoStack.orientation = .vertical
            infoStack.alignment = .leading
            infoStack.spacing = 2
            infoStack.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = NSTextField(labelWithString: command.title)
            nameLabel.font = .systemFont(ofSize: 14)
            nameLabel.textColor = NSColor(red: 0.886, green: 0.898, blue: 0.929, alpha: 1.0)  // #e2e5ed
            let descLabel = NSTextField(labelWithString: command.explanation)
            descLabel.font = .systemFont(ofSize: 14)
            descLabel.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3acc0
            infoStack.addArrangedSubview(nameLabel)
            infoStack.addArrangedSubview(descLabel)

            rowView.addSubview(infoStack)
            rowView.addSubview(controls)

            NSLayoutConstraint.activate([
                infoStack.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10),
                infoStack.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
                infoStack.widthAnchor.constraint(equalTo: rowView.widthAnchor, multiplier: 0.7),

                controls.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -10),
                controls.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),

                rowView.heightAnchor.constraint(equalToConstant: 43),
            ])

            // Add border separator
            if !first {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                listContainer.addSubview(separator, positioned: .below, relativeTo: listStack.arrangedSubviews.last!)
                NSLayoutConstraint.activate([
                    separator.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
                    separator.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
                    separator.topAnchor.constraint(equalTo: listStack.arrangedSubviews.last!.bottomAnchor),
                    separator.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
            first = false

            listStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            keyboardRows[command] = rowView
        }

        pane.addArrangedSubview(listContainer)
        listContainer.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        shortcutWarning.font = .systemFont(ofSize: 14)
        pane.addArrangedSubview(shortcutWarning)
        return pane
    }

    private func shellPane() -> NSView {
        let pane = paneStack()

        pane.addArrangedSubview(sectionHeading("Default shell", description: "Applied to new tabs and windows"))

        shellPopup.target = self
        shellPopup.action = #selector(shellChanged(_:))
        shellPopup.translatesAutoresizingMaskIntoConstraints = false
        shellPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let shellRow = inlineRow(title: "Detected shells", help: "Choose a shell installed on this Mac", control: shellPopup)
        pane.addArrangedSubview(shellRow)
        shellRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        pane.addArrangedSubview(sectionHeading("Custom executable", description: "For shells not listed above, enter an absolute path to the executable."))

        shellPathField.placeholderString = "/opt/homebrew/bin/fish"
        shellPathField.translatesAutoresizingMaskIntoConstraints = false
        shellPathField.widthAnchor.constraint(equalToConstant: 210).isActive = true
        shellPathField.wantsLayer = true
        shellPathField.layer?.cornerRadius = 6
        shellPathField.layer?.borderWidth = 1
        shellPathField.layer?.borderColor = NSColor(red: 0.216, green: 0.239, blue: 0.302, alpha: 1.0).cgColor  // #373d4d
        shellPathField.layer?.backgroundColor = NSColor(red: 0.125, green: 0.141, blue: 0.188, alpha: 1.0).cgColor  // #202430
        shellPathField.font = .systemFont(ofSize: 14)
        shellPathField.textColor = NSColor(red: 0.875, green: 0.890, blue: 0.929, alpha: 1.0)  // #dfe3ec

        let validateButton = SmallButton(title: "Validate", target: self, action: #selector(useCustomShell(_:)))

        let pathStack = NSStackView(views: [shellPathField, validateButton])
        pathStack.orientation = .horizontal
        pathStack.spacing = 7
        pathStack.translatesAutoresizingMaskIntoConstraints = false

        let pathRow = inlineRow(title: "Executable path", help: "Absolute path to an executable file", control: pathStack)
        pane.addArrangedSubview(pathRow)
        pathRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -40).isActive = true

        // Status row
        let statusRow = NSView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.wantsLayer = true
        statusRow.layer?.borderWidth = 1
        statusRow.layer?.borderColor = NSColor(red: 0.188, green: 0.212, blue: 0.275, alpha: 1.0).cgColor  // #303646
        statusRow.layer?.backgroundColor = NSColor(red: 0.114, green: 0.129, blue: 0.173, alpha: 1.0).cgColor  // #1d212c
        statusRow.layer?.cornerRadius = 7

        let statusStack = NSStackView()
        statusStack.orientation = .horizontal
        statusStack.distribution = .fill
        statusStack.alignment = .centerY
        statusStack.spacing = 12
        statusStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addSubview(statusStack)
        NSLayoutConstraint.activate([
            statusStack.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor),
            statusStack.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor),
            statusStack.topAnchor.constraint(equalTo: statusRow.topAnchor),
            statusStack.bottomAnchor.constraint(equalTo: statusRow.bottomAnchor),
        ])

        let statusLabelStack = NSStackView()
        statusLabelStack.orientation = .vertical
        statusLabelStack.alignment = .leading
        statusLabelStack.spacing = 2
        let statusTitle = NSTextField(labelWithString: "Existing sessions won't be interrupted")
        statusTitle.font = .systemFont(ofSize: 13, weight: .medium)
        statusTitle.textColor = NSColor(red: 0.886, green: 0.898, blue: 0.929, alpha: 1.0)  // #e2e5ed
        let statusHelp = NSTextField(labelWithString: "The new shell is used next time you open a tab or window.")
        statusHelp.font = .systemFont(ofSize: 12)
        statusHelp.textColor = NSColor(red: 0.639, green: 0.671, blue: 0.741, alpha: 1.0)  // #a3acc0
        statusLabelStack.addArrangedSubview(statusTitle)
        statusLabelStack.addArrangedSubview(statusHelp)

        let statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.backgroundColor = NSColor(red: 0.471, green: 0.859, blue: 0.631, alpha: 1.0).cgColor  // #78dba2
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        statusStack.addArrangedSubview(statusLabelStack)
        statusStack.addArrangedSubview(NSView()) // spacer
        statusStack.addArrangedSubview(statusDot)

        pane.addArrangedSubview(statusRow)
        // The status bar carries two lines of text; give it the full content
        // width rather than the narrower column the small rows use, so neither
        // line has to wrap into a cramped block.
        statusRow.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -20).isActive = true

        return pane
    }

    private func resetButton() -> NSButton {
        NSButton(title: "Reset All Settings\u{2026}", target: self, action: #selector(resetAll(_:)))
    }

    private func revealButton() -> NSButton {
        NSButton(title: "Show file ↗", target: self, action: #selector(revealSettingsFile(_:)))
    }

    private func doneButton() -> NSButton {
        NSButton(title: "Done", target: self, action: #selector(done(_:)))
    }

    @objc private func done(_ sender: NSButton) {
        window?.close()
    }

    // MARK: - Reading the configuration back in

    /// Set every control from `configuration`. Called on open, on Reset, and
    /// after a font-size shortcut changes the configuration elsewhere.
    func reload(from configuration: Configuration) {
        self.configuration = configuration

        var families = Fonts.monospacedFamilies()
        if !families.contains(configuration.appearance.fontFamily) {
            families.insert(configuration.appearance.fontFamily, at: 0)
        }
        fontPopup.removeAllItems()
        fontPopup.addItems(withTitles: families)
        fontPopup.selectItem(withTitle: configuration.appearance.fontFamily)

        fontSizeField.doubleValue = configuration.appearance.fontSize
        fontSizeStepper.doubleValue = configuration.appearance.fontSize

        let palette = Palette(preset: configuration.colours.preset,
                              overrides: configuration.colours.overrides)
        for (name, well) in colourWells {
            well.color = Self.nsColor(palette.colour(named: name) ?? palette.background)
        }
        updateContrast(palette)
        refreshGallery()

        cursorSegments.selectedSegment = Configuration.Behaviour.CursorShape.allCases
            .firstIndex(of: configuration.behaviour.cursorShape) ?? 0
        blinkToggle.state = configuration.behaviour.cursorBlinks ? .on : .off
        confirmToggle.state = configuration.behaviour.confirmBeforeClosingRunningSession ? .on : .off

        scrollbackField.integerValue = configuration.behaviour.scrollbackLines

        promptApplyToggle.state = configuration.appearance.promptStyleApplied ? .on : .off
        for (styleID, card) in promptStyleCards {
            stylePromptCard(card, selected: styleID == configuration.appearance.promptStyle)
        }

        stopShortcutRecording()
        for (command, field) in shortcutFields {
            field.title = Command.shortcut(for: command,
                                           overrides: configuration.keyboard.overrides)?.display ?? "Record"
        }
        shortcutWarning.stringValue = ""

        shellPopup.removeAllItems()
        let choices = shellChoices()
        shellPopup.addItems(withTitles: choices.map(shellTitle))
        if let index = choices.firstIndex(where: { $0 == configuration.shell.path }) {
            shellPopup.selectItem(at: index)
        }
        shellPathField.stringValue = configuration.shell.path ?? ""
        shellNote.textColor = .secondaryLabelColor
        shellNote.stringValue = "Applies to new windows; a shell that is already running stays put."

        preview.configuration = configuration
    }

    /// Hand a change to the application. Deliberately does *not* reload the
    /// controls: that would fight whatever the user is in the middle of typing.
    private func apply(_ updated: Configuration) {
        configuration = updated
        let palette = Palette(preset: updated.colours.preset, overrides: updated.colours.overrides)
        updateContrast(palette)
        preview.configuration = updated
        onChange(updated)
    }

    private func updateContrast(_ palette: Palette) {
        let ratio = Palette.RGB.contrastRatio(palette.foreground, palette.background)
        contrastLabel.stringValue = ratio >= 4.5
            ? String(format: "Text on background: %.1f:1 — readable.", ratio)
            : String(format: "Text on background: %.1f:1 — hard to read. WCAG asks for 4.5:1.", ratio)
        contrastLabel.textColor = ratio >= 4.5 ? .secondaryLabelColor : .systemOrange
    }

    // MARK: - Actions: appearance

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        var updated = configuration
        updated.appearance.fontFamily = sender.titleOfSelectedItem ?? updated.appearance.fontFamily
        apply(updated)
    }

    @objc private func fontSizeTyped(_ sender: NSTextField) {
        setFontSize(sender.doubleValue)
    }

    @objc private func fontSizeStepped(_ sender: NSStepper) {
        setFontSize(sender.doubleValue)
    }

    private func setFontSize(_ size: Double) {
        var updated = configuration
        let range = Configuration.Appearance.fontSizeRange
        updated.appearance.fontSize = min(max(size.rounded(), range.lowerBound), range.upperBound)
        fontSizeField.doubleValue = updated.appearance.fontSize
        fontSizeStepper.doubleValue = updated.appearance.fontSize
        apply(updated)
    }

    // MARK: - Actions: colours

    @objc private func themeCardClicked(_ sender: ThemeCardView) {
        // A gallery card is a deliberate fresh choice, so it clears overrides:
        // what you see on the card is what the terminal shows.
        var updated = configuration
        updated.colours.preset = sender.preset
        updated.colours.overrides = [:]
        apply(updated)
        let palette = Palette(preset: sender.preset, overrides: [:])
        for (name, well) in colourWells {
            well.color = Self.nsColor(palette.colour(named: name) ?? palette.background)
        }
        updateContrast(palette)
        refreshGallery()
    }

    @objc private func revertColours(_ sender: NSButton) {
        // The way back that clears *only* the colours: font, behaviour and
        // shell stay exactly as they were.
        var updated = configuration
        updated.colours.overrides = [:]
        apply(updated)
        let palette = Palette(preset: updated.colours.preset, overrides: [:])
        for (name, well) in colourWells {
            well.color = Self.nsColor(palette.colour(named: name) ?? palette.background)
        }
        updateContrast(palette)
        refreshGallery()
    }

    /// The gallery marks the selected preset as modified when custom overrides exist.
    private func refreshGallery() {
        let modified = !configuration.colours.overrides.isEmpty
        for card in gallery {
            if card.preset == configuration.colours.preset {
                card.selectionState = modified ? .modified : .selected
            } else {
                card.selectionState = .unselected
            }
        }
        galleryModifiedNote.isHidden = !modified
        galleryRevertButton.isHidden = !modified
    }

    @objc private func colourChanged(_ sender: NSColorWell) {
        guard let name = sender.identifier?.rawValue, let colour = Self.rgb(from: sender.color) else { return }
        var updated = configuration
        updated.colours.overrides[name] = colour.hex
        apply(updated)
        refreshGallery()
    }

    @objc private func promptStyleSelected(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var updated = configuration
        updated.appearance.promptStyle = id
        // Picking a style is the same act as asking for it: leaving the toggle
        // off would record a preference that changes nothing, which is exactly
        // the complaint the gallery was meant to answer.
        updated.appearance.promptStyleApplied = true
        apply(updated)
        preview.configuration = updated
        promptApplyToggle.state = .on
        onApplyPrompt?(updated)
        for (styleID, card) in promptStyleCards {
            stylePromptCard(card, selected: styleID == id)
        }
    }

    @objc private func applyPromptToCurrentTab(_ sender: NSButton) {
        onApplyPrompt?(configuration)
    }

    @objc private func promptStyleApplyToggled(_ sender: NSButton) {
        var updated = configuration
        updated.appearance.promptStyleApplied = sender.state == .on
        apply(updated)
    }

    @objc private func selectAdvancedPage(_ sender: NSButton) {
        selectPage("Advanced")
    }

    // MARK: - Actions: behaviour

    @objc private func cursorShapeChanged(_ sender: NSSegmentedControl) {
        guard Configuration.Behaviour.CursorShape.allCases.indices.contains(sender.selectedSegment) else { return }
        var updated = configuration
        updated.behaviour.cursorShape =
            Configuration.Behaviour.CursorShape.allCases[sender.selectedSegment]
        apply(updated)
    }

    @objc private func blinkChanged(_ sender: NSButton) {
        var updated = configuration
        updated.behaviour.cursorBlinks = sender.state == .on
        apply(updated)
    }

    @objc private func scrollbackTyped(_ sender: NSTextField) {
        var updated = configuration
        let range = Configuration.Behaviour.scrollbackRange
        updated.behaviour.scrollbackLines = min(max(sender.integerValue, range.lowerBound), range.upperBound)
        sender.integerValue = updated.behaviour.scrollbackLines
        apply(updated)
    }

    @objc private func confirmChanged(_ sender: NSButton) {
        var updated = configuration
        updated.behaviour.confirmBeforeClosingRunningSession = sender.state == .on
        apply(updated)
    }

    // MARK: - Actions: keyboard

    @objc private func shortcutRecordRequested(_ sender: ShortcutCaptureButton) {
        guard let raw = sender.identifier?.rawValue, let command = Command(rawValue: raw) else { return }
        beginRecording(command)
    }

    /// Start recording a shortcut for `command`, exactly as clicking the command's
    /// button does.
    ///
    /// Internal rather than private because `--settings-test` drives this path: the
    /// monitor it installs sees every key in the application, so one that outlives
    /// the window it belongs to would swallow Escape everywhere — including in the
    /// terminal. That has to be a failing test rather than a review note.
    func beginRecording(_ command: Command) {
        stopShortcutRecording()
        guard let field = shortcutFields[command] else { return }
        recordingShortcut = command
        field.title = "Press shortcut…"
        shortcutWarning.textColor = .secondaryLabelColor
        shortcutWarning.stringValue = "Press a shortcut with at least one modifier. Escape cancels."
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureShortcut(event) ?? event
        }
    }

    @objc private func shortcutRestoreDefault(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let command = Command(rawValue: raw) else { return }
        stopShortcutRecording()
        var updated = configuration
        updated.keyboard.overrides.removeValue(forKey: command.rawValue)
        apply(updated)
        shortcutFields[command]?.title = Command.shortcut(for: command)?.display ?? "Record"
        shortcutWarning.stringValue = ""
    }

    private var recordingShortcut: Command?

    /// Handle a key while recording.
    ///
    /// Returns the event when it is somebody else's — including when nothing is
    /// being recorded, which is what makes a monitor that is on its way out
    /// harmless rather than a trap.
    ///
    /// Internal for the same reason as `beginRecording`: `--settings-test` sends
    /// events through it, because the rules it enforces (a modifier is required, a
    /// key already in use is refused) are claims in the changelog, and a claim
    /// should be an assertion.
    func captureShortcut(_ event: NSEvent) -> NSEvent? {
        guard recordingShortcut != nil else { return event }
        if event.keyCode == 53 {
            stopShortcutRecording()
            shortcutWarning.stringValue = ""
            return nil
        }
        guard let command = recordingShortcut, let field = shortcutFields[command] else { return event }
        guard let shortcut = shortcut(from: event) else {
            shortcutWarning.textColor = .systemRed
            shortcutWarning.stringValue = "That key cannot be used as a shortcut. Try a letter, arrow, or function key."
            return nil
        }
        guard !shortcut.modifiers.isEmpty else {
            shortcutWarning.textColor = .systemRed
            shortcutWarning.stringValue = "Add a modifier such as Command, Control, Option, or Shift."
            return nil
        }
        if let owner = Command.owner(of: shortcut, excluding: command,
                                     overrides: configuration.keyboard.overrides) {
            shortcutWarning.textColor = .systemRed
            shortcutWarning.stringValue = "\(shortcut.display) is already used by \(owner.title)."
            return nil
        }

        stopShortcutRecording()
        shortcutWarning.stringValue = ""
        commitShortcut(shortcut, for: command, field: field)
        return nil
    }

    private func shortcut(from event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [String] = []
        if flags.contains(.command) { modifiers.append("cmd") }
        if flags.contains(.control) { modifiers.append("ctrl") }
        if flags.contains(.option) { modifiers.append("opt") }
        if flags.contains(.shift) { modifiers.append("shift") }

        let namedKeys: [UInt16: String] = [
            36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
            76: "keypadenter", 115: "home", 116: "pageup", 117: "forwarddelete",
            119: "end", 121: "pagedown", 123: "left", 124: "right", 125: "down", 126: "up",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
            98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
            105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17",
            79: "f18", 80: "f19", 90: "f20",
        ]
        let key: String
        if let named = namedKeys[event.keyCode] {
            key = named
        } else if let character = event.charactersIgnoringModifiers?.lowercased(),
                  character.count == 1 {
            switch character {
            case "+": key = "plus"
            case "-": key = "minus"
            case "=": key = "equal"
            case ",": key = "comma"
            case ".": key = "period"
            case "/": key = "slash"
            case "\\": key = "backslash"
            case ";": key = "semicolon"
            case "'": key = "quote"
            case "`": key = "backtick"
            default: key = character
            }
        } else {
            return nil
        }
        return Shortcut(parsing: (modifiers + [key]).joined(separator: "+"))
    }

    private func stopShortcutRecording() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
        if let recordingShortcut, let field = shortcutFields[recordingShortcut] {
            field.title = Command.shortcut(for: recordingShortcut,
                                           overrides: configuration.keyboard.overrides)?.display ?? "Record"
        }
        recordingShortcut = nil
    }

    /// A recording must not outlive its window: the monitor it installs sees every
    /// key the application gets, so one left behind would swallow Escape in the
    /// terminal, in the command palette, and anywhere else that wants it.
    func windowWillClose(_ notification: Notification) {
        stopShortcutRecording()
    }

    private func commitShortcut(_ shortcut: Shortcut, for command: Command, field: ShortcutCaptureButton) {
        var updated = configuration
        updated.keyboard.overrides[command.rawValue] = shortcut.text
        apply(updated)
        field.title = shortcut.display
        shortcutWarning.stringValue = ""
    }

    // MARK: - Actions: shell

    @objc private func shellChanged(_ sender: NSPopUpButton) {
        var updated = configuration
        updated.shell.path = shellChoices()[safe: sender.indexOfSelectedItem] ?? nil
        shellPathField.stringValue = updated.shell.path ?? ""
        shellNote.textColor = .secondaryLabelColor
        shellNote.stringValue = "Applies to new windows; a shell that is already running stays put."
        apply(updated)
    }

    @objc private func useCustomShell(_ sender: NSButton) {
        let path = shellPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else {
            shellNote.textColor = .systemRed
            shellNote.stringValue = "Choose an absolute path to an existing executable file."
            NSSound.beep()
            return
        }

        var updated = configuration
        updated.shell.path = path
        apply(updated)
        shellPopup.removeAllItems()
        let choices = shellChoices()
        shellPopup.addItems(withTitles: choices.map(shellTitle))
        if let index = choices.firstIndex(where: { $0 == path }) {
            shellPopup.selectItem(at: index)
        }
        shellNote.textColor = .secondaryLabelColor
        shellNote.stringValue = "Custom shell saved. Applies to new windows; running shells stay put."
    }

    /// The shells to offer. `/etc/shells` is the system's own record of what is a
    /// valid login shell, which beats a list we would have to maintain.
    private func shellChoices() -> [String?] {
        var paths: Set<String> = ["/bin/zsh", "/bin/bash", "/bin/sh"]
        if let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("/"),
                      FileManager.default.isExecutableFile(atPath: trimmed) else { continue }
                paths.insert(trimmed)
            }
        }
        if let current = configuration.shell.path { paths.insert(current) }
        return [nil] + paths.sorted()
    }

    private func shellTitle(_ path: String?) -> String {
        guard let path else {
            let fallback = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return "Use $SHELL — \(fallback)"
        }
        return path
    }

    // MARK: - Actions: reset and reveal

    @objc private func resetAll(_ sender: Any?) {
        let differences = configuration.differingSections(from: Configuration())
        guard !differences.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Settings are already at their defaults."
            alert.informativeText = "There is nothing to discard."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Restore the original settings?"
        alert.informativeText = "These will go back to their defaults: "
            + differences.joined(separator: ", ") + "."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try Configuration.reset()
        } catch {
            showSettingsError("Could not restore settings", error: error)
            return
        }
        let defaults = Configuration()
        reload(from: defaults)
        onChange(defaults)
    }

    @objc private func revealSettingsFile(_ sender: Any?) {
        do {
            try configuration.save()
        } catch {
            showSettingsError("Could not save settings", error: error)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([Configuration.defaultURL])
    }

    private func showSettingsError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    // MARK: - Reading the window back
    //
    // `--settings-test` prints this, for the same reason `--menu-test` prints the
    // menu bar: a window is the one thing CI cannot look at, so the window
    // describes itself in text instead. These read what `reload` loaded, so a
    // control that failed to pick up the configuration is visible rather than
    // merely invisible.

    /// The settings pages in their navigation order.
    var pageTitles: [String] { pageOrder }

    /// Every command and the shortcut the window is showing for it.
    var shortcutBindings: [(command: String, shortcut: String)] {
        shortcutFields
            .map { (command: $0.key.rawValue, shortcut: $0.value.title) }
            .sorted { $0.command < $1.command }
    }

    /// The colour preset names shown in the gallery.
    ///
    /// Read from the cards themselves rather than from the enum: what the window
    /// shows is the thing worth asserting, and a gallery that stopped drawing a
    /// preset should fail a test rather than quietly agree with the enum.
    var presetTitles: [String] { gallery.map { Self.title($0.preset) } }

    /// The prompt-style cards the gallery is showing, in order.
    var promptStyleTitles: [String] { PromptStyle.allCases.map(\.rawValue) }

    /// The prompt the live preview is drawing, line by line — the thing the
    /// gallery is for. Read from the preview itself, so a style that was recorded
    /// but never reached the drawing would fail a test instead of passing one.
    var previewPromptText: [String] { preview.promptText }

    /// Whether the recorded style is also the one new shells will wear.
    var isPromptStyleApplied: Bool { configuration.appearance.promptStyleApplied }

    /// Press a prompt-style card through its own action and return the preference
    /// it recorded — a card that is drawn but not wired records nothing.
    func choosePromptStyle(_ id: String) -> String {
        promptStyleCards[id]?.performClick(nil)
        return configuration.appearance.promptStyle
    }

    /// Whether a shortcut is being recorded right now.
    var isRecordingShortcut: Bool { recordingShortcut != nil }

    /// The warning line the keyboard page is showing.
    var shortcutWarningText: String { shortcutWarning.stringValue }

    /// A compact summary of loaded controls, for the headless settings proof.
    var appearanceSummary: String {
        let preset = Self.title(configuration.colours.preset)
        return "preset=\(preset) font=\(fontPopup.titleOfSelectedItem ?? "?") "
            + "size=\(fontSizeField.stringValue) "
            + "cursor=\(cursorSegments.label(forSegment: cursorSegments.selectedSegment) ?? "?") "
            + "colours=\(colourWells.count) shells=\(shellPopup.numberOfItems) "
            + "presets=\(Configuration.Colours.Preset.allCases.count) "
            + "promptStyles=\(promptStyleTitles.count)"
    }

    // MARK: - Conversions

    private static func title(_ preset: Configuration.Colours.Preset) -> String {
        switch preset {
        case .dark:
            return "Dark"
        case .ember:
            return "Ember (warm dark)"
        case .fern:
            return "Fern (green dark)"
        case .violet:
            return "Violet (purple dark)"
        case .light:
            return "Light"
        case .paper:
            return "Paper (warm light)"
        case .dawn:
            return "Dawn (soft light)"
        case .highContrast:
            return "High contrast"
        }
    }

    private static func nsColor(_ rgb: Palette.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255,
                alpha: 1)
    }

    private static func rgb(from colour: NSColor) -> Palette.RGB? {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return nil }
        return Palette.RGB(red: UInt8((srgb.redComponent * 255).rounded()),
                           green: UInt8((srgb.greenComponent * 255).rounded()),
                           blue: UInt8((srgb.blueComponent * 255).rounded()))
    }
}

// MARK: - Preview

/// A live sample of the terminal: the chosen font, at the chosen size, in the
/// chosen colours — and, because the gallery above it offers a choice, the
/// chosen **prompt style**.
///
/// It draws with the same `Theme` and palette the real view uses, so what it
/// shows is what the terminal will do rather than a drawing of an idea of it. The
/// prompt is the exception, and deliberately: a shell owns its own prompt, so the
/// style is a preview of how a prompt looks, which is what the note beside the
/// gallery says.
final class PreviewView: NSView {
    var configuration = Configuration() {
        didSet {
            theme = Theme(configuration)
            font = Fonts.resolve(configuration)
            boldFont = Fonts.bold(font)
            // The prompt may have grown a line, and the text may have grown with
            // the font, so the view has to be allowed to ask for a new height.
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// The identity the sample prompt shows. One place, so a gallery card and the
    /// preview cannot describe two different prompts.
    static let sampleUser = NSUserName()
    static let sampleHost = ProcessInfo.processInfo.hostName
        .split(separator: ".").first.map(String.init) ?? "localhost"
    static let samplePath = "~/src/nymbra"
    static let sampleBranch = "main"

    /// The prompt a style draws in a palette. The gallery cards call this too, so
    /// a card cannot show one prompt while the preview shows another.
    static func promptLines(_ style: PromptStyle, palette: Palette) -> [[PromptRun]] {
        style.lines(user: sampleUser, host: sampleHost, path: samplePath,
                    branch: sampleBranch, palette: palette)
    }

    private var theme = Theme(Configuration())
    private var font = Fonts.resolve(Configuration())
    private var boldFont = Fonts.bold(Fonts.resolve(Configuration()))

    /// The prompt the preview is drawing right now, line by line.
    var promptText: [String] { promptRuns.map { $0.map(\.text).joined() } }

    private var promptStyle: PromptStyle {
        PromptStyle(stored: configuration.appearance.promptStyle)
    }

    private var promptRuns: [[PromptRun]] {
        Self.promptLines(promptStyle, palette: theme.palette)
    }

    private func read(_ run: PromptRun) -> (String, Attributes) {
        var attributes = Attributes()
        attributes.foreground = .rgb(r: run.ink.red, g: run.ink.green, b: run.ink.blue)
        if let paper = run.paper {
            attributes.background = .rgb(r: paper.red, g: paper.green, b: paper.blue)
        }
        attributes.bold = run.bold
        return (run.text, attributes)
    }

    /// The document under the prompt. Fixed, because it is there to show the
    /// palette and the font: a document that moved with the prompt would make two
    /// things change at once, and the prompt is the thing being chosen.
    private var document: [[(String, Attributes)]] {
        [
            [("On branch ", sample()), ("main", sample(.indexed(2), bold: true))],
            [("  modified:   ", sample()), ("Sources/Nymbra/SettingsWindow.swift", sample(.indexed(3)))],
            [("warning: ", sample(.indexed(1), bold: true)),
             ("1 file changed, 日本語 ok", sample(.indexed(1)))],
            [("README.md ", sample(.indexed(6), underline: .single)),
             ("docs/ ", sample(.indexed(4))),
             ("highlighted", sample(.default, background: .indexed(3)))],
            [("bold ", sample(bold: true)), ("faint ", sample(faint: true)),
             ("reverse ", sample(reverse: true))]
        ]
    }

    /// Every line the preview draws: the prompt, the document, then the cursor's
    /// own line.
    private var lines: [[(String, Attributes)]] {
        promptRuns.map { $0.map(read) } + document
    }

    private var lineHeight: CGFloat { (configuration.appearance.fontSize * 1.5).rounded() }
    private static let inset: CGFloat = 12

    /// The preview is exactly as tall as what it draws. A fixed height clipped the
    /// document once the font grew, and would have cropped the second line of a
    /// two-line prompt.
    override var intrinsicContentSize: NSSize {
        let height = Self.inset * 2 + CGFloat(lines.count + 1) * lineHeight
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // swiftlint:disable:next function_body_length
    // The preview draws a small document; the limit is for logic, not for this.
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(theme.background)
        ctx.fill(bounds)

        let inset = Self.inset
        let descent = CTFontGetDescent(font)
        let samples = lines

        for (index, runs) in samples.enumerated() {
            let baseline = bounds.height - inset - CGFloat(index + 1) * lineHeight + descent
            var x = inset
            for (text, attributes) in runs {
                let (foreground, background) = theme.resolve(attributes, reversed: false)
                let runFont = attributes.bold ? boldFont : self.font
                let attributed = NSAttributedString(string: text, attributes: [
                    .init(kCTFontAttributeName as String): runFont,
                    .init(kCTForegroundColorAttributeName as String): foreground,
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

                if let background {
                    ctx.setFillColor(background)
                    ctx.fill(CGRect(x: x, y: bounds.height - inset - CGFloat(index + 1) * lineHeight,
                                    width: width, height: lineHeight))
                }
                if attributes.underline != .none {
                    ctx.setFillColor(foreground)
                    ctx.fill(CGRect(x: x, y: bounds.height - inset - CGFloat(index + 1) * lineHeight + 1,
                                    width: width, height: 1))
                }

                ctx.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, ctx)
                x += width
            }
        }

        // The cursor, so its colour is part of the preview too.
        let cursorWidth = Fonts.advanceWidth(of: font)
        ctx.setFillColor(theme.cursor)
        ctx.fill(CGRect(x: inset,
                        y: bounds.height - inset - CGFloat(samples.count + 1) * lineHeight,
                        width: cursorWidth,
                        height: lineHeight))
    }

    private func sample(_ colour: Colour = .default,
                        bold: Bool = false,
                        faint: Bool = false,
                        reverse: Bool = false,
                        underline: UnderlineStyle = .none,
                        background: Colour = .default) -> Attributes {
        var attributes = Attributes()
        attributes.foreground = colour
        attributes.background = background
        attributes.bold = bold
        attributes.faint = faint
        attributes.inverse = reverse
        attributes.underline = underline
        return attributes
    }
}

private final class ShortcutCaptureButton: NSButton {}

private final class ThemeCardView: HoverCardButton {
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

private extension Array {
    /// A subscript that answers with nothing rather than trapping. Used for
    /// mapping a popup's index back to a value, where a stale index is a state
    /// the user can reach and a crash is not an acceptable answer.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
