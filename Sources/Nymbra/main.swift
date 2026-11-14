import AppKit
import Foundation
import NymbraCore
import NymbraInput

// MARK: - Configuration
//
// Loaded before anything else, and before the shell is spawned, because the
// shell choice comes from it. Loading is total: a missing file is the defaults,
// and a broken one is the defaults plus a warning (ADR-0006). A terminal must
// not refuse to start because of its own settings file.
let loaded = Configuration.load()
for warning in loaded.warnings {
    FileHandle.standardError.write(Data("nymbra: \(warning)\n".utf8))
}
let settings = loaded.configuration

// MARK: - Window tabbing is off
//
// Nymbra has its own tabs: a strip inside the window, with the `+` item at the end
// of it, a title per tab, the unread dot, and panes that belong to one tab and not
// to another. macOS window tabbing draws a *second* strip, above that one, for a
// tab group AppKit maintains — and whether it does is the system's "prefer tabs
// when opening documents" setting, not something Nymbra gets a say in. The second
// strip knows about none of the above. It cannot: a `+` item and an unread dot are
// not things AppKit has ever heard of.
//
// The switch has to be thrown before any window exists — AppKit reads it when a
// window is created, and the View menu's "Show Tab Bar" grows from it at launch —
// which makes this the first thing the process says. Every window also refuses to
// join a tab group on its own account (`TerminalWindow.init`), so the answer
// belongs to the window and not only to the application that made it.
//
// The headless proofs get the same answer deliberately: a test that merged two
// windows into one tab group because the machine's owner prefers tabs would be a
// test passing for a reason that has nothing to do with Nymbra.
NSWindow.allowsAutomaticWindowTabbing = false

if CommandLine.arguments.contains("--pty-test") {
    runPTYTest(shell: settings.shell.path)
    exit(0)
}

for (flag, debug) in [("--screen-test", false), ("--screen-debug", true)] {
    if let index = CommandLine.arguments.firstIndex(of: flag) {
        let command = index + 1 < CommandLine.arguments.count
            ? CommandLine.arguments[index + 1]
            : "echo hello"
        runScreenTest(command, debug: debug, shell: settings.shell.path)
        exit(0)
    }
}

// Colour and menu proofs are pure functions of the settings, so they run before
// a shell is ever spawned — and before AppKit is asked to do anything but exist.
if CommandLine.arguments.contains("--theme-test") {
    runThemeTest()
    exit(0)
}

if CommandLine.arguments.contains("--menu-test") {
    // Menus are AppKit objects, so the application has to exist for them to be
    // built. Nothing is activated and no window opens; this process exits here.
    _ = NSApplication.shared
    runMenuTest(configuration: settings)
    exit(0)
}

if CommandLine.arguments.contains("--settings-test") {
    NSApplication.shared.setActivationPolicy(.prohibited)
    exit(runSettingsTest(configuration: settings) ? 0 : 1)
}

// The command palette, driven with real key events: arrows, Return and Escape are
// received by the field *editor*, so a palette that reads them off the field is a
// palette whose keys do nothing.
if CommandLine.arguments.contains("--palette-test") {
    exit(runPaletteTest(configuration: settings) ? 0 : 1)
}

// Find, end to end: a live shell prints, the bar is typed into, and the highlight
// it draws is judged by the pixels on the screen rather than by its own state.
if CommandLine.arguments.contains("--find-test") {
    exit(runFindTest(configuration: settings) ? 0 : 1)
}

// The grid the shell is told about is invisible on a test runner and easy to
// transpose, so it is asked for directly.
if CommandLine.arguments.contains("--resize-test") {
    runResizeTest(configuration: settings)
    exit(0)
}

// Closing the window with the red button used to be a dead end, and a dead end
// is easy to fix and easy to break again, so the whole round trip is asserted.
if CommandLine.arguments.contains("--window-test") {
    exit(runWindowTest(configuration: settings) ? 0 : 1)
}

// Splits, asserted the way the milestone is written: four panes, four shells,
// resized and closed independently. Nothing is shown; four real shells run.
if CommandLine.arguments.contains("--split-test") {
    exit(runSplitTest(configuration: settings) ? 0 : 1)
}

// Tabs, asserted the way they are used: a strip that is there, tabs that can be
// made and closed, and a shell in each that no other tab can disturb.
if CommandLine.arguments.contains("--tabs-test") {
    exit(runTabsTest(configuration: settings) ? 0 : 1)
}

// Composing text with an input method, and drawing a frame at once (DEC 2026).
if CommandLine.arguments.contains("--input-test") {
    exit(runInputTest(configuration: settings) ? 0 : 1)
}

// Knowing where you are: tab and window titles and the path bar follow the
// shell's folder and running program, read from the kernel.
if CommandLine.arguments.contains("--location-test") {
    exit(runLocationTest(configuration: settings) ? 0 : 1)
}

if CommandLine.arguments.contains("--mouse-test") {
    exit(runMouseTest() ? 0 : 1)
}

// Shell integration, asserted against a real zsh: that the marks a terminal
// needs actually arrive, and that the user's own startup file still runs.
if CommandLine.arguments.contains("--shell-integration-test") {
    exit(runShellIntegrationTest() ? 0 : 1)
}

// A notification when a long command finishes, asserted against a real zsh: the
// timing comes from the shell's own marks, so without one there is no duration to
// measure and nothing to decide.
if CommandLine.arguments.contains("--notify-test") {
    exit(runNotifyTest() ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let controller = AppController(configuration: settings)
// Held here as well as by AppKit: `NSApplication.delegate` is a weak reference,
// and a delegate that is deallocated takes "reopen the window" with it.
let delegate = AppDelegate(controller: controller)
app.delegate = delegate

// The first window is made like every other one. It used to be a special case,
// because `forkpty` had to run before AppKit was initialised (ADR-0002); with
// `posix_spawn` (ADR-0007) there is no reason for it, and one path is one path to
// get wrong.
controller.start()

app.activate(ignoringOtherApps: true)
app.run()
