import Darwin
import Foundation

/// A live terminal: a PTY, the parser that consumes its output, and the screen
/// those bytes describe.
///
/// Threading (docs/ARCHITECTURE.md): one reader thread blocks on the PTY master.
/// Every chunk is handed to `deliveryQueue` — the main queue in the application —
/// where the parser mutates the screen and `onUpdate` fires. The screen is
/// therefore only ever touched on one thread, which is why it needs no locking.
public final class Terminal {
    public let screen: Screen
    public let parser: Parser
    public let master: Int32
    public let pid: pid_t

    /// Called on `deliveryQueue` after output has been parsed.
    public var onUpdate: (() -> Void)?
    /// Called on `deliveryQueue` when the shell exits or the PTY reaches EOF.
    public var onExit: (() -> Void)?
    /// Called on `deliveryQueue` for a `BEL`.
    public var onBell: (() -> Void)?
    /// Called on `deliveryQueue` for a shell-integration mark (`OSC 133`), which
    /// is how the shell reports prompts, commands and exit statuses.
    public var onShellMark: ((ShellMark) -> Void)?

    private let ioQueue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private var started = false

    /// Spawn `shell` — or the user's login shell — in a `size` grid.
    ///
    /// The grid is one value rather than two integers so that the rows and the
    /// columns cannot be handed over in the wrong order; see `GridSize`.
    ///
    /// May be constructed at any time, including with AppKit already running and
    /// other shells live: shells are started with `posix_spawn`, so this process
    /// is never forked (ADR-0007). That is what makes more than one window, and
    /// later more than one pane, possible at all.
    public init(
        size: GridSize,
        shell: String? = nil,
        deliveryQueue: DispatchQueue = .main
    ) throws {
        let pty = try spawnShell(rows: size.rows, cols: size.cols, shell: shell)
        let screen = Screen(rows: size.rows, cols: size.cols)
        self.master = pty.master
        self.pid = pty.pid
        self.screen = screen
        self.parser = Parser(screen: screen)
        self.deliveryQueue = deliveryQueue
        self.ioQueue = DispatchQueue(label: "dev.nymbra.reader", qos: .userInteractive)
    }

    /// Begin reading the PTY. Safe to call more than once.
    public func start() {
        guard !started else { return }
        started = true
        parser.onResponse = { [weak self] bytes in self?.send(bytes) }
        parser.onBell = { [weak self] in self?.onBell?() }
        parser.onShellMark = { [weak self] mark in self?.onShellMark?(mark) }
        ioQueue.async { [weak self] in self?.readLoop() }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = ptyRead(master, into: &chunk)
            if count <= 0 { break }
            let bytes = Array(chunk[0..<count])
            deliveryQueue.async { [weak self] in
                guard let self else { return }
                self.parser.feed(bytes)
                self.onUpdate?()
            }
        }
        deliveryQueue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.onExit?()
        }
    }

    /// True until the shell exits or the PTY reaches end of file.
    public private(set) var isRunning = true

    /// True when something other than the shell itself holds the terminal's
    /// foreground — a command still running, which is worth confirming before a
    /// window is closed.
    ///
    /// The shell is the session leader and its own process group, and a child job
    /// takes the foreground group. Comparing the two is the POSIX way to ask
    /// whether the shell is busy. A shell without job control never changes the
    /// foreground group, so this answers `false` there; that is the honest
    /// answer rather than a bug, and it is why the confirmation is a courtesy
    /// rather than a guarantee.
    public var hasForegroundJob: Bool {
        let foreground = tcgetpgrp(master)
        return foreground != -1 && foreground != pid
    }

    // MARK: - Input

    public func send(_ bytes: [UInt8]) {
        ptyWrite(master, bytes)
    }

    public func send(_ text: String) {
        send(Array(text.utf8))
    }

    /// Resize both the model and the PTY, so the shell sees `SIGWINCH` and knows
    /// the new dimensions. Call on the delivery queue.
    ///
    /// Takes one `GridSize`, not a pair of integers: this is the seam where a
    /// transposed pair silently misinforms every program that formats to the
    /// terminal's width.
    public func resize(_ size: GridSize) {
        guard size.rows != screen.rows || size.cols != screen.cols else { return }
        screen.resize(rows: size.rows, cols: size.cols)
        ptyResize(master, rows: size.rows, cols: size.cols)
    }

    /// Hang up on the shell.
    public func terminate() {
        kill(pid, SIGHUP)
    }
}
