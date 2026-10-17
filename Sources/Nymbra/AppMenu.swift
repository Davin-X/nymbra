import AppKit
import NymbraCore
import NymbraInput

/// The menu bar.
///
/// Every command's key equivalent comes from `Command.shortcut(for:overrides:)`,
/// which is the same function the settings window reads. That is deliberate: it
/// makes "the menu advertises a shortcut the application does not honour"
/// impossible rather than merely unlikely.
enum AppMenu {

    /// Build the menu bar and install it, including the Window menu the
    /// application uses to track its windows.
    static func install(controller: AppController, configuration: Configuration) {
        let menus = build(controller: controller, configuration: configuration)
        NSApp.mainMenu = menus.main
        NSApp.windowsMenu = menus.window
    }

    /// A pure function of the configuration, so `--menu-test` can print exactly
    /// what would be installed without a window ever opening.
    static func build(controller: AppController,
                      configuration: Configuration) -> (main: NSMenu, window: NSMenu) {
        let main = NSMenu()
        main.addItem(applicationMenu(controller: controller, configuration: configuration))
        main.addItem(fileMenu(controller: controller, configuration: configuration))
        main.addItem(editMenu(controller: controller, configuration: configuration))
        main.addItem(viewMenu(controller: controller, configuration: configuration))
        let window = windowMenu()
        main.addItem(window)
        main.addItem(helpMenu(controller: controller, configuration: configuration))
        // The Window menu is also handed to AppKit, which populates it with the
        // open windows.
        return (main, window.submenu ?? NSMenu(title: "Window"))
    }

    // MARK: - The menus

    private static func applicationMenu(controller: AppController,
                                        configuration: Configuration) -> NSMenuItem {
        let root = NSMenuItem(title: "Nymbra", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Nymbra")
        root.submenu = menu

        menu.addItem(plain("About Nymbra", #selector(AppController.about(_:)), target: controller))
        menu.addItem(.separator())
        menu.addItem(command(.settings, #selector(AppController.showSettings(_:)),
                             target: controller, configuration: configuration))
        menu.addItem(plain("Reveal Settings File", #selector(AppController.revealSettingsFile(_:)),
                           target: controller))
        menu.addItem(.separator())
        menu.addItem(standard("Hide Nymbra", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
                              key: "h", modifiers: [.command, .option]))
        menu.addItem(standard("Show All", #selector(NSApplication.unhideAllApplications(_:)),
                              key: "", modifiers: []))
        menu.addItem(.separator())
        menu.addItem(standard("Quit Nymbra", #selector(NSApplication.terminate(_:)), key: "q"))
        return root
    }

    /// File holds what makes a window and what ends one. Both are ordinary
    /// platform behaviour, which is the point: a terminal that cannot open a
    /// second window is not one you can work in.
    private static func fileMenu(controller: AppController,
                                 configuration: Configuration) -> NSMenuItem {
        let root = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "File")
        root.submenu = menu

        menu.addItem(command(.newWindow, #selector(AppController.newWindow(_:)),
                             target: controller, configuration: configuration))
        menu.addItem(.separator())
        menu.addItem(standard("Close Window", #selector(NSWindow.performClose(_:)), key: "w"))
        return root
    }

    private static func editMenu(controller: AppController,
                                 configuration: Configuration) -> NSMenuItem {
        let root = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Edit")
        root.submenu = menu

        menu.addItem(command(.copy, #selector(AppController.copy(_:)),
                             target: controller, configuration: configuration))
        menu.addItem(command(.paste, #selector(AppController.paste(_:)),
                             target: controller, configuration: configuration))
        menu.addItem(command(.selectAll, #selector(AppController.selectAll(_:)),
                             target: controller, configuration: configuration))
        menu.addItem(.separator())
        menu.addItem(command(.clearBuffer, #selector(AppController.clearBuffer(_:)),
                             target: controller, configuration: configuration))
        return root
    }

    private static func viewMenu(controller: AppController,
                                 configuration: Configuration) -> NSMenuItem {
        let root = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "View")
        root.submenu = menu

        menu.addItem(command(.increaseFontSize, #selector(AppController.increaseFontSize(_:)),
                             target: controller, configuration: configuration))
        menu.addItem(command(.decreaseFontSize, #selector(AppController.decreaseFontSize(_:)),
                             target: controller, configuration: configuration))
        menu.addItem(.separator())
        menu.addItem(standard("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)),
                              key: "f", modifiers: [.command, .control]))
        return root
    }

    private static func windowMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Window")
        root.submenu = menu
        menu.addItem(standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(standard("Zoom", #selector(NSWindow.performZoom(_:)), key: "", modifiers: []))
        menu.addItem(.separator())
        menu.addItem(standard("Close Window", #selector(NSWindow.performClose(_:)), key: "w"))
        menu.addItem(.separator())
        menu.addItem(plain("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)),
                           target: NSApp))
        return root
    }

    private static func helpMenu(controller: AppController,
                                 configuration: Configuration) -> NSMenuItem {
        let root = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Help")
        root.submenu = menu
        menu.addItem(plain("Nymbra on GitHub", #selector(AppController.openProjectPage(_:)),
                           target: controller))
        return root
    }

    // MARK: - Items

    /// An item with no key equivalent, aimed at a specific target.
    private static func plain(_ title: String, _ action: Selector, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }

    /// An item aimed at the responder chain, for the standard window and
    /// application actions AppKit already implements.
    private static func standard(_ title: String, _ action: Selector, key: String,
                                 modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// An item for one of our commands, with the shortcut that is actually in
    /// force — the user's, if they changed it.
    private static func command(_ command: Command, _ action: Selector, target: AnyObject,
                                configuration: Configuration) -> NSMenuItem {
        let item = plain(command.title, action, target: target)
        guard let shortcut = Command.shortcut(for: command,
                                              overrides: configuration.keyboard.overrides) else {
            return item
        }
        item.keyEquivalent = shortcut.menuKey
        item.keyEquivalentModifierMask = modifiers(of: shortcut.modifiers)
        return item
    }

    static func modifiers(of modifiers: Keyboard.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    // MARK: - Reading the menu back
    //
    // CI cannot look at a menu bar, so it reads a description of one instead.
    // This is the same trick as `--screen-test`: turn the thing nobody can see
    // into text somebody can assert on.

    static func describe(_ menu: NSMenu) -> [String] {
        var lines: [String] = []
        for item in menu.items {
            if item.isSeparatorItem { continue }
            lines.append("\(item.title)\t\(describeKey(of: item))")
            if let submenu = item.submenu {
                lines.append(contentsOf: describe(submenu).map { "  \($0)" })
            }
        }
        return lines
    }

    private static func describeKey(of item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var text = ""
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { text += "\u{2303}" }
        if mask.contains(.option) { text += "\u{2325}" }
        if mask.contains(.shift) { text += "\u{21E7}" }
        if mask.contains(.command) { text += "\u{2318}" }
        return text + name(of: item.keyEquivalent)
    }

    private static func name(of key: String) -> String {
        guard key.count == 1, let scalar = key.unicodeScalars.first else { return key.uppercased() }
        switch scalar.value {
        case 0xF700: return "\u{2191}"
        case 0xF701: return "\u{2193}"
        case 0xF702: return "\u{2190}"
        case 0xF703: return "\u{2192}"
        case 0xF704...0xF717: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "\u{2326}"
        case 0xF729: return "\u{2196}"
        case 0xF72B: return "\u{2198}"
        case 0xF72C: return "\u{21DE}"
        case 0xF72D: return "\u{21DF}"
        case 0x0D: return "\u{21A9}"
        case 0x09: return "\u{21E5}"
        case 0x1B: return "\u{238B}"
        case 0x08: return "\u{232B}"
        case 0x20: return "Space"
        default: return key.uppercased()
        }
    }
}
