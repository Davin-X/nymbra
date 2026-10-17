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

    // MARK: The terminal the shell was handed
    //
    // A PTY that is not the child's *controlling* terminal is the quietest
    // failure available here: the shell runs, prints a prompt, echoes what you
    // type, and Ctrl+C does nothing — because there is no foreground process
    // group for the tty driver to signal. Nothing on the screen says so. Only
    // `tcgetpgrp` and an interrupted job can tell the difference, so both are
    // asked directly.

    do {
        let pty = try spawnShell(rows: 24, cols: 80, shell: "/bin/sh")
        defer { close(pty.master) }

        h.expect(waitForGroup(pty.master, timeout: 3) { $0 == pty.pid } != nil,
                 "the shell is the foreground process group of its own terminal")

        // Wait until the shell is reading input, so that what follows is a
        // question about job control and not about how long a shell takes to
        // start on a slow machine.
        ptyWrite(pty.master, Array("echo NYMBRA_READY\n".utf8))
        h.expect(readUntil(pty.master, marker: "NYMBRA_READY", timeout: 5).contains("NYMBRA_READY"),
                 "the shell read a command sent down the PTY")

        // A job in the foreground gets its own process group — unless the shell
        // never got a controlling terminal, in which case it stays in the
        // shell's group and this is the assertion that notices.
        ptyWrite(pty.master, Array("sleep 30\n".utf8))
        let job = waitForGroup(pty.master, timeout: 3) { $0 != pty.pid }
        h.expect(job != nil, "a running job is put in its own process group")

        // And Ctrl+C is delivered to that group rather than to the shell.
        if let job {
            ptyWrite(pty.master, [0x03])
            h.expect(waitForGroup(pty.master, timeout: 3) { $0 == pty.pid } != nil,
                     "Ctrl+C hands the terminal back to the shell")
            h.expect(kill(job, 0) != 0, "the interrupted job is gone, not merely detached")
            kill(job, SIGKILL) // only reached if the assertion above failed
        }

        // The child must not inherit this process's signal dispositions. SIGPIPE
        // is the visible one: ignored, `yes | head -1` complains instead of
        // ending quietly.
        ptyWrite(pty.master, Array("yes | head -1 >/dev/null; echo NYMBRA_PIPE_OK\n".utf8))
        let piped = readUntil(pty.master, marker: "NYMBRA_PIPE_OK", timeout: 5)
        h.expect(piped.contains("NYMBRA_PIPE_OK"), "a pipeline whose reader exits completes")
        h.expect(!piped.lowercased().contains("broken pipe"),
                 "SIGPIPE is at its default in the shell, not ignored as it is here")

        ptyWrite(pty.master, Array("exit\n".utf8))
        _ = drain(pty.master)
        waitpid(pty.pid, nil, 0)
    } catch {
        h.expect(false, "a shell can be given a controlling terminal (\(error))")
    }

    // MARK: Where a new shell starts
    //
    // A GUI process has no useful working directory: opened from the Finder it is
    // "/", which is read-only, so the first `mkdir` fails. The shell is therefore
    // given one explicitly, and `/bin/pwd` is asked rather than the `pwd` builtin
    // — a shell prints the `PWD` it was handed, which is the very thing that
    // could be wrong.

    h.equal(defaultWorkingDirectory(), NSHomeDirectory(),
            "a new shell starts in the home directory")
    h.expect(access(defaultWorkingDirectory(), X_OK) == 0,
             "and that directory exists")

    do {
        let pty = try spawnShell(rows: 24, cols: 80, shell: "/bin/sh",
                                 workingDirectory: "/tmp")
        defer { close(pty.master) }
        ptyWrite(pty.master, Array("/bin/pwd; echo NYMBRA_CWD_OK\nexit\n".utf8))
        let text = drain(pty.master)
        waitpid(pty.pid, nil, 0)
        h.expect(text.contains("/tmp"),
                 "the shell starts where it was told to, not where the application is")
    } catch {
        h.expect(false, "a shell can be given a working directory (\(error))")
    }

    // MARK: Starting a shell while the process is busy
    //
    // This is why the spawn path is `posix_spawn` and not `forkpty` (ADR-0007):
    // every shell after the first is started with the application's threads
    // already running. Other threads are pushed to allocate and initialise
    // Foundation types while eight shells are started, which is the situation a
    // forked child could not survive.
    let workers = DispatchGroup()
    for worker in 0..<4 {
        DispatchQueue.global().async(group: workers) {
            for step in 0..<20_000 {
                _ = String(describing: ["worker": worker, "step": step])
                _ = Date().addingTimeInterval(Double(step))
                _ = UUID().uuidString
            }
        }
    }

    var started = 0
    for index in 0..<8 {
        do {
            let pty = try spawnShell(rows: 24, cols: 80, shell: "/bin/sh")
            defer { close(pty.master) }
            let marker = "NYMBRA_SPAWN_\(index)_OK"
            ptyWrite(pty.master, Array("echo \(marker); exit\n".utf8))
            if readUntil(pty.master, marker: marker, timeout: 5).contains(marker) {
                started += 1
            }
            waitpid(pty.pid, nil, 0)
        } catch {
            h.expect(false, "shell \(index) started at runtime (\(error))")
        }
    }
    workers.wait()
    h.equal(started, 8, "eight shells started while other threads were working, and each one ran")
}

// MARK: - Reading a live PTY
//
// `ptyRead` blocks until there is something to read, which is right for the
// reader thread in the application and useless for a test with a deadline. These
// wait for a marker or a process group instead, so a failure is an assertion
// rather than a hung suite.

/// Read until `marker` appears or `timeout` seconds pass.
private func readUntil(_ master: Int32, marker: String, timeout: Double) -> String {
    var output = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        // Polling first means the blocking read below has something to return.
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 50) > 0 {
            let count = ptyRead(master, into: &chunk)
            if count > 0 {
                output.append(contentsOf: chunk[0..<count])
                if String(decoding: output, as: UTF8.self).contains(marker) { break }
            } else if count == 0 {
                break
            }
        }
    }
    return String(decoding: output, as: UTF8.self)
}

/// Read until the shell exits and the PTY reports EOF.
private func drain(_ master: Int32) -> String {
    var output = [UInt8]()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = ptyRead(master, into: &chunk)
        if count <= 0 { break }
        output.append(contentsOf: chunk[0..<count])
    }
    return String(decoding: output, as: UTF8.self)
}

/// Wait for the terminal's foreground process group to satisfy `condition`.
private func waitForGroup(_ master: Int32, timeout: Double,
                          _ condition: (pid_t) -> Bool) -> pid_t? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let group = tcgetpgrp(master)
        if group > 0 && condition(group) { return group }
        usleep(20_000)
    }
    return nil
}
