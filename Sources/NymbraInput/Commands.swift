import Foundation

/// The things Nymbra does with a key press, as opposed to the bytes it forwards
/// to the program running inside it.
///
/// One list, here rather than in the menu builder and again in the key handler,
/// so that the shortcut the settings window *shows* is by construction the
/// shortcut that is in force. Drift between those two is how an app ends up
/// advertising a shortcut that does nothing.
public enum Command: String, CaseIterable, Sendable {
    case newWindow
    case newTab
    case closeTab
    case nextTab
    case previousTab
    case splitRight
    case splitDown
    case closePane
    case focusNextPane
    case focusPreviousPane
    case copy
    case paste
    case selectAll
    case clearBuffer
    case settings
    case increaseFontSize
    case decreaseFontSize

    /// What a menu calls it.
    public var title: String {
        switch self {
        case .newWindow:
            return "New Window"
        case .newTab:
            return "New Tab"
        case .closeTab:
            return "Close Tab"
        case .nextTab:
            return "Next Tab"
        case .previousTab:
            return "Previous Tab"
        case .splitRight:
            return "Split Right"
        case .splitDown:
            return "Split Down"
        case .closePane:
            return "Close Pane"
        case .focusNextPane:
            return "Focus Next Pane"
        case .focusPreviousPane:
            return "Focus Previous Pane"
        case .copy:
            return "Copy"
        case .paste:
            return "Paste"
        case .selectAll:
            return "Select All"
        case .clearBuffer:
            return "Clear Buffer"
        case .settings:
            return "Settings\u{2026}"
        case .increaseFontSize:
            return "Increase Font Size"
        case .decreaseFontSize:
            return "Decrease Font Size"
        }
    }

    /// A sentence for the settings window, since "Clear Buffer" is not obvious.
    public var explanation: String {
        switch self {
        case .newWindow:
            return "Open another window, with a shell of its own"
        case .newTab:
            return "A new shell in this window, filling it"
        case .closeTab:
            return "Close the current tab"
        case .nextTab:
            return "Switch to the next tab"
        case .previousTab:
            return "Switch to the previous tab"
        case .splitRight:
            return "Put a new shell beside this one"
        case .splitDown:
            return "Put a new shell below this one"
        case .closePane:
            return "Close the pane with the keyboard; the window, if it is the last one"
        case .focusNextPane:
            return "Move the keyboard to the next pane"
        case .focusPreviousPane:
            return "Move the keyboard to the previous pane"
        case .copy:
            return "Copy the selection to the clipboard"
        case .paste:
            return "Paste the clipboard into the terminal"
        case .selectAll:
            return "Select everything on screen"
        case .clearBuffer:
            return "Clear the screen and scrollback"
        case .settings:
            return "Open this window"
        case .increaseFontSize:
            return "Make the text bigger"
        case .decreaseFontSize:
            return "Make the text smaller"
        }
    }

    /// The shortcut until the user changes it.
    ///
    /// These follow the platform's conventions rather than being invented, so
    /// that muscle memory from other applications transfers.
    public var defaultShortcut: Shortcut? {
        switch self {
        case .newWindow:
            return Shortcut(parsing: "cmd+n")
        case .newTab:
            return Shortcut(parsing: "cmd+shift+t")
        case .closeTab:
            return Shortcut(parsing: "cmd+shift+w")
        case .nextTab:
            return Shortcut(parsing: "cmd+shift+rightbracket")
        case .previousTab:
            return Shortcut(parsing: "cmd+shift+leftbracket")
        case .splitRight:
            return Shortcut(parsing: "cmd+d")
        case .splitDown:
            return Shortcut(parsing: "cmd+shift+d")
        case .closePane:
            return Shortcut(parsing: "cmd+w")
        case .focusNextPane:
            return Shortcut(parsing: "cmd+rightbracket")
        case .focusPreviousPane:
            return Shortcut(parsing: "cmd+leftbracket")
        case .copy:
            return Shortcut(parsing: "cmd+c")
        case .paste:
            return Shortcut(parsing: "cmd+v")
        case .selectAll:
            return Shortcut(parsing: "cmd+a")
        case .clearBuffer:
            return Shortcut(parsing: "cmd+k")
        case .settings:
            return Shortcut(parsing: "cmd+comma")
        case .increaseFontSize:
            return Shortcut(parsing: "cmd+equal")
        case .decreaseFontSize:
            return Shortcut(parsing: "cmd+minus")
        }
    }

    /// The shortcut in force: the user's if it parses, otherwise the default.
    ///
    /// Falling back rather than leaving the command with no shortcut is
    /// deliberate. A typo in one line of a config file should cost the user that
    /// one binding, not every command in the list.
    public static func shortcut(for command: Command, overrides: [String: String] = [:]) -> Shortcut? {
        if let text = overrides[command.rawValue], let shortcut = Shortcut(parsing: text) {
            return shortcut
        }
        return command.defaultShortcut
    }

    /// Every command with the shortcut in force, in a stable order. The settings
    /// window renders exactly this.
    public static func bindings(overrides: [String: String] = [:]) -> [(command: Command, shortcut: Shortcut?)] {
        allCases.map { ($0, shortcut(for: $0, overrides: overrides)) }
    }

    /// The command that already holds a shortcut, if any. The settings window
    /// uses this to refuse a duplicate at the moment the user types it, rather
    /// than silently letting two commands fight over one chord.
    public static func owner(
        of shortcut: Shortcut,
        excluding command: Command,
        overrides: [String: String] = [:]
    ) -> Command? {
        for (candidate, candidateShortcut) in bindings(overrides: overrides)
        where candidate != command && candidateShortcut == shortcut {
            return candidate
        }
        return nil
    }

    /// The command a key event performs, if any.
    public static func matching(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: Keyboard.Modifiers,
        overrides: [String: String] = [:]
    ) -> Command? {
        for (command, shortcut) in bindings(overrides: overrides) {
            guard let shortcut else { continue }
            if shortcut.matches(keyCode: keyCode,
                                charactersIgnoringModifiers: charactersIgnoringModifiers,
                                modifiers: modifiers) {
                return command
            }
        }
        return nil
    }
}
