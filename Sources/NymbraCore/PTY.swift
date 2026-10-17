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
/// The shell to run: the one asked for, else `$SHELL`, else the first login
/// shell that actually exists on this machine.
///
/// An empty `$SHELL` counts as unset. It is not a path, and handing it to
/// `execv` fails the instant the child starts — which is how a CI runner whose
/// `SHELL` is set but empty turns a working terminal into "no output at all".
/// A shell that is not executable is skipped for the same reason: a login shell
/// that cannot run is worth less than a fallback that can.
public func resolveShell(_ explicitShell: String? = nil) -> String {
    var candidates: [String] = []
    if let explicitShell, !explicitShell.isEmpty { candidates.append(explicitShell) }
    if let environment = ProcessInfo.processInfo.environment["SHELL"], !environment.isEmpty {
        candidates.append(environment)
    }
    candidates += ["/bin/zsh", "/bin/bash", "/bin/sh"]

    for candidate in candidates where access(candidate, X_OK) == 0 {
        return candidate
    }
    // Nothing above exists, which cannot happen on macOS. `/bin/sh` is the
    // POSIX guarantee, so it is the answer even so.
    return "/bin/sh"
}

public func spawnShell(rows: Int, cols: Int, shell explicitShell: String? = nil) throws -> PTY {
    let shellPath = resolveShell(explicitShell)

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

        // execv only returns when it failed. Say so on the terminal itself
        // rather than exiting silently: "the terminal printed nothing" is a far
        // worse bug report than "cannot run /bin/typo: No such file or
        // directory", and this is the only place that knows which it was.
        let reason = String(cString: strerror(errno))
        let message = "nymbra: cannot run \(shellPath): \(reason)\r\n"
        _ = message.withCString { write(2, $0, strlen($0)) }
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

/// Read whatever the shell has produced. Returns 0 at EOF, negative on error.
///
/// `EINTR` is retried rather than reported. A signal arriving mid-read is not
/// the end of the shell's output, and treating it as EOF truncates a session
/// at a random point — which is the kind of bug that only ever appears under
/// load.
public func ptyRead(_ fd: Int32, into buffer: inout [UInt8]) -> Int {
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        return count
    }
}
