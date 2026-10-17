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
}
