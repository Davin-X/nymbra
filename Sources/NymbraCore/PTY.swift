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

/// The shell to run: the one asked for, else `$SHELL`, else the first login
/// shell that actually exists on this machine.
///
/// An empty `$SHELL` counts as unset. It is not a path, and handing it to
/// `execve` fails the instant the child starts — which is how a CI runner whose
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

/// Fork the user's login shell onto a new PTY.
///
/// Everything the child needs is built **here**, before the fork: after `forkpty`
/// the child may call nothing but async-signal-safe functions, and in particular
/// may not touch Foundation. This is not pedantry. The child inherits the whole
/// Objective-C runtime, and using it — even by bridging a Swift `String` to
/// `NSString`, which is what `lastPathComponent` does — can be fatal:
///
///     objc[4452]: +[NSPathStore2 initialize] may have been in progress in
///     another thread when fork() was called ... Crashing instead.
///
/// That message is what CI collected, unchanged, for several commits: the shell
/// never started, and the only thing on the terminal was the line discipline
/// echoing back what had been typed — which reads exactly like a broken emulator
/// and was a broken child.
public func spawnShell(rows: Int, cols: Int, shell explicitShell: String? = nil) throws -> PTY {
    let shellPath = resolveShell(explicitShell)

    // The path, the arguments, the environment and the failure message are all
    // prepared in the parent, because the child can only hand pointers to
    // `execve` and `write`.
    let path = strdup(shellPath)
    let argv = CStringVector([basename(of: shellPath), "-l"])
    let envp = CStringVector(childEnvironment())
    let failure = Array("nymbra: cannot run \(shellPath): ".utf8)
    defer {
        free(path)
        argv.deallocate()
        envp.deallocate()
    }

    var master: Int32 = -1
    let pid = cpty_spawn(&master, UInt16(rows), UInt16(cols))

    if pid == 0 {
        execve(path, argv.pointer, envp.pointer)

        // `execve` only returns when it failed. Say so on the terminal itself
        // rather than exiting silently: "the terminal printed nothing" is a far
        // worse bug report than "cannot run /bin/typo: No such file or
        // directory". Plain C and the standard library only, no Foundation —
        // see the note above.
        failure.withUnsafeBufferPointer { buffer in
            _ = write(2, buffer.baseAddress, buffer.count)
        }
        if let reason = strerror(errno) {
            _ = write(2, reason, strlen(reason))
        }
        _ = "\r\n".withCString { write(2, $0, strlen($0)) }
        _exit(127)
    }

    guard pid > 0 else { throw PTYError.spawnFailed }
    return PTY(master: master, pid: pid)
}

/// The last path component, without bridging to `NSString`.
private func basename(of path: String) -> String {
    guard let separator = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: separator)...])
}

/// The environment the shell starts with. A terminal has to declare what it is
/// before a program can ask: `TERM` is what makes full-screen programs emit the
/// right escape sequences, and true-colour programs check `COLORTERM`.
private func childEnvironment() -> [String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = "en_US.UTF-8"
    return environment.map { "\($0.key)=\($0.value)" }
}

/// A NULL-terminated `char *` array, filled in the parent and handed to `execve`
/// in the child.
///
/// It exists so that no allocation or bridging happens between the fork and the
/// exec: `forkpty` forks a process that may hold allocator and runtime locks on
/// other threads, and a child that takes one of those locks never returns.
private final class CStringVector {
    private let storage: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        storage = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            storage[index] = strdup(string)
        }
        storage[strings.count] = nil
    }

    var pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> { storage }

    func deallocate() {
        for index in 0..<count {
            free(storage[index])
        }
        storage.deallocate()
    }
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
