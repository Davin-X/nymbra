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
        terminal.send("echo PTY_OK; echo TERM=$TERM; tty; id -un; uname -m; exit\n")

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

// MARK: - Application

// The shell is spawned *first*, before AppKit is initialised. `forkpty` forks,
// and forking a process that already has AppKit's threads and Mach ports running
// is undefined behaviour (ADR-0002). The PTY is opened at a default size and
// corrected with TIOCSWINSZ once the window exists.
let terminal: Terminal
do {
    terminal = try Terminal(size: GridSize(rows: 24, cols: 80), shell: settings.shell.path)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let controller = AppController(configuration: settings)
controller.start(terminal: terminal)

app.activate(ignoringOtherApps: true)
app.run()
