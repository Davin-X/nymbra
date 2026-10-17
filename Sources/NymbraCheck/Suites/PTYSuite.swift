import Darwin
import Foundation
import NymbraCore

/// Shell resolution, asserted without a window.
///
/// This suite exists because of a CI failure that read like a broken emulator:
/// the runner's `SHELL` was set but empty, `execv("")` failed inside the child,
/// and the terminal printed nothing at all — so the smoke test saw an empty file
/// and the emulator took the blame. "Which shell runs, and what happens when the
/// answer is nonsense" has a right answer, so it is asserted here rather than
/// discovered on a runner.
func ptySuite(_ h: Harness) {
    h.suite("pty")

    // MARK: A shell that was asked for

    h.equal(resolveShell("/bin/sh"), "/bin/sh", "an explicit shell that exists is used as-is")
    h.equal(resolveShell("/bin/bash"), "/bin/bash", "so is any other that exists")

    // MARK: A shell that cannot be used

    // An empty string is not a path and a path that does not exist is not a
    // shell. Neither may reach `execv`, because the failure is silent.
    let unresolvable = [
        ("empty", resolveShell("")),
        ("missing", resolveShell("/definitely/not/a/shell")),
    ]
    for (name, path) in unresolvable {
        h.expect(path.hasPrefix("/"), "the \(name) shell falls back to an absolute path (\(path))")
        h.expect(access(path, X_OK) == 0, "the \(name) shell falls back to something executable")
        h.expect(path != "", "the \(name) shell does not fall back to nothing")
    }

    h.expect(resolveShell("/definitely/not/a/shell") != "/definitely/not/a/shell",
             "a shell that cannot be run is not returned merely because it was named")

    // MARK: The default

    // Whatever `$SHELL` says — including nothing — the answer is runnable.
    let fromEnvironment = resolveShell(nil)
    h.expect(fromEnvironment.hasPrefix("/"), "the default shell is an absolute path")
    h.expect(access(fromEnvironment, X_OK) == 0,
             "the default shell, \(fromEnvironment), is executable")

    // The fallbacks are tried in order, so the first one that exists wins rather
    // than the first one that was listed.
    h.expect(resolveShell("") == resolveShell("/definitely/not/a/shell"),
             "two unusable shells resolve to the same fallback")

    // MARK: The child itself

    // Everything above is answerable without a fork. This one is not: it proves
    // that the process on the other end of the PTY is a *shell*, and that the
    // child survived the fork.
    //
    // The distinction matters because the PTY echoes what is typed into it. A
    // child that dies before `exec` still produces a screen full of text, so
    // "the command appears in the output" proves nothing at all — only the
    // *result* of running it does.
    do {
        let pty = try spawnShell(rows: 24, cols: 80, shell: "/bin/sh")
        ptyWrite(pty.master, Array("echo NYMBRA_$((6*7))\nexit\n".utf8))

        var output = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = ptyRead(pty.master, into: &chunk)
            if count <= 0 { break }
            output.append(contentsOf: chunk[0..<count])
        }
        waitpid(pty.pid, nil, 0)
        let text = String(decoding: output, as: UTF8.self)

        // `$((6*7))` has to be *evaluated*, which the echo of the command line
        // cannot do for it.
        h.expect(text.contains("NYMBRA_42"),
                 "the shell on the other end of the PTY ran the command it was sent")
        h.expect(!text.contains("objc["),
                 "the forked child did not touch the Objective-C runtime")
        h.expect(!text.contains("cannot run"),
                 "the child reached the shell rather than failing to exec one")
    } catch {
        h.expect(false, "a shell can be spawned on a PTY (\(error))")
    }
}
