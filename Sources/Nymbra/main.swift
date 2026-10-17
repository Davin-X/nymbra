import AppKit
import Foundation
import NymbraCore

// MARK: - Headless proof
//
// Proves the PTY works without needing a GUI, so CI can run it.

func runPTYTest() {
    do {
        let pty = try spawnShell(rows: 24, cols: 80)
        ptyWrite(pty.master, Array("echo PTY_OK; echo TERM=$TERM; tty; id -un; uname -m; exit\n".utf8))

        var output = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = ptyRead(pty.master, into: &chunk)
            if n <= 0 { break }
            output.append(contentsOf: chunk[0..<n])
        }
        waitpid(pty.pid, nil, 0)
        FileHandle.standardOutput.write(Data(output))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

if CommandLine.arguments.contains("--pty-test") {
    runPTYTest()
    exit(0)
}

// MARK: - Application

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let buffer = TermBuffer()
let frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
let view = TermView(frame: frame, buffer: buffer)

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

// Must happen before any other work starts: forkpty() forks the process.
let pty: PTY
do {
    pty = try spawnShell(rows: view.rows, cols: view.cols)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

view.onInput = { bytes in ptyWrite(pty.master, bytes) }
view.onResize = { rows, cols in ptyResize(pty.master, rows: rows, cols: cols) }

DispatchQueue.global(qos: .userInteractive).async {
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = ptyRead(pty.master, into: &chunk)
        if n <= 0 { break }
        let bytes = Array(chunk[0..<n])
        DispatchQueue.main.async {
            buffer.feed(bytes)
            view.needsDisplay = true
        }
    }
    DispatchQueue.main.async { window.title = "Nymbra \u{2014} shell exited" }
}

app.activate(ignoringOtherApps: true)
app.run()
