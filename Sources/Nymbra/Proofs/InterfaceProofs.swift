import AppKit
import Foundation
import NymbraCore
import NymbraInput

// Headless proofs of the settings window, the command palette and find.
//
// CI cannot look at a window, so correctness is demonstrated by driving the
// emulator with real bytes and printing what the screen model made of them.
// Dispatched from `main.swift` by command-line flag.

/// The settings window is the largest piece of UI in the project and the one a
/// test runner can least easily look at, so it prints itself too: build it, list
/// what each control loaded, and then assert the two things about it that are
/// easy to get wrong and impossible to see.
///
/// The first is the shortcut recorder's rules, which are claims: a key with no
/// modifier is not a shortcut, and a combination another command answers to is
/// refused with the name of that command.
///
/// The second is the recorder's *lifetime*. It installs a local event monitor —
/// which sees every key the application gets — and a monitor that outlives its
/// window swallows Escape for the whole application, in the terminal included.
func runSettingsTest(configuration: Configuration) -> Bool {
    let controller = SettingsWindowController(configuration: configuration) { _ in }
    print("pages\t" + controller.pageTitles.joined(separator: ","))
    print("appearance\t" + controller.appearanceSummary)
    print("presets\t" + controller.presetTitles.joined(separator: ","))
    for binding in controller.shortcutBindings {
        print("shortcut\t\(binding.command)\t\(binding.shortcut)")
    }

    // The gallery draws its own cards, so this also says the cards exist and are
    // holding the presets the window claims to offer.
    let galleryFilled = controller.presetTitles.count == Configuration.Colours.Preset.allCases.count
    let shortcutsListed = controller.shortcutBindings.count == Command.bindings().count

    controller.beginRecording(.newTab)
    let recording = controller.isRecordingShortcut

    // A letter with no modifier is a letter, not a shortcut.
    let plainKey = controller.captureShortcut(keyEvent(0, "a"))
    let unmodifiedRefused = plainKey == nil && controller.isRecordingShortcut
        && !controller.shortcutWarningText.isEmpty

    // Command-N is New Window's, and the warning has to say whose it is.
    let takenKey = controller.captureShortcut(keyEvent(45, "n", modifiers: .command))
    let conflictRefused = takenKey == nil && controller.shortcutWarningText.contains("already used by")

    // Control-Command-Backslash belongs to nobody, so it is recorded.
    let freeKey = controller.captureShortcut(keyEvent(42, "\\", modifiers: [.control, .command]))
    let accepted = freeKey == nil && !controller.isRecordingShortcut
        && controller.shortcutBindings.contains {
            $0.command == Command.newTab.rawValue && $0.shortcut.contains("⌃")
        }

    // And closing the window takes the monitor with it.
    controller.beginRecording(.splitRight)
    let recordingAgain = controller.isRecordingShortcut
    controller.window?.close()
    let released = !controller.isRecordingShortcut

    // The prompt-style gallery is a control, and a control has to change
    // something. Picking a style redraws the live preview's prompt line, so this
    // walks every style, presses its card, and compares what the *preview is
    // drawing* against the same model the card is built from — the copy on the
    // card and the prompt in the preview cannot come from two different places.
    let promptStyles = controller.promptStyleTitles
    let promptGalleryComplete = promptStyles == PromptStyle.allCases.map(\.rawValue)
        && Set(promptStyles).count == promptStyles.count
    let palette = Palette(preset: configuration.colours.preset,
                          overrides: configuration.colours.overrides)
    var promptDrawn: [String: String] = [:]
    var promptRecorded = true
    for style in PromptStyle.allCases {
        promptRecorded = controller.choosePromptStyle(style.rawValue) == style.rawValue && promptRecorded
        promptDrawn[style.rawValue] = controller.previewPromptText.joined(separator: "\n")
    }
    // Choosing a card is also asking for it. A recorded style that no shell will
    // wear is the bug this test exists to keep fixed.
    let promptAppliedAfterChoice = controller.isPromptStyleApplied
    // Every style has to look unlike every other one, or the gallery is a row of
    // buttons that all do the same nothing.
    let promptDistinct = Set(promptDrawn.values).count == PromptStyle.allCases.count
    // ...and the preview has to be drawing the style that was picked.
    let promptPreviewed = PromptStyle.allCases.allSatisfy { style in
        promptDrawn[style.rawValue] == PreviewView.promptLines(style, palette: palette)
            .map { $0.map(\.text).joined() }
            .joined(separator: "\n")
    }
    // A few shapes worth naming, because "it changed" and "it changed into the
    // right thing" are different claims.
    let promptShapes = promptDrawn[PromptStyle.git.rawValue]?.contains("git:(main)") == true
        && promptDrawn[PromptStyle.pure.rawValue]?.hasSuffix("❯") == true
        && promptDrawn[PromptStyle.robbyrussell.rawValue]?.hasSuffix("➜") == true
        && promptDrawn[PromptStyle.starship.rawValue]?.contains("▸ ") == true
        && promptDrawn[PromptStyle.spaceship.rawValue]?.hasPrefix("in ") == true
        && promptDrawn[PromptStyle.agnoster.rawValue]?.contains(" ›") == true
        && promptDrawn[PromptStyle.kali.rawValue]?.contains("\n") == true
        && promptDrawn[PromptStyle.powerlevel10k.rawValue]?.contains("\n") == false

    let ok = galleryFilled && shortcutsListed && recording && unmodifiedRefused
        && conflictRefused && accepted && recordingAgain && released
        && promptGalleryComplete && promptRecorded && promptDistinct && promptPreviewed && promptShapes
        && promptAppliedAfterChoice
    print("settings-test\tgallery=\(controller.presetTitles.count) shortcuts=\(controller.shortcutBindings.count) "
          + "recording=\(flag(recording && recordingAgain)) unmodified=\(flag(unmodifiedRefused)) "
          + "conflict=\(flag(conflictRefused)) accepted=\(flag(accepted)) "
          + "promptStyles=\(promptStyles.count) promptRecorded=\(flag(promptRecorded)) "
          + "promptDistinct=\(flag(promptDistinct)) promptPreviewed=\(flag(promptPreviewed)) "
          + "promptShapes=\(flag(promptShapes)) promptApplied=\(flag(promptAppliedAfterChoice)) "
          + "released=\(flag(released)) ok=\(flag(ok))")
    return ok
}

/// The command palette, driven with real key events rather than method calls.
///
/// The keys *are* the test. A text field's own `keyDown` is never called while the
/// field is being edited — the first responder is the field's editor, an
/// `NSTextView` — so a palette that reads arrows there is a palette whose arrows
/// do nothing at all. Every key below is sent the way the application sends one.
func runPaletteTest(configuration: Configuration) -> Bool {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let commands = Command.allCases.filter { $0 != .commandPalette }
    var chosen: Command?
    let palette = CommandPaletteController(commands: commands, configuration: configuration) { chosen = $0 }
    palette.show(over: nil)

    func press(_ keyCode: UInt16, _ characters: String) {
        NSApp.sendEvent(keyEvent(keyCode, characters, windowNumber: palette.window?.windowNumber ?? 0))
    }

    // The whole list, every row carrying the shortcut it answers to today.
    let opensOnScreen = palette.isShowing
    let listedAll = palette.visibleRows.count == commands.count
    let showsShortcuts = palette.visibleRows.contains { $0.contains("⌘") }

    // Return runs the highlighted row without any typing at all.
    press(36, "\r")
    let returnRanFirst = chosen == commands.first
    let closedAfterRunning = !palette.isShowing

    // Typing filters: the field editor inserts what was typed and the shortlist
    // follows, starting at its own first row.
    palette.show(over: nil)
    press(17, "tab")
    let typingArrived = palette.query == "tab"
    let filtered = !palette.visibleRows.isEmpty
        && palette.visibleRows.count < commands.count
        && palette.visibleRows.allSatisfy { $0.localizedCaseInsensitiveContains("tab") }
    let firstMatch = commands.first {
        $0.title.localizedCaseInsensitiveContains("tab")
            || $0.explanation.localizedCaseInsensitiveContains("tab")
    }
    let highlightAtTop = palette.selectedCommand == firstMatch

    // ↓ and ↑ move the highlight, and ↑ comes back to where it started.
    press(125, "\u{F701}")
    let afterDown = palette.selectedCommand
    press(126, "\u{F700}")
    let arrowsMove = afterDown != nil && afterDown != firstMatch
        && palette.selectedCommand == firstMatch

    // Return runs what is highlighted now — a different row from the first one,
    // which is what makes this more than the earlier assertion repeated.
    chosen = nil
    press(36, "\r")
    let returnRanHighlighted = chosen == firstMatch

    // Escape closes without running anything.
    palette.show(over: nil)
    chosen = nil
    press(53, "\u{1B}")
    let escaped = !palette.isShowing && chosen == nil

    let ok = opensOnScreen && listedAll && showsShortcuts && returnRanFirst && closedAfterRunning
        && typingArrived && filtered && highlightAtTop && arrowsMove && returnRanHighlighted && escaped
    print("palette-test\topens=\(flag(opensOnScreen)) listed=\(flag(listedAll)) "
          + "shortcuts=\(flag(showsShortcuts)) typed=\(flag(typingArrived)) filtered=\(flag(filtered)) "
          + "top=\(flag(highlightAtTop)) arrows=\(flag(arrowsMove)) "
          + "return=\(flag(returnRanFirst && returnRanHighlighted)) escape=\(flag(escaped))")
    return ok
}

/// Find, asserted against a live shell: the bar's state, its keys, and the
/// highlight, which is judged by pixels.
///
/// The pixels are the point. A highlight drawn where the terminal's rows then
/// paint over it is a highlight nobody can see, and no amount of *state* would
/// ever show that: the query, the count and the current match would all be right
/// while the screen stayed blank. So the view is rendered twice — find off, find
/// on — and the difference has to be large enough to be the matched cells, not
/// just the cursor. The cursor is taken out of the argument entirely by turning
/// blinking off for this test.
func runFindTest(configuration: Configuration) -> Bool { // swiftlint:disable:this function_body_length
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // A blinking cursor differs between two renders for reasons that have nothing
    // to do with find, and a modal question in a headless process is a hang.
    var quiet = configuration
    quiet.behaviour.cursorBlinks = false
    quiet.behaviour.confirmBeforeClosingRunningSession = false

    let controller = AppController(configuration: quiet)
    guard let window = controller.makeWindow() else {
        print("find-test\tFAIL: no window could be made")
        return false
    }
    window.window.makeKeyAndOrderFront(nil)

    // Printed by an expansion, so the echoed command line does not contain what is
    // searched for: the only two matches are the two on the output line.
    let shell = window.panes[window.focusedPane]!.terminal
    shell.send("echo NYMBRA_FIND$((6*7)) NYMBRA_FIND$((6*8))\n")
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if shell.screen.dump().contains("NYMBRA_FIND48") { break }
    }
    let printed = shell.screen.dump().contains("NYMBRA_FIND48")

    func press(_ keyCode: UInt16, _ characters: String) {
        NSApp.sendEvent(keyEvent(keyCode, characters, windowNumber: window.window.windowNumber))
    }

    // Type into the bar the way a person does, and read back what it says.
    window.beginFind()
    let barOpened = window.findBarIsVisible
    press(20, "NYMBRA_FIND4")
    let typed = window.findQuery == "NYMBRA_FIND4"
    let counted = window.findStatusText == "1 of 2"
    window.findNext()
    let nextWalked = window.findStatusText == "2 of 2"
    window.findPrevious()
    let previousWalked = window.findStatusText == "1 of 2"

    // Escape, while the query is live and the field is being edited, takes the
    // query and the bar with it.
    press(53, "\u{1B}")
    let escaped = !window.findBarIsVisible && window.findQuery.isEmpty
        && window.focusedView?.findStatus == "0 matches"

    // Find opens again on the same query, and stays open for the rest.
    window.beginFind()
    press(20, "NYMBRA_FIND4")
    let reopened = window.findBarIsVisible && window.findStatusText == "1 of 2"

    // The three switches. Each is pressed through its own action, so a switch that
    // is not wired is a switch that never moves — which is why the read-back of the
    // buttons is part of the assertion rather than a convenience.
    // The bar is a stack of eight controls squeezed into a fixed width, and Auto
    // Layout clips an over-full row rather than complaining: something would simply
    // be missing. So the switches and the count have to be *inside* the bar, which
    // is a thing a proof can check and a person would only notice by looking.
    window.window.contentView?.layoutSubtreeIfNeeded()
    let bar = window.findBarBounds
    let controls = window.findControlFrames
    let controlsInside = controls.count == 8
        && controls.allSatisfy { bar.contains($0) && $0.width > 10 && $0.height > 10 }

    window.search("nymbra_find4")
    let insensitive = window.findStatusText == "1 of 2"

    // Match case: the same query, and the same click, now finds nothing — which is
    // also what says the click re-ran the search without the query being retyped.
    window.clickFindToggle(.matchCase)
    let caseSensitive = window.findOptionSummary == "case=1 word=0 regex=0"
        && window.findStatusText == "No matches"
    window.search("NYMBRA_FIND4")
    let caseTyped = window.findStatusText == "1 of 2"

    // Whole word: `NYMBRA_FIND4` runs into the digits that follow it, so it is not a
    // word; `NYMBRA_FIND42` is.
    window.clickFindToggle(.wholeWord)
    let wordRejects = window.findStatusText == "No matches"
    window.search("NYMBRA_FIND42")
    let wordAccepts = window.findStatusText == "1 of 1"

    // Regex: what the literal query could not say.
    window.clickFindToggle(.regex)
    window.search("NYMBRA_FIND[0-9]+")
    let regexFinds = window.findOptionSummary == "case=1 word=1 regex=1"
        && window.findStatusText == "1 of 2"

    // A pattern that does not compile says so, and highlights nothing: an empty
    // screen and a broken query are different things to be told.
    window.search("NYMBRA_FIND[")
    let invalidReported = window.findStatusText == "Invalid regex"
        && window.focusedView?.findHasMatches == false

    // Back to the loose default, and the bar finds again.
    window.clickFindToggle(.matchCase)
    window.clickFindToggle(.wholeWord)
    window.clickFindToggle(.regex)
    window.search("NYMBRA_FIND4")
    let backToDefault = window.findOptionSummary == "case=0 word=0 regex=0"
        && window.findStatusText == "1 of 2"

    // The query belongs to the pane in front, so a new tab starts its own search
    // rather than keeping the highlight of a tab nobody is looking at.
    let firstTab = window.focusedTab
    let madeTab = window.newTab()
    let secondTab = window.focusedTab
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let followedTab = madeTab && secondTab != firstTab && window.findStatusText == "No matches"

    // Back to the first tab, where the query and its highlight follow the focus.
    window.selectTab(firstTab)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let followedBack = window.findStatusText == "1 of 2"

    guard let view = window.focusedView else {
        print("find-test\tFAIL: no focused view")
        return false
    }

    // The highlight, judged by what is drawn: off, on, off again. This is the pane
    // with the matches in it — rendering the new empty tab would prove only that
    // an empty screen matches an empty screen.
    view.endFind()
    let plain = pixels(of: view)
    view.startFind(query: "NYMBRA_FIND4")
    let marked = pixels(of: view)
    view.endFind()
    let cleared = pixels(of: view)
    let highlighted = differingBytes(plain, marked)
    let leftBehind = differingBytes(plain, cleared)

    // The match the keys are on has to look like the match the keys are on: the
    // bar says `1 of 2` and the screen has to say *which*. So the same query is
    // rendered with the first match current and with the second current, and the
    // two have to differ — which they can only do if the current one is drawn
    // differently from the rest. The matches are on the same row, so nothing but
    // the highlight moves.
    view.startFind(query: "NYMBRA_FIND4")
    let onFirst = pixels(of: view)
    view.findNext()
    let onSecond = pixels(of: view)
    view.endFind()
    let currentIsMarked = differingBytes(onFirst, onSecond) >= 200

    // A match far up in history: find has to bring it on screen. The marker is
    // printed by an expansion, then pushed a few hundred lines into scrollback.
    func waitFor(_ text: String) -> Bool {
        let until = Date().addingTimeInterval(5)
        while Date() < until {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if shell.screen.dump().contains(text) { return true }
        }
        return false
    }
    func markerOnScreen() -> Bool {
        shell.screen.displayRows(scrollOffset: view.currentScrollOffset)
            .contains { Screen.text(ofLine: $0).contains("NYMBRA_HIST2") }
    }
    // Each wait is for a word made by an expansion, so the echoed command line
    // (which contains `seq 1001 1300` but not `NYMBRA_DONE5`) cannot satisfy it
    // before the output has actually arrived.
    shell.send("echo NYMBRA_HIST$((1+1)); seq 1001 1300; echo NYMBRA_DONE$((2+3))\n")
    let flooded = waitFor("NYMBRA_DONE5")
    let scrollerHiddenLive = !view.scrollerIsVisible
    view.startFind(query: "NYMBRA_HIST2")
    let historyFound = view.currentScrollOffset > 0 && markerOnScreen()
    let scrollerShown = view.scrollerIsVisible

    // More output while the person is reading: the line they are reading stays.
    shell.send("seq 2001 2100; echo NYMBRA_MORE$((3+4))\n")
    let morePrinted = waitFor("NYMBRA_MORE7")
    let stayedPut = morePrinted && view.currentScrollOffset > 0 && markerOnScreen()
    view.endFind()

    // The extra tab's shell is a real process, so it is closed here rather than
    // left to the end of the process.
    window.selectTab(secondTab)
    window.closeFocusedTab()
    window.selectTab(firstTab)

    let behaviour = printed && barOpened && typed && counted && nextWalked && previousWalked
        && escaped && reopened
    let options = insensitive && caseSensitive && caseTyped && wordRejects && wordAccepts
        && regexFinds && invalidReported && backToDefault
    let following = followedTab && followedBack
    let history = flooded && scrollerHiddenLive && historyFound && scrollerShown && stayedPut
    let ok = behaviour && options && following && controlsInside
        && highlighted >= 1000 && leftBehind == 0 && currentIsMarked && history
    let state = "printed=\(flag(printed)) bar=\(flag(barOpened)) typed=\(flag(typed)) "
        + "count=\(flag(counted)) next=\(flag(nextWalked)) previous=\(flag(previousWalked)) "
        + "escape=\(flag(escaped)) reopened=\(flag(reopened))"
    let optionFlags = "insensitive=\(flag(insensitive)) case=\(flag(caseSensitive && caseTyped)) "
        + "word=\(flag(wordRejects && wordAccepts)) regex=\(flag(regexFinds)) "
        + "invalid=\(flag(invalidReported)) reset=\(flag(backToDefault))"
    let drawn = "controls=\(flag(controlsInside)) follow=\(flag(following)) "
        + "highlight=\(highlighted) leftBehind=\(leftBehind) current=\(flag(currentIsMarked)) "
        + "history=\(flag(historyFound)) scroller=\(flag(scrollerHiddenLive && scrollerShown)) "
        + "pinned=\(flag(stayedPut))"
    print("find-test\t" + state + " " + optionFlags + " " + drawn)
    return ok
}

/// Typing that is not one key, one letter: an input method composing text,
/// and a program drawing a frame all at once.
///
/// The input method itself is the system's, and a headless process cannot
/// drive Kotoeri. What is proved is the terminal's side of the contract: text
/// being composed is drawn and never sent; committed text is sent once, as
/// UTF-8; real key events still reach the program with their exact bytes; and
/// the candidate window would open at the cursor rather than in a corner.
func runInputTest(configuration: Configuration) -> Bool { // swiftlint:disable:this function_body_length
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    var quiet = configuration
    quiet.behaviour.cursorBlinks = false
    quiet.behaviour.confirmBeforeClosingRunningSession = false
    let controller = AppController(configuration: quiet)
    guard let window = controller.makeWindow(), let view = window.focusedView else {
        print("input-test\tFAIL: no window")
        return false
    }
    window.window.makeKeyAndOrderFront(nil)
    window.window.makeFirstResponder(view)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    // Capture what would be sent, instead of sending it to the shell.
    let original = view.onInput
    var sent: [UInt8] = []
    view.onInput = { sent += $0 }
    defer { view.onInput = original }

    // Composing: drawn, not sent.
    let before = pixels(of: view)
    view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0),
                       replacementRange: NSRange(location: NSNotFound, length: 0))
    let composing = view.hasMarkedText() && view.markedRange().length == 2 && sent.isEmpty
    let drawn = differingBytes(before, pixels(of: view)) > 200

    // The candidate window opens at the cursor, on this window's screen.
    let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
    let atCursor = rect.width > 0 && rect.height > 0 && window.window.frame.contains(rect.origin)

    // Committing: sent once, as UTF-8, and the composition is gone.
    view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
    let committed = sent == Array("日本".utf8) && !view.hasMarkedText()
    let cleared = differingBytes(before, pixels(of: view)) == 0

    // Real key events: a letter makes the round trip through the input method
    // and comes back as itself; ⌃C and an arrow go straight to the key table.
    sent.removeAll()
    view.keyDown(with: keyEvent(0, "a", windowNumber: window.window.windowNumber))
    let letter = sent == [0x61]
    sent.removeAll()
    view.keyDown(with: keyEvent(8, "\u{03}", modifiers: .control, windowNumber: window.window.windowNumber))
    let control = sent == [0x03]
    sent.removeAll()
    view.keyDown(with: keyEvent(126, "\u{F700}", windowNumber: window.window.windowNumber))
    let arrow = sent == Array("\u{1B}[A".utf8)
    sent.removeAll()
    view.keyDown(with: keyEvent(36, "\r", windowNumber: window.window.windowNumber))
    let enter = sent == [0x0D]

    // A frame (DEC 2026): held while open, drawn when closed.
    let shell = window.panes[window.focusedPane]!.terminal
    shell.parser.feed("\u{1B}[?2026hframe")
    view.screenDidUpdate()
    let held = view.isHoldingFrame
    shell.parser.feed("\u{1B}[?2026l")
    view.screenDidUpdate()
    let released = !view.isHoldingFrame

    let ok = composing && drawn && atCursor && committed && cleared && letter && control
        && arrow && enter && held && released
    print("input-test\tcomposing=\(flag(composing)) drawn=\(flag(drawn)) atCursor=\(flag(atCursor)) "
          + "committed=\(flag(committed)) cleared=\(flag(cleared)) letter=\(flag(letter)) "
          + "control=\(flag(control)) arrow=\(flag(arrow)) enter=\(flag(enter)) "
          + "held=\(flag(held)) released=\(flag(released))")
    return ok
}
