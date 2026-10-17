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
    /// The shell could not be started, with the system's reason. Carried as a
    /// string because the message is the whole value of the error: "cannot run
    /// /opt/homebrew/bin/fish: No such file or directory" tells a person what to
    /// fix, and `spawnFailed` on its own does not.
    case spawnFailed(shell: String, reason: String)

    /// The program that gives a shell its terminal is not where it should be.
    /// Carried as a path because the answer is always "it is not next to the
    /// binary you are running, and here is the path that was tried".
    case spawnHelperNotFound(looked: String)

    public var description: String {
        switch self {
        case let .spawnFailed(shell, reason):
            return "cannot run \(shell): \(reason)"
        case let .spawnHelperNotFound(looked):
            return "cannot find the spawn helper at \(looked) — run `make build`"
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

/// Where a new shell starts when nothing else is asked for.
///
/// Deliberately not the application's own working directory. An application
/// opened from the Finder or the Dock starts in `/`, and a shell in `/` cannot
/// create a file — which is exactly what "new window" must never do. A terminal
/// that inherits nothing useful has to choose somewhere, and home is what the
/// platform's own terminals choose and what a person expects.
public func defaultWorkingDirectory() -> String {
    let home = NSHomeDirectory()
    return home.isEmpty || access(home, X_OK) != 0 ? "/" : home
}

/// Start the user's login shell on a new PTY.
///
/// Started with `posix_spawn`, not `forkpty` (ADR-0007). That matters beyond
/// taste: `forkpty` forks *this* process, so it is only safe while the process
/// is a single thread, and every shell after the first — a new window, a tab, a
/// split — is started with AppKit already running. `posix_spawn` execs without
/// running any of this process's code in between, so there is no window in which
/// an inherited Objective-C runtime can be touched by a half-forked child.
///
/// That window is not hypothetical. It is what CI reported, unchanged, for
/// several commits while the first window was still forked:
///
///     objc[4452]: +[NSPathStore2 initialize] may have been in progress in
///     another thread when fork() was called ... Crashing instead.
///
/// The shell never started; all anyone saw was the line discipline echoing back
/// what had been typed, which reads exactly like a broken emulator.
public func spawnShell(rows: Int, cols: Int, shell explicitShell: String? = nil,
                       workingDirectory: String? = nil) throws -> PTY {
    let shellPath = resolveShell(explicitShell)
    // argv[0] is the bare name, as a login shell expects.
    return try spawn(program: shellPath, arguments: [basename(of: shellPath), "-l"],
                     rows: rows, cols: cols, workingDirectory: workingDirectory)
}

/// Run any program on a new PTY, with that terminal as its controlling terminal.
///
/// `spawnShell` is this with a login shell in the arguments. The two are the
/// same call on purpose: "the shell has a terminal" and "a program that does
/// nothing with its terminal still has one" are different claims, and the second
/// is the one that catches a spawn that only *looks* right (ADR-0008).
public func spawn(program: String, arguments: [String], rows: Int, cols: Int,
                  workingDirectory: String? = nil) throws -> PTY {
    let helper = try spawnHelperPath()
    let directory = workingDirectory ?? defaultWorkingDirectory()

    // The environment is built here rather than inherited blindly: TERM is what
    // makes full-screen programs emit the right escape sequences.
    let argv = CStringVector(arguments)
    let envp = CStringVector(childEnvironment(directory: directory))
    defer {
        argv.deallocate()
        envp.deallocate()
    }

    var master: Int32 = -1
    let pid = cpty_spawn(&master, UInt16(rows), UInt16(cols), helper, program,
                         argv.pointer, envp.pointer, directory)
    guard pid > 0 else {
        throw PTYError.spawnFailed(shell: program, reason: String(cString: strerror(errno)))
    }
    return PTY(master: master, pid: pid)
}

/// The program that claims the terminal for the child: `nymbra-spawn`.
///
/// Looked for next to the program that is running rather than in a fixed place,
/// because the two travel together everywhere they go — `.build/release/` when
/// the package is built, `Contents/MacOS/` inside the application bundle — and a
/// terminal that cannot find it cannot start a shell at all. `NYMBRA_SPAWN`
/// overrides the search for the case where they have been separated on purpose.
///
/// See ADR-0008 for why this cannot be done with a spawn attribute.
public func spawnHelperPath() throws -> String {
    let name = "NymbraSpawn"
    if let override = ProcessInfo.processInfo.environment["NYMBRA_SPAWN"],
       !override.isEmpty {
        guard access(override, X_OK) == 0 else {
            throw PTYError.spawnHelperNotFound(looked: override)
        }
        return override
    }

    let directory = runningExecutableDirectory()
    let path = directory.map { "\($0)/\(name)" } ?? name
    guard access(path, X_OK) == 0 else {
        throw PTYError.spawnHelperNotFound(looked: path)
    }
    return path
}

/// Where the running program lives, which is where its helper was built.
///
/// `Bundle.main.executableURL` is the reliable answer for both a bare executable
/// and an application bundle. `argv[0]` is the fallback for the case where there
/// is no bundle information at all, and is only trusted when it names a path.
private func runningExecutableDirectory() -> String? {
    if let executable = Bundle.main.executableURL {
        return executable.resolvingSymlinksInPath().deletingLastPathComponent().path
    }
    let argv0 = CommandLine.arguments.first ?? ""
    guard argv0.contains("/") else { return nil }
    return URL(fileURLWithPath: argv0).deletingLastPathComponent().path
}

/// The last path component, without bridging to `NSString`.
private func basename(of path: String) -> String {
    guard let separator = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: separator)...])
}

/// The environment the shell starts with. A terminal has to declare what it is
/// before a program can ask: `TERM` is what makes full-screen programs emit the
/// right escape sequences, and true-colour programs check `COLORTERM`.
private func childEnvironment(directory: String) -> [String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = "en_US.UTF-8"
    // `PWD` has to agree with where the child actually is: shells trust it for
    // `cd -` and for their prompt, and an inherited value naming a different
    // directory is a lie the child cannot detect.
    environment["PWD"] = directory
    return environment.map { "\($0.key)=\($0.value)" }
}

/// A NULL-terminated `char *` array for `posix_spawn`.
///
/// It owns the strings for as long as the array lives, because `posix_spawn`
/// reads `argv` and `envp` in the parent before the child exists; the caller
/// therefore keeps this alive until the spawn returns.
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
