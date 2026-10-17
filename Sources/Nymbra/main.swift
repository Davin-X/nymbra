import AppKit
import Foundation
import NymbraCore

// MARK: - Headless proofs
//
// CI cannot look at a window, so correctness is demonstrated by driving the
// emulator with real bytes and printing what the screen model made of them.

/// Spawn a login shell, run one command, and print every raw byte it produced.
func runPTYTest(shell: String?) {
    do {
        let terminal = try Terminal(rows: 24, cols: 80, shell: shell)
        terminal.send("echo PTY_OK; echo TERM=$TERM; tty; id -un; uname -m; exit\n")

        var output = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = ptyRead(terminal.master, into: &chunk)
            if count <= 0 { break }
            output.append(contentsOf: chunk[0..<count])
        }
        waitpid(terminal.pid, nil, 0)
        FileHandle.standardOutput.write(Data(output))
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
        let terminal = try Terminal(rows: 24, cols: 80, shell: shell)
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

// MARK: - Application

// The shell is spawned *first*, before AppKit is initialised. `forkpty` forks,
// and forking a process that already has AppKit's threads and Mach ports running
// is undefined behaviour (ADR-0002). The PTY is opened at a default size and
// corrected with TIOCSWINSZ once the window exists.
let terminal: Terminal
do {
    terminal = try Terminal(rows: 24, cols: 80, shell: settings.shell.path)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
let view = TermView(frame: frame, screen: terminal.screen, configuration: settings)

let window = NSWindow(
    contentRect: frame,
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "Nymbra"
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)

view.onInput = { bytes in terminal.send(bytes) }
view.onResize = { rows, cols in terminal.resize(rows: rows, cols: cols) }

// The window's real grid size is only known now, so tell the shell about it.
terminal.resize(rows: view.rows, cols: view.cols)

terminal.onUpdate = { [weak view] in
    view?.needsDisplay = true
    if !terminal.screen.title.isEmpty { window.title = terminal.screen.title }
}
terminal.onBell = { NSSound.beep() }
terminal.onExit = { window.title = "Nymbra \u{2014} shell exited" }
terminal.start()

app.activate(ignoringOtherApps: true)
app.run()
