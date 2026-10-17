import AppKit
import Foundation
import NymbraCore

// MARK: - Headless proofs
//
// CI cannot look at a window, so correctness is demonstrated by driving the
// emulator with real bytes and printing what the screen model made of them.

/// Spawn a login shell, run one command, and print every raw byte it produced.
///
/// The shell and the number of bytes read are named on stderr on purpose: "the
/// PTY test failed" says nothing about whether the shell never started, started
/// and printed only a banner, or died on the way up. The byte count is the
/// difference between a race and a bug in the shell lookup.
func runPTYTest(shell: String?) {
    do {
        let resolved = resolveShell(shell)
        FileHandle.standardError.write(Data("nymbra: pty-test shell \(resolved)\n".utf8))

        let terminal = try Terminal(size: GridSize(rows: 24, cols: 80), shell: resolved)
        terminal.send("echo PTY_OK; echo TERM=$TERM; tty; /bin/pwd; id -un; uname -m; exit\n")

        var output = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = ptyRead(terminal.master, into: &chunk)
            if count <= 0 { break }
            output.append(contentsOf: chunk[0..<count])
        }
        waitpid(terminal.pid, nil, 0)
        FileHandle.standardError.write(Data("nymbra: pty-test read \(output.count) bytes\n".utf8))
        FileHandle.standardOutput.write(Data(output))

        // Exiting 0 after printing nothing would make the smoke test pass on an
        // empty file, which is the one outcome it must never do.
        if output.isEmpty {
            FileHandle.standardError.write(
                Data("nymbra: the shell produced no output at all\n".utf8))
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

/// Feed a shell's output through the real parser and print the resulting screen.
/// This is the closest thing to "does a terminal render this correctly" that a
/// headless process can assert.
///
/// The default dump is the text a user would see. `--screen-debug` instead marks
/// blank cells with `·` and the second half of a wide character with `→`, which
/// is what you want when diagnosing, but which would defeat text assertions.
func runScreenTest(_ command: String, debug: Bool, shell: String?) {
    do {
        let terminal = try Terminal(size: GridSize(rows: 24, cols: 80), shell: shell)
        terminal.send(command + "\nexit\n")

        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = ptyRead(terminal.master, into: &chunk)
            if count <= 0 { break }
            terminal.parser.feed(Array(chunk[0..<count]))
        }
        waitpid(terminal.pid, nil, 0)
        print(debug ? terminal.screen.debugDump() : terminal.screen.dump())
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

/// Print every preset and how legible each of its colours is, so CI can assert
/// that no preset ships a colour its own background swallows.
///
/// The `worst` line is the assertion: it ends in `readable` or in `UNREADABLE`.
/// This exists because `ls` prints directories in ANSI colour 4, and a dim blue
/// on a dark background does not look like a colour setting — it looks like the
/// filenames are missing.
func runThemeTest() {
    for preset in Configuration.Colours.Preset.allCases {
        let palette = Palette(preset: preset)
        // The interface colours that are *text*: `selection` is a background for
        // text that carries its own contrast, and the background does not need
        // to contrast with itself.
        let named = ["foreground", "cursor"] + Palette.ansiNames
        var worst = Double.greatestFiniteMagnitude

        print("\(preset) background \(palette.background.hex)")
        for name in named {
            guard let colour = palette.colour(named: name) else { continue }
            let raw = Palette.RGB.contrastRatio(colour, palette.background)
            let drawn = Palette.readable(colour, on: palette.background)
            let final = Palette.RGB.contrastRatio(drawn, palette.background)
            worst = min(worst, final)
            let note = drawn == colour ? "" : " (lifted to \(drawn.hex))"
            print("  " + pad(name, 15) + colour.hex
                  + pad(String(format: "%.2f:1", raw), 10, right: true) + note)
        }
        print("  worst \(String(format: "%.2f", worst)):1 "
              + (worst >= 4.5 ? "readable" : "UNREADABLE"))
    }
}

/// The menu bar is not visible to a test runner either, so `--menu-test` prints
/// what would be installed, key equivalents included.
func runMenuTest(configuration: Configuration) {
    let controller = AppController(configuration: configuration)
    let menus = AppMenu.build(controller: controller, configuration: configuration)
    for line in AppMenu.describe(menus.main) { print(line) }
}

/// The settings window is the largest piece of UI in the project and the one a
/// test runner can least easily look at, so it prints itself too: build it, list
/// what each control loaded, and exit without showing anything.
func runSettingsTest(configuration: Configuration) {
    let controller = SettingsWindowController(configuration: configuration) { _ in }
    print("tabs\t" + controller.tabTitles.joined(separator: ","))
    print("appearance\t" + controller.appearanceSummary)
    print("presets\t" + controller.presetTitles.joined(separator: ","))
    for binding in controller.shortcutBindings {
        print("shortcut\t\(binding.command)\t\(binding.shortcut)")
    }
}

/// Prove that the view and the shell agree about the grid — and, in particular,
/// that they agree about *which* dimension is which.
///
/// A transposed pair is invisible in review and, once running, does not look
/// like a size at all: the shell formats its output to a width equal to the
/// window's height, and every wide line wraps in the middle of a field. That is
/// exactly how `eza --icons -l` came to split its rows in half.
///
/// So the assertion is the relationship a transposed grid breaks (a window wider
/// than it is tall must report more columns than rows), plus the viewer taking
/// the numbers it was handed. Only a window can answer this, hence a flag.
func runResizeTest(configuration: Configuration) {
    let screen = Screen(rows: 24, cols: 80)
    let view = TermView(
        frame: NSRect(x: 0, y: 0, width: 1000, height: 640),
        screen: screen,
        configuration: configuration
    )

    var reported: GridSize?
    view.onResize = { reported = $0 }

    var failures = 0
    let windows: [(Double, Double)] = [(880, 560), (700, 500), (420, 260)]
    for (width, height) in windows {
        reported = nil
        view.setFrameSize(NSSize(width: width, height: height))

        guard let size = reported else {
            print("resize-test: \(Int(width))x\(Int(height)) FAIL reported no resize")
            failures += 1
            continue
        }

        // What the view says it shows, and what the model ends up with when
        // handed that value, have to be the same grid.
        screen.resize(rows: size.rows, cols: size.cols)
        let agrees = size == view.grid
        let ordered = size.cols > size.rows
        let modelled = screen.rows == size.rows && screen.cols == size.cols
        let ok = agrees && ordered && modelled
        print("resize-test: window \(Int(width))x\(Int(height)) -> "
              + "\(size.rows) rows x \(size.cols) cols " + (ok ? "ok" : "FAIL"))
        if !ok { failures += 1 }
    }

    if failures > 0 {
        FileHandle.standardError.write(Data("nymbra: \(failures) resize failure(s)\n".utf8))
        exit(1)
    }
}

/// Close a window and get a working one back.
///
/// This is the one thing a person does without thinking, and it was completely
/// broken: the red button ended the shell, the application stayed alive with no
/// window, and a Dock click did nothing — the only way back to a terminal was to
/// quit and start again. A dead end is easy to fix and just as easy to break
/// again, so the whole round trip is asserted here rather than checked by hand.
///
/// It is a window-lifecycle question, so it needs AppKit. It is still headless:
/// nothing is shown, and the answer is one printed line.
func runWindowTest(configuration: Configuration) -> Bool { // swiftlint:disable:this function_body_length
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // Closing is not the part worth testing; getting a *live* shell back is. The
    // dialogue that guards a running command is switched off for the test,
    // because a modal question in a headless process is a hang, not a failure.
    var quiet = configuration
    quiet.behaviour.confirmBeforeClosingRunningSession = false

    let controller = AppController(configuration: quiet)
    guard let first = controller.makeWindow() else {
        print("window-test\tFAIL: no window could be made")
        return false
    }

    // The red button, as far as the application is concerned.
    first.window.performClose(nil)
    guard first.isClosed else {
        print("window-test\tFAIL: closing the window did not record it as closed")
        return false
    }

    // A Dock click, or `open` on the bundle.
    guard let second = controller.reopenWindow(), second !== first else {
        print("window-test\tFAIL: reopening produced no new window")
        return false
    }

    // The shell in the new window has to be a live process, not a corpse with a
    // prompt already drawn on it. `$((6*7))` only exists as 42 if it ran.
    let shell = second.panes[second.focusedPane]!.terminal
    shell.send("echo NYMBRA_REOPEN_$((6*7))\n")
    let deadline = Date().addingTimeInterval(5)
    var screen = ""
    while Date() < deadline {
        // The screen is only ever touched on the main queue, so the run loop has
        // to turn for the output to arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        screen = shell.screen.dump()
        if screen.contains("NYMBRA_REOPEN_42") { break }
    }

    let ran = screen.contains("NYMBRA_REOPEN_42")
    let alive = kill(shell.pid, 0) == 0
    print("window-test\tclosed=\(first.isClosed) reopened=\(second !== first) "
          + "shellAlive=\(alive) ranCommand=\(ran)")

    for pane in first.panes.values { pane.terminal.terminate() }
    for pane in second.panes.values { pane.terminal.terminate() }
    return ran && alive
}

/// Four panes, four shells, and nothing shared between them.
///
/// This is the milestone's acceptance criterion, asserted headlessly. Every part
/// of it is invisible on screen: a pane drawn at the window's size looks correct
/// until its output wraps, two panes sharing a screen model look correct until
/// both print at once, and a pane closed without handing its space back leaves a
/// seam nobody notices.
///
/// The shells are real, and each is asked a question whose answer can only be in
/// its own pane.
func runSplitTest(configuration: Configuration) -> Bool { // swiftlint:disable:this function_body_length
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // The same reasoning as `--window-test`: a modal question in a headless
    // process is a hang, not a failure.
    var quiet = configuration
    quiet.behaviour.confirmBeforeClosingRunningSession = false

    let window: TerminalWindow
    do {
        window = try TerminalWindow(configuration: quiet)
    } catch {
        print("split-test\tFAIL: no window: \(error)")
        return false
    }
    window.onSpawnFailure = { error in print("split-test\tspawn failed: \(error)") }

    let containerSize = (width: Double(window.container.bounds.width),
                         height: Double(window.container.bounds.height))

    // What one pane of this window is told before there are four of them: the
    // size every pane's size has to be smaller than, or the shells are being told
    // about the window and not about their own quarters.
    let firstID = window.focusedPane
    let wholeWindowGrid = window.panes[firstID]!.view.grid

    // The shape `PaneLayoutSuite` asserts in arithmetic: side by side, then each
    // half stacked. Split the focused pane each time, which is what ⌘D does.
    guard window.split(.sideBySide), window.split(.stacked) else {
        print("split-test\tFAIL: a split did not happen")
        return false
    }
    window.focus(firstID)
    guard window.split(.stacked) else {
        print("split-test\tFAIL: the fourth pane did not happen")
        return false
    }

    let ids = window.layout.panes
    guard ids.count == 4 else {
        print("split-test\tFAIL: expected four panes, found \(ids.count)")
        return false
    }

    // 1. The views are where the layout says they are, and every shell is told the
    //    size of its own pane.
    let placed = Dictionary(uniqueKeysWithValues:
        window.container.placedPanes.map { ($0.pane, $0.frame) })
    var placedExactly = true
    for id in ids {
        guard let pane = window.panes[id], let frame = placed[id] else {
            placedExactly = false
            continue
        }
        let expected = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        if pane.view.frame != expected { placedExactly = false }
    }

    let grids = ids.map { window.panes[$0]!.view.grid }
    let quarterSized = grids.allSatisfy {
        $0.cols < wholeWindowGrid.cols && $0.rows < wholeWindowGrid.rows
    }
    let sameGrid = grids.dropFirst().allSatisfy { $0 == grids[0] }

    // 2. Four shells, four screen models. Each is asked to print a marker only it
    //    can produce, and each may show its own and nobody else's.
    for (index, id) in ids.enumerated() {
        window.panes[id]!.terminal.send("echo NYMBRA_PANE_\(index)_OK\n")
    }

    func ownMarkerOnly() -> Bool {
        ids.enumerated().allSatisfy { index, id in
            let dump = window.panes[id]!.terminal.screen.dump()
            guard dump.contains("NYMBRA_PANE_\(index)_OK") else { return false }
            return !ids.enumerated().contains { other, _ in
                other != index && dump.contains("NYMBRA_PANE_\(other)_OK")
            }
        }
    }

    // 3. One pane runs a program, and only that pane knows it: job control is per
    //    terminal, which a shared one could not be.
    let busy = ids[3]
    let idle = ids[0]
    window.panes[busy]!.terminal.send("sleep 30\n")

    let deadline = Date().addingTimeInterval(10)
    var independent = false
    var jobIsolated = false
    while Date() < deadline {
        // The screen is only ever touched on the main queue, so the run loop has
        // to turn for any of this to arrive.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        independent = ownMarkerOnly()
        jobIsolated = window.panes[busy]!.terminal.hasForegroundJob
            && !window.panes[idle]!.terminal.hasForegroundJob
        if independent && jobIsolated { break }
    }
    window.panes[busy]!.terminal.send([0x03])  // Ctrl+C, so nothing is left running

    // 4. A divider drag reaches the shells: a pane that changed width is a pane
    //    whose shell was told about it.
    let left = ids[0]
    let right = ids[2]
    var dragReachedTheShells = false
    if let divider = window.layout.divider(nearX: containerSize.width / 2, y: 40,
                                           in: containerSize) {
        let leftBefore = window.panes[left]!.view.grid.cols
        let rightBefore = window.panes[right]!.view.grid.cols
        window.moveDivider(divider, to: 200)
        let leftAfter = window.panes[left]!.view.grid.cols
        let rightAfter = window.panes[right]!.view.grid.cols
        dragReachedTheShells = leftAfter < leftBefore && rightAfter > rightBefore
    }

    // 5. Closing one pane leaves the others exactly as they were: the same
    //    shells, still holding their own output. A window that lost a pane must
    //    not have disturbed the sessions in it.
    let closing = ids[3]
    let sibling = ids[2]
    let survivors = ids.filter { $0 != closing }
    let pidsBefore = survivors.map { window.panes[$0]!.terminal.pid }
    let siblingHeightBefore = window.panes[sibling]!.view.frame.height

    window.focus(closing)
    let closed = window.close(closing)

    let remaining = window.layout.panes
    let closedIndependently = closed && remaining.count == 3 && !remaining.contains(closing)
    let sameShells = remaining.map { window.panes[$0]!.terminal.pid } == pidsBefore
    let spaceReturned = window.panes[sibling]!.view.frame.height > siblingHeightBefore
    let markersHeld = ids.enumerated().allSatisfy { index, id in
        !remaining.contains(id)
            || window.panes[id]!.terminal.screen.dump().contains("NYMBRA_PANE_\(index)_OK")
    }

    print("split-test\tpanes=\(ids.count) placed=\(placedExactly ? 1 : 0) "
          + "quarterGrids=\(quarterSized && sameGrid ? 1 : 0) "
          + "independent=\(independent ? 1 : 0) jobControl=\(jobIsolated ? 1 : 0) "
          + "divider=\(dragReachedTheShells ? 1 : 0) closed=\(remaining.count) "
          + "sameShells=\(sameShells ? 1 : 0) spaceReturned=\(spaceReturned ? 1 : 0) "
          + "markersHeld=\(markersHeld ? 1 : 0)")

    // Left to the process exiting, but terminated explicitly so a failure below
    // does not leave four shells behind on a test runner.
    for pane in window.panes.values { pane.terminal.terminate() }
    return placedExactly && quarterSized && sameGrid && independent && jobIsolated
        && dragReachedTheShells && closedIndependently && sameShells && spaceReturned
        && markersHeld
}

private func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let filler = String(repeating: " ", count: max(0, width - text.count))
    return right ? filler + text : text + filler
}

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
    runSettingsTest(configuration: settings)
    exit(0)
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

/// Tabs, the way they are actually used: a strip that is there to be seen and
/// clicked, a `+` that makes a tab, and a shell in each that no other tab can
/// disturb.
///
/// Nothing here is visible from outside the process, which is the point. A tab
/// strip that draws nothing is indistinguishable from no tabs at all until ⌘T is
/// pressed; a "new tab" that merely swaps the view reads as the window reloading;
/// and a title that belongs to whichever tab printed last is wrong in a way that
/// no screenshot of the front tab will ever show. Three shells really run.
func runTabsTest(configuration: Configuration) -> Bool { // swiftlint:disable:this function_body_length
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // The dialogue that guards a running command is switched off: a modal question
    // in a headless process is a hang, not a failure.
    var quiet = configuration
    quiet.behaviour.confirmBeforeClosingRunningSession = false

    let window: TerminalWindow
    do {
        window = try TerminalWindow(configuration: quiet)
    } catch {
        print("tabs-test\tFAIL: no window: \(error)")
        return false
    }
    window.onSpawnFailure = { error in print("tabs-test\tspawn failed: \(error)") }

    // The screen is only ever touched on the main queue, so the run loop has to
    // turn for anything a shell produces to arrive.
    func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // 1. A strip that is there. The tabs live above the content, so the content
    //    area is smaller than the view holding it, and the tab in front is placed
    //    inside that area. That geometry is what makes a tab visible and clickable,
    //    and it is what `noTabsNoBorder` throws away.
    let strip = window.tabView
    let stripVisible = strip.tabPosition == .top
        && strip.bounds.height > strip.contentRect.height
        && window.container.frame == strip.contentRect

    // 2. The `+`: an item in the strip that is not a tab. It is counted as an item
    //    and not as a tab, and it is last, so the tabs read in the order they were
    //    opened and the thing that makes another one is at the end of them.
    let plusIsLast = strip.tabViewItems.last === window.plusItem
    let plusIsNotTab = window.tabCount == strip.tabViewItems.count - 1

    // 3. Making tabs. Each one is a fresh full-window shell, and the selection
    //    follows the one that was just made rather than staying where it was.
    let madeFirst = window.newTab()
    let madeSecond = window.newTab()
    let ids = strip.tabViewItems.compactMap { $0.identifier as? TabID }
    let created = madeFirst && madeSecond && ids.count == 3

    // Each tab has exactly one pane and its own shell, and no two are the same
    // process — which is the property a window with one shared shell could not
    // have.
    let shells = ids.map { window.panes(in: $0).values.first?.terminal }
    let ownShells = shells.allSatisfy { $0 != nil }
        && Set(shells.compactMap { $0?.pid }).count == ids.count
        && ids.allSatisfy { window.panes(in: $0).count == 1 }

    // Each tab is asked for a marker only it can produce, and each may show its
    // own and nobody else's. Evaluated, so the PTY's echo of the command cannot
    // satisfy the check — it contains `%s` where the marker has a digit.
    for (index, id) in ids.enumerated() {
        window.panes(in: id).values.first!.terminal.send("printf 'NYMBRA_TAB_%s\\n' \(index)_OK\n")
    }
    pump(1.0)
    func ownMarkerOnly() -> Bool {
        ids.enumerated().allSatisfy { index, id in
            let dump = window.panes(in: id).values.first!.terminal.screen.dump()
            guard dump.contains("NYMBRA_TAB_\(index)_OK") else { return false }
            return !ids.enumerated().contains { other, _ in
                other != index && dump.contains("NYMBRA_TAB_\(other)_OK")
            }
        }
    }
    let independent = ownMarkerOnly()

    // 4. Switching. The tab in front changes, and what is on screen changes with
    //    it: a switch that moved the focus and left the old view up is a switch
    //    that shows two terminals at once.
    let showingFirst = window.container
    window.selectTab(ids[1])
    let movedForward = window.focusedTab == ids[1] && window.container !== showingFirst
    window.selectTab(ids[2])
    window.selectTab(ids[1])
    let movedBack = window.focusedTab == ids[1] && window.container !== showingFirst

    // 5. The title belongs to the tab in front. Each tab names itself, and the
    //    window carries the name of whichever one is showing — so a title is a
    //    claim about what the person is looking at, and it is checked by switching.
    for (index, id) in ids.enumerated() {
        window.panes(in: id).values.first!.terminal.send("printf '\\033]0;NYMBRA_TITLE_\(index)\\007'\n")
    }
    pump(1.0)

    var titleFollows = true
    for index in ids.indices {
        window.selectTab(ids[index])
        pump(0.4)
        if window.window.title != "NYMBRA_TITLE_\(index)" { titleFollows = false }
    }

    // And a tab that is not in front must not move it: the title is the window's,
    // not whichever shell happened to print last.
    let front = ids[0]
    let background = ids[2]
    window.selectTab(front)
    pump(0.4)
    let titleInFront = window.window.title
    window.panes(in: background).values.first!.terminal.send("printf '\\033]0;NYMBRA_IN_THE_BACK\\007'\n")
    pump(0.6)
    let backgroundIsQuiet = window.window.title == titleInFront

    // 6. Closing one tab leaves the others exactly as they were: the same shells,
    //    still holding their own output. A tab closed must not have disturbed the
    //    sessions beside it.
    let survivors = ids.filter { $0 != ids[1] }
    let survivorPids = survivors.map { window.panes(in: $0).values.first!.terminal.pid }
    let outputBefore = window.panes(in: front).values.first!.terminal.screen.dump()

    window.selectTab(ids[1])
    window.closeFocusedTab()

    let remaining = Set(strip.tabViewItems.compactMap { $0.identifier as? TabID })
    let closedCleanly = remaining.count == 2 && remaining == Set(survivors)
    let sameShells = survivors.map { window.panes(in: $0).values.first!.terminal.pid } == survivorPids
    let stillAlive = survivorPids.allSatisfy { kill($0, 0) == 0 }
    let outputHeld = window.panes(in: front).values.first!.terminal.screen.dump() == outputBefore

    // The last tab closes the window, which is what a person expects of a strip
    // with one thing left in it.
    window.closeFocusedTab()
    window.closeFocusedTab()
    let windowClosed = window.isClosed

    print("tabs-test\tstrip=\(stripVisible ? 1 : 0) plus=\(plusIsLast && plusIsNotTab ? 1 : 0) "
        + "created=\(created ? 1 : 0) ownShells=\(ownShells ? 1 : 0) "
        + "independent=\(independent ? 1 : 0) switched=\(movedForward && movedBack ? 1 : 0) "
        + "title=\(titleFollows && backgroundIsQuiet ? 1 : 0) closed=\(remaining.count) "
        + "sameShells=\(sameShells && stillAlive && outputHeld ? 1 : 0) "
        + "lastTabClosesWindow=\(windowClosed ? 1 : 0)")

    // Left to the process exiting, but terminated explicitly so a failure does not
    // leave shells behind on a test runner.
    for tab in ids {
        for pane in window.panes(in: tab).values { pane.terminal.terminate() }
    }
    return stripVisible && plusIsLast && plusIsNotTab && created && ownShells && independent
        && movedForward && movedBack && titleFollows && backgroundIsQuiet
        && closedCleanly && sameShells && stillAlive && outputHeld && windowClosed
}

// Temporary: open a window with three named tabs and hold it open so a
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
