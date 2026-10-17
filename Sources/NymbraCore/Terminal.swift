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

    private let ioQueue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private var started = false

    /// Spawn `shell` — or the user's login shell — sized `rows` × `cols`.
    ///
    /// Must be constructed before AppKit is initialised: `forkpty` forks, and
    /// forking a process with live threads and Mach ports is undefined behaviour.
    /// See ADR-0002.
    public init(
        rows: Int,
        cols: Int,
        shell: String? = nil,
        deliveryQueue: DispatchQueue = .main
    ) throws {
        let pty = try spawnShell(rows: rows, cols: cols, shell: shell)
        let screen = Screen(rows: rows, cols: cols)
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
        deliveryQueue.async { [weak self] in self?.onExit?() }
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
    public func resize(rows: Int, cols: Int) {
        guard rows != screen.rows || cols != screen.cols else { return }
        screen.resize(rows: rows, cols: cols)
        ptyResize(master, rows: rows, cols: cols)
    }

    /// Hang up on the shell.
    public func terminate() {
        kill(pid, SIGHUP)
    }
}
