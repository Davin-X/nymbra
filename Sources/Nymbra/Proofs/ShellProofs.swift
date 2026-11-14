import AppKit
import Foundation
import NymbraCore
import NymbraInput

// Headless proofs of shell integration and finished-command notifications, against a real zsh.
//
// CI cannot look at a window, so correctness is demonstrated by driving the
// emulator with real bytes and printing what the screen model made of them.
// Dispatched from `main.swift` by command-line flag.

/// Shell integration, asserted against a real zsh.
///
/// This is deliberately not a test against a pile of expected bytes. zsh is what
/// decides when its own hooks run, so the only honest questions are whether a
/// real zsh, started the way Nymbra starts one, reports what it is doing — and
/// whether the user's own startup file still ran, because that is the way this
/// feature can ruin somebody's shell rather than merely fail to help.
///
/// The stand-in for the user's config is a temporary directory, so the real one
/// is not involved and nothing here depends on how this machine is set up.
func runShellIntegrationTest() -> Bool {
    guard access("/bin/zsh", X_OK) == 0 else {
        // Said out loud rather than passed silently: "there was no zsh to test"
        // and "the integration works" must not look the same in a log.
        print("shell-integration-test\tskipped=true reason=no-zsh")
        return true
    }

    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nymbra-integration-\(getpid())")
    let userZDOTDIR = root.appendingPathComponent("user")
    let generated = root.appendingPathComponent("generated")
    defer { try? fileManager.removeItem(at: root) }

    do {
        try fileManager.createDirectory(at: userZDOTDIR, withIntermediateDirectories: true)
        // Standing in for the user's own config. If the generated files ever
        // stop loading it, this variable stops arriving — which is exactly the
        // regression this test exists to catch.
        //
        // Only a `.zshrc`, deliberately: the user therefore has no `.zshenv`,
        // `.zprofile` or `.zlogin`, so the generated stand-ins for those are all
        // exercised down the "the user has no such file" path on the way.
        try "export NYMBRA_TEST_RC=loaded\nPS1='nymbra-test%# '\n".write(
            to: userZDOTDIR.appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8)

        // Asked for the way the app asks for it, rather than assembled here, so
        // that the setting and the writing of the files are covered too and not
        // merely the parser on the other end of them.
        var configuration = Configuration()
        configuration.behaviour.shellIntegration = true
        // And a prompt the shell is meant to wear, so this test covers the
        // application of a chosen style and not only the marks. `pure` ends on a
        // glyph the user's own `.zshrc` above never prints, so seeing it on screen
        // can only mean Nymbra's prompt replaced theirs.
        configuration.appearance.promptStyle = PromptStyle.pure.rawValue
        configuration.appearance.promptStyleApplied = true
        guard let integration = configuration.shellIntegration(
            in: generated, userZDOTDIR: userZDOTDIR.path
        ) else {
            print("shell-integration-test\tthe setting was on and the integration was not written")
            return false
        }
        let promptInEnvironment = integration.environment["NYMBRA_PROMPT"]?.contains("❯") == true
        let promptInSnippet = ((try? String(contentsOf: generated.appendingPathComponent("shell/nymbra.zsh"),
                                            encoding: .utf8)) ?? "")
            .contains("PROMPT=$NYMBRA_PROMPT")

        let queue = DispatchQueue(label: "dev.nymbra.shell-integration-test")
        let terminal = try Terminal(size: GridSize(rows: 24, cols: 80),
                                    shell: "/bin/zsh",
                                    deliveryQueue: queue,
                                    integration: integration)

        let log = MarkLog()
        let promptUp = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let failed = DispatchSemaphore(value: 0)
        terminal.onShellMark = { mark in
            log.append(mark)
            switch mark {
            case .promptStart: promptUp.signal()
            case let .commandFinished(status):
                // A status of 0 for everything would pass a test that only ever
                // asked for "a finished command", which is precisely the bug
                // worth catching: a terminal that reports success regardless.
                if status == 0 { finished.signal() } else if status == 7 { failed.signal() }
            case .commandStart, .commandExecuted: break
            }
        }
        terminal.start()

        guard promptUp.wait(timeout: .now() + 20) == .success else {
            reportShellIntegration(terminal, queue: queue, log: log,
                                   reason: "zsh printed no prompt in 20s")
            terminal.terminate()
            waitpid(terminal.pid, nil, 0)
            return false
        }

        // The line as it will be typed, written once and used for both halves of
        // what follows — what it prints, and what the marked command has to say it
        // was — so that a typo cannot make the test agree with itself about a
        // command nobody sent.
        let commandLine = "__nymbra_encode $'a\\ab\\ec\\nd\\re\\tf\\x7fg%d;h'; "
            + "printf 'nymbra-ran=%s encoded=%s\\n' \"$NYMBRA_TEST_RC\" \"$__nymbra_encoded\""

        // `printf` with the value expanded, rather than `echo "$VAR"`: the pty
        // echoes what is typed back at us, so a marker that also appeared in the
        // command line would be satisfied by the echo alone.
        //
        // One line, doing the work of two, because it is typed once and asserted
        // twice. What it prints proves the encoder in the shell: the BEL, ESC, tab,
        // newline, carriage return, delete, percent and semicolon in that first
        // argument come back as `%07`, `%1B`, `%09`, `%0A`, `%0D`, `%7F`, `%25` and
        // `%3B`. And what it is, as typed, is what has to come back through the `C`
        // mark: a line with quotes, a `$`, a percent sign, a semicolon and a
        // backslash in it, none of which the terminal could have read off the screen
        // it was echoed to.
        terminal.send(commandLine + "\n")
        guard finished.wait(timeout: .now() + 20) == .success else {
            reportShellIntegration(terminal, queue: queue, log: log,
                                   reason: "zsh reported no finished command")
            terminal.terminate()
            waitpid(terminal.pid, nil, 0)
            return false
        }

        // A command that fails, so the status is shown to be the command's and
        // not a constant. `(exit 7)` rather than `false`, because 7 is a number
        // nothing else in this test produces.
        terminal.send("(exit 7)\n")
        guard failed.wait(timeout: .now() + 20) == .success else {
            reportShellIntegration(terminal, queue: queue, log: log,
                                   reason: "zsh did not report a failing command as 7")
            terminal.terminate()
            waitpid(terminal.pid, nil, 0)
            return false
        }

        // Read the screen back on the queue that parses it, so this cannot race
        // the reader: the mark that said "finished" came through that same queue,
        // and everything the command printed came before it.
        let text = queue.sync {
            (0..<terminal.screen.rows).map { terminal.screen.rowText($0) }.joined(separator: "\n")
        }

        terminal.terminate()
        waitpid(terminal.pid, nil, 0)

        let marks = log.all
        let prompted = marks.contains(.promptStart)
        let executed = marks.contains { if case .commandExecuted = $0 { return true } else { return false } }
        let status = marks.contains(.commandFinished(0))
        let failure = marks.contains(.commandFinished(7))
        let userConfig = text.contains("nymbra-ran=loaded")
        // The prompt the person picked, on the screen rather than only in the
        // environment it was handed over in: `pure` ends on `❯`.
        let promptApplied = promptInEnvironment && promptInSnippet && text.contains("❯")
        // The encoder's half, read off the screen: every byte it exists for comes
        // back escaped, and everything else is left exactly as it was.
        let encoding = text.contains("encoded=a%07b%1Bc%0Ad%0De%09f%7Fg%25d%3Bh")
        // And the decoder's half: the command as typed, recovered from the mark
        // rather than from anything the shell printed.
        let recorded = marks.compactMap { mark -> String? in
            if case let .commandExecuted(command) = mark { return command } else { return nil }
        }
        // Every `C` here comes from a shell that was taught to report, so none may
        // arrive without its command: a payload dropped on the way through would
        // leave "a command ran" looking correct, which is exactly what `executed`
        // above only appears to check.
        let everyMarkCarriedOne = !recorded.isEmpty && !marks.contains { mark in
            if case .commandExecuted(nil) = mark { return true } else { return false }
        }
        let command = recorded.contains(commandLine) && everyMarkCarriedOne

        print("shell-integration-test\tmarks=\(marks.count)"
              + " prompt=\(prompted ? 1 : 0)"
              + " executed=\(executed ? 1 : 0)"
              + " finished=\(status ? 1 : 0)"
              + " failed=\(failure ? 1 : 0)"
              + " userConfig=\(userConfig ? 1 : 0)"
              + " command=\(command ? 1 : 0)"
              + " encoding=\(encoding ? 1 : 0)"
              + " promptApplied=\(promptApplied ? 1 : 0)")
        return prompted && executed && status && failure && userConfig && command && encoding
            && promptApplied
    } catch {
        FileHandle.standardError.write(Data("nymbra: shell-integration-test \(error)\n".utf8))
        return false
    }
}

/// A notification when a command that took a while finishes, asserted against a
/// real zsh.
///
/// The *rule* — how long is long, and whether anybody was watching — is tested in
/// the harness, where it can be argued with. What only a live shell can show is
/// the wiring: that a shell taught to report itself yields a duration at all, that
/// the number governing it is the configured threshold rather than one written
/// down somewhere, and that the tab announced is the one nobody was looking at.
///
/// The notification is swapped for a capture. Posting cannot be tested from here:
/// this is a bare executable, and `UNUserNotificationCenter.current()` aborts
/// outside an application bundle rather than failing — which is why
/// `TerminalWindow.deliver` is a seam in the first place.
func runNotifyTest() -> Bool { // swiftlint:disable:this function_body_length
    guard access("/bin/zsh", X_OK) == 0 else {
        print("notify-test\tskipped=true reason=no-zsh")
        return true
    }

    // A duration needs the shell's marks, so the integration has to be on, so
    // files get written. Pointed at a temporary directory so this test cannot
    // overwrite the real ones, and put back afterwards because the environment
    // outlives the test.
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nymbra-notify-\(getpid())")
    defer { try? fileManager.removeItem(at: root) }

    let previous = ProcessInfo.processInfo.environment["NYMBRA_CONFIG"]
    setenv("NYMBRA_CONFIG", root.appendingPathComponent("config.json").path, 1)
    defer {
        // An empty value is not an absence: only `unsetenv` restores "there was
        // no such variable".
        if let previous {
            setenv("NYMBRA_CONFIG", previous, 1)
        } else {
            unsetenv("NYMBRA_CONFIG")
        }
    }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    var configuration = Configuration()
    configuration.behaviour.shellIntegration = true
    configuration.behaviour.confirmBeforeClosingRunningSession = false
    // Half a second, so the test does not spend a real ten waiting to find out
    // that the threshold is honoured.
    configuration.behaviour.notifyAfterSeconds = 0.5
    configuration.shell.path = "/bin/zsh"

    let window: TerminalWindow
    do {
        window = try TerminalWindow(configuration: configuration)
    } catch {
        print("notify-test\tFAIL: no window: \(error)")
        return false
    }
    window.onSpawnFailure = { error in
        FileHandle.standardError.write(Data("nymbra: notify-test spawn failed: \(error)\n".utf8))
    }

    /// What the window would have posted, in full — the announcement itself, not
    /// just the text of it, because what a click carries is the announcement's tab
    /// and the click path below has to be given the real thing.
    final class Postbox {
        private(set) var sent: [(announcement: CommandAttention.Announcement, tab: TabID)] = []

        var lines: [String] { sent.map { "\($0.announcement.title): \($0.announcement.body)" } }
        var tabs: [TabID] { sent.map(\.tab) }

        func note(_ announcement: CommandAttention.Announcement, for tab: TabID) {
            sent.append((announcement, tab))
        }
    }
    let postbox = Postbox()
    window.deliver = { announcement, tab in postbox.note(announcement, for: tab) }

    func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// Wait for something that is supposed to happen, so a slow runner costs
    /// time rather than a failure — but not forever.
    func pump(until arrived: () -> Bool, within timeout: Double) {
        let deadline = Date().addingTimeInterval(timeout)
        while !arrived() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    let strip = window.tabBar
    guard window.newTab() else {
        print("notify-test\tFAIL: a second tab would not open")
        return false
    }
    let tabs = strip.tabs.map(\.identifier)
    let front = window.focusedTab
    guard tabs.count == 2, let background = tabs.first(where: { $0 != front }),
          let terminal = window.panes(in: background).values.first?.terminal else {
        print("notify-test\tFAIL: no tab left in the background (tabs=\(tabs.count))")
        return false
    }

    // 1. A command that took a while, in a tab nobody is watching. This is the
    //    milestone's acceptance criterion, minus the part that needs a bundle.
    terminal.send("sleep 1.2\n")
    pump(until: { postbox.lines.count == 1 }, within: 20)
    let announced = postbox.lines.count == 1
    let measured = postbox.lines.first?.contains("Finished in 1.") == true
    let namedTheTab = postbox.tabs.first == background

    // 2. It went badly. The exit status is the reason somebody would want to
    //    know, so it leads — and a terminal that reported every finished command
    //    as a success would pass everything above this.
    terminal.send("sleep 1.2 && false\n")
    pump(until: { postbox.lines.count == 2 }, within: 20)
    let failed = postbox.lines.count == 2
    let failedSaidSo = postbox.lines.last?.contains("Exited 1 after 1.") == true

    // 3. Under the threshold: not news. The rule is tested in the harness, and
    //    this is the wiring question — that the shell's own marks are what feed
    //    it, rather than the threshold being applied to something else.
    let beforeShort = postbox.lines.count
    terminal.send("sleep 0.1\n")
    pump(1.5)
    let quiet = postbox.lines.count == beforeShort

    // 4. Turned off, which is a threshold of zero and not a separate switch.
    var silenced = configuration
    silenced.behaviour.notifyAfterSeconds = 0
    window.apply(silenced)
    let beforeSilence = postbox.lines.count
    terminal.send("sleep 1.2\n")
    pump(2.5)
    let silencedQuiet = postbox.lines.count == beforeSilence

    // 5. The click. A click only exists when somebody clicks, and the object the
    //    daemon hands over — a `UNNotificationResponse` — cannot be constructed by
    //    anything but the daemon. So both *ends* of the path are asserted instead:
    //    the tab a notification carries, built here the way the window builds it,
    //    and what happens to it when it comes back.
    //
    //    `start()` is the application's own path into this, which is why it is
    //    called rather than `makeWindow()`: it installs the notification delegate,
    //    and outside an application bundle that must not touch the notification
    //    centre at all. Reaching the next line is the assertion.
    let controller = AppController(configuration: silenced)
    guard let target = controller.start(), target.newTab() else {
        print("notify-test\tFAIL: no window to bring a tab forward in")
        return false
    }
    let targetTabs = target.tabBar.tabs.map(\.identifier)
    guard targetTabs.count == 2, let behind = targetTabs.first(where: { $0 != target.focusedTab }) else {
        print("notify-test\tFAIL: expected two tabs to click between, found \(targetTabs.count)")
        return false
    }

    let router = NotificationRouter()
    router.focus = { [weak controller] tab in controller?.focus(tab: tab) ?? false }
    // The announcement the window really produced in step 1, put into a
    // notification as the window would put it, so what the click carries is what
    // the app carries rather than something the test assembled.
    guard let real = postbox.sent.first else {
        print("notify-test\tFAIL: nothing was announced to click on")
        return false
    }
    let posted = TerminalWindow.content(for: real.announcement, tab: behind)
    let clicked = router.handle(userInfo: posted.userInfo)
    let cameForward = clicked && target.focusedTab == behind
    let nonsenseIgnored = !router.handle(userInfo: ["tab": "not a tab"])
    let strangerIgnored = !controller.focus(tab: TabID(9_999))

    print("notify-test\tannounced=\(announced ? 1 : 0) "
        + "measured=\(measured ? 1 : 0) "
        + "tab=\(namedTheTab ? 1 : 0) "
        + "failed=\(failed && failedSaidSo ? 1 : 0) "
        + "quiet=\(quiet ? 1 : 0) "
        + "off=\(silencedQuiet ? 1 : 0) "
        + "click=\(cameForward ? 1 : 0) "
        + "ignored=\(nonsenseIgnored && strangerIgnored ? 1 : 0)")
    if !announced {
        print("notify-test\tsaw=\(postbox.lines)")
    }

    // Terminated explicitly rather than left to the process exiting, so a failure
    // does not leave shells behind on a runner.
    for tab in tabs {
        for pane in window.panes(in: tab).values { pane.terminal.terminate() }
    }
    for tab in targetTabs {
        for pane in target.panes(in: tab).values { pane.terminal.terminate() }
    }
    return announced && measured && namedTheTab && failed && failedSaidSo && quiet
        && silencedQuiet && cameForward && nonsenseIgnored && strangerIgnored
}
