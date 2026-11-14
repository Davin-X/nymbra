import AppKit
import Foundation
import NymbraCore
import NymbraInput

// Headless proofs of windows, splits, tabs and the mouse.
//
// CI cannot look at a window, so correctness is demonstrated by driving the
// emulator with real bytes and printing what the screen model made of them.
// Dispatched from `main.swift` by command-line flag.

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

    // A floor under the window. Without one the window shrinks to nothing, the
    // shell is told it has one column, and every line it prints arrives wrapped
    // into a strip one character wide — not a small window, a broken one.
    //
    // The clamp itself is AppKit's, for the user's drag; `setContentSize` walks
    // straight past it, so asking the window to be small proves nothing. What can
    // be checked is that the floor it declares is a *usable grid*: the view is
    // shown exactly that size and asked what grid it would report. A number in a
    // window property is not a promise; a grid is.
    let declared = second.window.contentMinSize
    let view = second.focusedView!
    let saved = view.frame.size
    view.setFrameSize(declared)
    let floorGrid = view.grid
    view.setFrameSize(saved)
    let hasFloor = declared.width > 0 && declared.height > 0
        && floorGrid.rows >= 10 && floorGrid.cols >= 30

    print("window-test\tclosed=\(first.isClosed) reopened=\(second !== first) "
          + "shellAlive=\(alive) ranCommand=\(ran) minSize=\(flag(hasFloor)) "
          + "floor=\(Int(declared.width))x\(Int(declared.height)) grid=\(floorGrid.cols)x\(floorGrid.rows)")

    for pane in first.panes.values { pane.terminal.terminate() }
    for pane in second.panes.values { pane.terminal.terminate() }
    return ran && alive && hasFloor
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

    // 1. A strip that is there, and that gives the terminal the rest of the window.
    //    The strip takes the top edge, and the view the tabs share reaches the left,
    //    right and bottom edges — so a terminal fills the window rather than sitting
    //    in a frame drawn around it. Those are four edges and four assertions,
    //    because a strip that is drawn but overlapped by the content is a strip a
    //    person cannot click.
    let bar = window.tabBar
    let content = window.window.contentView?.bounds ?? .zero
    let host = window.paneHostFrame
    let stripVisible = bar.frame.height > 0
        && bar.frame.width == content.width
        && bar.frame.maxY == content.height
        && host.minX == 0 && host.width == content.width
        && host.minY == 0 && host.maxY == bar.frame.minY

    //    And the tabs are laid out from the left, in order, with the `+` after the
    //    last of them rather than floating in the middle of the strip: the stock
    //    strip centres its items, which is the whole reason this one is drawn by
    //    hand. Read off the frames, so what is asserted is where they are drawn.
    let oneChip = bar.chipFrames.count == 1 && bar.chipFrames[0].minX <= 12
        && bar.chipFrames[0].maxX < bar.plusFrame.minX
        && bar.plusFrame.maxX <= bar.bounds.width

    //    And it is the *only* strip. macOS window tabbing would draw a second one
    //    above it, for a tab group AppKit maintains, holding none of Nymbra's tabs
    //    — no `+`, no title, no unread dot, and panes belonging to a different
    //    window — which is why it is off for the application and why this window
    //    would refuse to join a group even if it were not. Also assert the tab group
    //    is actually nil (not just disallowed): a window that somehow joined a group
    //    would have a non-nil tabGroup even if tabbing is disallowed.
    let onlyStrip = !NSWindow.allowsAutomaticWindowTabbing
        && window.window.tabbingMode == .disallowed
        && window.window.tabGroup == nil

    // 2. The `+`: a control in the strip that is not a tab. It is not counted as a
    //    tab, and it is last, so the tabs read in the order they were opened and
    //    the thing that makes another one is at the end of them.
    let plusIsNotTab = window.tabCount == bar.tabs.count

    // 3. Making tabs. Each one is a fresh full-window shell, and the selection
    //    follows the one that was just made rather than staying where it was.
    let madeFirst = window.newTab()
    let madeSecond = window.newTab()
    let ids = bar.tabs.map(\.identifier)
    let created = madeFirst && madeSecond && ids.count == 3

    //    Moving one changes the order and nothing else: the tab in front is still
    //    the tab that was in front.
    window.reorderTab(ids[0], to: 2)
    let reorderedIDs = bar.tabs.map(\.identifier)
    let reorderWorked = reorderedIDs == [ids[1], ids[2], ids[0]]
        && window.focusedTab == ids[2]
    window.reorderTab(ids[0], to: 0)

    //    Three chips, in a row from the left, in order, with the `+` after the last
    //    of them — a strip that centred its tabs would put the first one wherever
    //    there was room, which is what the stock strip does.
    bar.layoutSubtreeIfNeeded()
    let chipsInOrder = bar.chipFrames.count == 3
        && zip(bar.chipFrames, bar.chipFrames.dropFirst()).allSatisfy { $0.maxX <= $1.minX }
        && (bar.chipFrames.last?.maxX ?? .infinity) <= bar.plusFrame.minX

    //    And the `+` is pressed rather than called, so the strip's own button is
    //    what makes the tab.
    let madeByPlus = { bar.pressPlus(); return window.tabCount == 4 }()
    if let extra = bar.tabs.last?.identifier, extra != ids.last { window.closeTab(extra) }
    let closedTheNewOne = window.tabCount == 3

    //    A strip with more tabs than room for them, built on its own so that
    //    proving it costs no shells: they shrink to a floor, stay in order and do
    //    not overlap each other — and the `+` stays inside the strip. A `+` pushed
    //    off the edge is a strip that cannot make a tab any more.
    let crowded = TabBarView()
    crowded.frame = NSRect(x: 0, y: 0, width: 420, height: 30)
    for index in 0..<40 {
        crowded.insert(TabBarView.Tab(identifier: TabID(900 + index),
                                      label: "tab \(index)",
                                      content: NSView()), at: index)
    }
    crowded.layoutSubtreeIfNeeded()
    let crowdedFrames = crowded.chipFrames
    let crowdedOK = crowdedFrames.count == 40
        && zip(crowdedFrames, crowdedFrames.dropFirst()).allSatisfy { $0.maxX <= $1.minX }
        && crowdedFrames.allSatisfy { $0.width >= TabBarView.chipMinimumWidth - 0.01 }
        && crowded.bounds.contains(crowded.plusFrame)

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

    // 6. The unread badge. A tab that printed while it was in the back is marked;
    //    the one in front is not, because output you are watching is not news;
    //    and looking at a marked tab clears it. The mark is read off the strip's
    //    own label, so what is asserted is the thing drawn rather than a flag
    //    beside it — a dot that is set but never painted would pass the wrong
    //    test.
    func stripLabel(_ id: TabID) -> String {
        bar.tab(id)?.label ?? ""
    }
    let backWasMarked = window.isUnread(background) && stripLabel(background).contains("•")
    let frontWasClean = !window.isUnread(front) && !stripLabel(front).contains("•")
    window.selectTab(background)
    let readingClearsIt = !window.isUnread(background) && !stripLabel(background).contains("•")
    window.selectTab(front)

    // 7. Closing one tab leaves the others exactly as they were: the same shells,
    //    still holding their own output. A tab closed must not have disturbed the
    //    sessions beside it.
    let survivors = ids.filter { $0 != ids[1] }
    let survivorPids = survivors.map { window.panes(in: $0).values.first!.terminal.pid }
    let outputBefore = window.panes(in: front).values.first!.terminal.screen.dump()

    //    Closed by the `×` on its own chip — the control a person actually uses,
    //    and one the stock strip does not have. It closes *that* tab: a close
    //    button that closed a different tab, or that moved the person into the tab
    //    it is closing, would pass every other assertion here.
    window.selectTab(front)
    bar.pressClose(of: ids[1])

    let remaining = Set(bar.tabs.map(\.identifier))
    let closedCleanly = remaining.count == 2 && remaining == Set(survivors)
    let closedByItsOwnButton = window.focusedTab == front
    let sameShells = survivors.map { window.panes(in: $0).values.first!.terminal.pid } == survivorPids
    let stillAlive = survivorPids.allSatisfy { kill($0, 0) == 0 }
    let outputHeld = window.panes(in: front).values.first!.terminal.screen.dump() == outputBefore

    // The last tab closes the window, which is what a person expects of a strip
    // with one thing left in it.
    window.closeFocusedTab()
    window.closeFocusedTab()
    let windowClosed = window.isClosed

    print("tabs-test\tstrip=\(stripVisible && oneChip ? 1 : 0) "
        + "plus=\(plusIsNotTab && chipsInOrder && madeByPlus && closedTheNewOne ? 1 : 0) "
        + "created=\(created ? 1 : 0) ownShells=\(ownShells ? 1 : 0) "
        + "independent=\(independent ? 1 : 0) switched=\(movedForward && movedBack ? 1 : 0) "
        + "title=\(titleFollows && backgroundIsQuiet ? 1 : 0) "
        + "unread=\(backWasMarked && frontWasClean && readingClearsIt ? 1 : 0) closed=\(remaining.count) "
        + "closeButton=\(closedByItsOwnButton ? 1 : 0) crowded=\(crowdedOK ? 1 : 0) "
        + "sameShells=\(sameShells && stillAlive && outputHeld ? 1 : 0) "
        + "lastTabClosesWindow=\(windowClosed ? 1 : 0) onlyStrip=\(onlyStrip ? 1 : 0) "
        + "reordered=\(reorderWorked ? 1 : 0)")

    // Left to the process exiting, but terminated explicitly so a failure does not
    // leave shells behind on a test runner.
    for tab in ids {
        for pane in window.panes(in: tab).values { pane.terminal.terminate() }
    }
    return stripVisible && oneChip && onlyStrip && plusIsNotTab && chipsInOrder && madeByPlus
        && closedTheNewOne && created && reorderWorked && ownShells && crowdedOK
        && independent && movedForward && movedBack && titleFollows && backgroundIsQuiet
        && closedCleanly && closedByItsOwnButton && sameShells && stillAlive && outputHeld
        && windowClosed
}

// Mouse reporting, asserted without a window: an NSEvent is AppKit, but the
// bytes it becomes are not, so the encoding is a pure function of the screen's
// mode and encoding and the event's parameters.
func runMouseTest() -> Bool {
    var failures = 0
    func expect(_ condition: Bool, _ what: String) {
        if !condition { failures += 1; print("mouse-test\tFAIL: \(what)") }
    }

    // Off reports nothing, whatever the event.
    expect(Screen.mouseReport(mode: .off, encoding: .sgr, button: 0, col: 0, row: 0) == nil,
           "an off terminal reports no mouse bytes")

    // Click mode, left press at (3, 4): SGR.
    let leftPress = Screen.mouseReport(mode: .click, encoding: .sgr, button: 0, col: 3, row: 4)
    expect(leftPress == [0x1B, 0x5B, 0x3C] + Array("0;36;37".utf8) + [0x4D],
           "a left press in SGR is ESC [ < 0 ; col+33 ; row+33 M")

    // Release uses the lowercase marker.
    let leftRelease = Screen.mouseReport(mode: .click, encoding: .sgr, button: 0, col: 3, row: 4, isRelease: true)
    expect(leftRelease == [0x1B, 0x5B, 0x3C] + Array("0;36;37".utf8) + [0x6D],
           "and a release is the same thing with a lowercase m")

    // X10 has no release and no motion: a release is nothing.
    expect(Screen.mouseReport(mode: .click, encoding: .x10, button: 0, col: 3, row: 4, isRelease: true) == nil,
           "X10 has no release report")

    // Modifiers are OR'd into the button byte: shift 0x08, option 0x10, control 0x20.
    let modified = Screen.mouseReport(mode: .click, encoding: .sgr, button: 0, col: 0, row: 0,
                                     shift: true, option: true, control: true)
    expect(modified == [0x1B, 0x5B, 0x3C] + Array("56;33;33".utf8) + [0x4D],
           "shift, option and control are OR'd into the button byte")

    // Motion in click mode is suppressed.
    expect(Screen.mouseReport(mode: .click, encoding: .sgr, button: 0, col: 0, row: 0, isMotion: true) == nil,
           "click mode reports no motion")

    // Motion in motion mode, no button: the motion bit (0x40) is set.
    let motion = Screen.mouseReport(mode: .motion, encoding: .sgr, button: 3, col: 1, row: 2, isMotion: true)
    expect(motion == [0x1B, 0x5B, 0x3C] + Array("67;34;35".utf8) + [0x4D],
           "a bare move in any-event mode carries the motion bit and an uppercase M")

    // Wheel: buttons 4 and 5, always a press.
    let wheel = Screen.mouseReport(mode: .click, encoding: .sgr, button: 0, col: 0, row: 0,
                                  isScrollWheel: true, scrollDeltaY: -1)
    expect(wheel == [0x1B, 0x5B, 0x3C] + Array("4;33;33".utf8) + [0x4D],
           "a wheel up is button 4")

    // X10 press encoding.
    let x10 = Screen.mouseReport(mode: .click, encoding: .x10, button: 0, col: 1, row: 2)
    expect(x10 == [0x1B, 0x5B, 0x4D, 0x20, 0x22, 0x23],
           "X10 is ESC [ M followed by three bytes offset by 32")

    print("mouse-test\t" + (failures == 0 ? "ok" : "FAIL"))
    return failures == 0
}
