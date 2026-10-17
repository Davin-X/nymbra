import Foundation
import CPTY

/// A pseudo-terminal running a shell.
public struct PTY {
    public let master: Int32
    public let pid: pid_t

    public init(master: Int32, pid: pid_t) {
        self.master = master
        self.pid = pid
    }
}

public enum PTYError: Error, CustomStringConvertible {
    case spawnFailed

    public var description: String {
        switch self {
        case .spawnFailed: return "forkpty failed"
        }
    }
}

/// Fork the user's login shell onto a new PTY.
///
/// Must be called before any AppKit/threads are running: `forkpty` forks the
/// process, and forking a process that already has Mach ports and threads
/// running is undefined behaviour on macOS.
public func spawnShell(rows: Int, cols: Int, shell explicitShell: String? = nil) throws -> PTY {
    let shellPath = explicitShell
        ?? ProcessInfo.processInfo.environment["SHELL"]
        ?? "/bin/zsh"

    var master: Int32 = -1
    let pid = cpty_spawn(&master, UInt16(rows), UInt16(cols))

    if pid == 0 {
        // Child. Inherit the environment, declare ourselves, then exec.
        setenv("TERM", "xterm-256color", 1)
        setenv("COLORTERM", "truecolor", 1)
        setenv("LANG", "en_US.UTF-8", 1)

        let base = (shellPath as NSString).lastPathComponent
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(base), strdup("-l"), nil]
        _ = shellPath.withCString { execv($0, &argv) }
        _exit(127)
    }

    guard pid > 0 else { throw PTYError.spawnFailed }
    return PTY(master: master, pid: pid)
}

/// Write bytes to the shell.
public func ptyWrite(_ fd: Int32, _ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
}

/// Inform the shell that the window changed size.
public func ptyResize(_ fd: Int32, rows: Int, cols: Int) {
    _ = cpty_resize(fd, UInt16(rows), UInt16(cols))
}

/// Read whatever the shell has produced. Returns 0 at EOF.
public func ptyRead(_ fd: Int32, into buffer: inout [UInt8]) -> Int {
    read(fd, &buffer, buffer.count)
}
