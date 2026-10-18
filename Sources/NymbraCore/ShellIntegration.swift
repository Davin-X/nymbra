import Foundation

/// What a shell says about its own progress, so that the terminal can tell a
/// prompt from a command's output.
///
/// A shell that has been taught to do so writes `OSC 133 ; <mark>` before and
/// after each command: `A` when it is about to print a prompt, `B` when the
/// prompt ends and the command line begins, `C` just before the command runs,
/// and `D` when it has finished, carrying the exit status. `D` may omit the
/// status, which is why it is optional here rather than defaulted to success —
/// "the command finished and I was not told how" is a different fact from "the
/// command succeeded".
///
/// Without these marks a terminal sees one undifferentiated stream of bytes. It
/// cannot answer the question the whole of M4 rests on — did the thing I started
/// finish, and did it work? — and everything built on that answer (a badge, a
/// notification, a timeline of what ran and how long it took) has nowhere to
/// start. See docs/ROADMAP.md, M4, and `Parser.onShellMark`.
public enum ShellMark: Equatable, Sendable {
    /// `OSC 133 ; A` — the shell is about to print a prompt.
    case promptStart
    /// `OSC 133 ; B` — the prompt has been printed; the command line starts here.
    case commandStart
    /// `OSC 133 ; C` — the command is about to run. The payload is the line as it
    /// was typed, or `nil` when the shell did not say which command it is running.
    ///
    /// It is not the command that *ran*: aliases are not expanded, a variable is
    /// recorded as it was written, and no shell that reports this way claims
    /// otherwise. What it is, is what was asked for — which is what a record of
    /// what you ran is for.
    case commandExecuted(String?)
    /// `OSC 133 ; D` — the command finished, with its exit status when the shell
    /// reported one.
    case commandFinished(Int32?)
}

/// `%XX` back to bytes, which is how the command travels inside a `C` mark.
///
/// Percent-encoding is not decoration here: a command can contain a BEL or an
/// ESC, and either would end the sequence before the terminal had finished
/// reading it. The encoding is the one every shell and terminal that reports
/// commands already shares, so a command recorded by Nymbra is readable by
/// anything else that understands `OSC 133`, and the reverse.
///
/// Malformed input is left exactly as it was rather than guessed at or dropped: a
/// `%` not followed by two hex digits is a `%`. This runs on whatever a shell
/// sends, and a decoder that can surprise you is the wrong half of a protocol to
/// be clever in.
enum PercentEncoding {
    static func decode(_ text: String) -> String {
        let input = Array(text.utf8)
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == 0x25, index + 2 < input.count,
               let high = hex(input[index + 1]), let low = hex(input[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        // Not a validating decode: a byte sequence that is not UTF-8 becomes the
        // replacement character, because a command that came from a shell is
        // worth showing even when part of it cannot be read.
        return String(decoding: output, as: UTF8.self)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30                    // 0-9
        case 0x41...0x46: return byte - 0x41 + 10               // A-F
        case 0x61...0x66: return byte - 0x61 + 10               // a-f
        default: return nil
        }
    }
}

/// Teaching a shell to say what it is doing, without touching the user's files.
///
/// A shell emits `OSC 133` only if something tells it to, and that telling has
/// to happen from inside the shell's own startup. zsh reads its startup files
/// from `$ZDOTDIR`, so Nymbra starts it with `ZDOTDIR` pointing at a generated
/// directory whose files load the user's real ones first and then the snippet.
///
/// The user's home directory is never written to. `ZDOTDIR` is set in the
/// environment of that one child process, so no other terminal — and no `zsh`
/// the user runs by hand — is affected, and turning the setting off stops the
/// whole mechanism rather than undoing anything.
public struct ShellIntegration: Sendable {

    /// The startup files zsh reads, in the order it reads them, all from
    /// `$ZDOTDIR`. Every one of them is generated, the empty ones included: zsh
    /// asks for these files by name, so a name left out is one of the user's own
    /// files that would never run.
    public static let startupFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"]

    /// Added to the child's environment.
    public let environment: [String: String]

    private init(environment: [String: String]) {
        self.environment = environment
    }

    /// Whether `path` is a shell this knows how to set up.
    ///
    /// Supports zsh, bash, and fish. Each has its own startup mechanism and
    /// hook names, but the OSC 133 marks they send are the same protocol.
    public static func supports(shell path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "zsh" || name == "bash" || name == "fish"
    }

    /// Write the startup files into `directory`, standing in front of the shell
    /// startup that lives in `userZDOTDIR`.
    public static func zsh(in directory: URL, userZDOTDIR: String) throws -> ShellIntegration {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try snippet.write(to: directory.appendingPathComponent("nymbra.zsh"),
                          atomically: true, encoding: .utf8)
        for name in startupFiles {
            try startup(named: name).write(to: directory.appendingPathComponent(name),
                                           atomically: true, encoding: .utf8)
        }
        return ShellIntegration(environment: [
            "ZDOTDIR": directory.path,
            "NYMBRA_USER_ZDOTDIR": userZDOTDIR,
        ])
    }

    /// Write the bash startup files into `directory`, standing in front of the
    /// shell startup that lives in `userHome`.
    ///
    /// Bash reads `.bash_profile` for login shells and `.bashrc` for interactive
    /// non-login shells. We generate both so that whichever one runs loads the
    /// user's original first, then our snippet. The snippet uses `PROMPT_COMMAND`
    /// for the prompt mark (A) and the command finished mark (D), and a `DEBUG`
    /// trap for the command executed mark (C).
    public static func bash(in directory: URL, userHome: String) throws -> ShellIntegration {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bashSnippet.write(to: directory.appendingPathComponent("nymbra.bash"),
                              atomically: true, encoding: .utf8)
        // .bash_profile for login shells
        try bashProfile.write(to: directory.appendingPathComponent(".bash_profile"),
                              atomically: true, encoding: .utf8)
        // .bashrc for interactive non-login shells
        try bashRc.write(to: directory.appendingPathComponent(".bashrc"),
                         atomically: true, encoding: .utf8)
        return ShellIntegration(environment: [
            "HOME": userHome,
            "NYMBRA_BASH_DIR": directory.path,
        ])
    }

    private static let bashProfile = """
        # Generated by Nymbra on every launch; edits here are overwritten.
        # Loads your own .bash_profile first, then the Nymbra integration.
        # Nymbra never writes to your files: delete this directory and your
        # shell is exactly as it was.
        [[ -r "${HOME}/.bash_profile" ]] && source "${HOME}/.bash_profile"
        [[ -r "${NYMBRA_BASH_DIR}/nymbra.bash" ]] && source "${NYMBRA_BASH_DIR}/nymbra.bash"
        """

    private static let bashRc = """
        # Generated by Nymbra on every launch; edits here are overwritten.
        # Loads your own .bashrc first, then the Nymbra integration.
        # Nymbra never writes to your files: delete this directory and your
        # shell is exactly as it was.
        [[ -r "${HOME}/.bashrc" ]] && source "${HOME}/.bashrc"
        [[ -r "${NYMBRA_BASH_DIR}/nymbra.bash" ]] && source "${NYMBRA_BASH_DIR}/nymbra.bash"
        """

    /// The bash snippet. Uses PROMPT_COMMAND for A/D marks and a DEBUG trap for C.
    private static let bashSnippet = #"""
        # Nymbra shell integration for bash.
        #
        # Bash does not have a direct equivalent of zsh's preexec/precmd, so we
        # use:
        #   - PROMPT_COMMAND: runs before each prompt (A mark, and D mark for the
        #     previous command)
        #   - trap DEBUG: runs before each command (C mark)
        #
        # The challenge with bash is that PROMPT_COMMAND runs *after* the command
        # finishes but *before* the prompt is drawn — perfect for A and D.
        # The DEBUG trap runs *before* each simple command — perfect for C.
        #
        # We track whether a command is running with __nymbra_running.
        #
        # Marks:
        #   A   a prompt is about to be printed
        #   C   the command is about to run, with the line as it was typed
        #   D   the command finished, with its exit status

        [[ $- == *i* ]] || return 0

        typeset -g __nymbra_running=0
        typeset -g __nymbra_last_status=0

        # Percent-encodes a command into $__nymbra_encoded for the C mark.
        function __nymbra_encode() {
            __nymbra_encoded=$1
            __nymbra_encoded=${__nymbra_encoded//'%'/'%25'}
            __nymbra_encoded=${__nymbra_encoded//$'\a'/'%07'}
            __nymbra_encoded=${__nymbra_encoded//$'\e'/'%1B'}
            __nymbra_encoded=${__nymbra_encoded//';'/'%3B'}
            __nymbra_encoded=${__nymbra_encoded//$'\t'/'%09'}
            __nymbra_encoded=${__nymbra_encoded//$'\n'/'%0A'}
            __nymbra_encoded=${__nymbra_encoded//$'\r'/'%0D'}
            __nymbra_encoded=${__nymbra_encoded//$'\x7f'/'%7F'}
        }

        # Runs before each command (DEBUG trap). $BASH_COMMAND has the command.
        function __nymbra_preexec() {
            [[ -n "$BASH_COMMAND" ]] || return 0
            __nymbra_running=1
            __nymbra_encode "$BASH_COMMAND"
            printf '\e]133;C;cmdline_url=%s\a' "$__nymbra_encoded"
        }

        # Runs before each prompt (PROMPT_COMMAND). $? is the exit status.
        function __nymbra_precmd() {
            local __nymbra_status=$?
            if (( __nymbra_running )); then
                printf '\e]133;D;%d\a' "$__nymbra_status"
                __nymbra_running=0
            fi
            printf '\e]133;A\a'
        }

        # Install traps. DEBUG trap must be set with 'trap', PROMPT_COMMAND is a variable.
        trap '__nymbra_preexec' DEBUG
        PROMPT_COMMAND="__nymbra_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
        """#

    /// Write the fish startup files into `directory`, standing in front of the
    /// shell startup that lives in `userHome`.
    ///
    /// Fish reads `config.fish` and files in `conf.d/`. We generate a conf.d
    /// file that loads after the user's config. The snippet uses fish's event
    /// system: `fish_preexec` (C), `fish_postexec` (D), and overrides `fish_prompt` (A).
    public static func fish(in directory: URL, userHome: String) throws -> ShellIntegration {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("conf.d"),
                                                withIntermediateDirectories: true)
        try fishSnippet.write(to: directory.appendingPathComponent("conf.d/nymbra.fish"),
                              atomically: true, encoding: .utf8)
        return ShellIntegration(environment: [
            "HOME": userHome,
            "NYMBRA_FISH_DIR": directory.path,
        ])
    }

    private static let fishSnippet = #"""
        # Nymbra shell integration for fish.
        #
        # Fish 3.1+ has built-in events for command tracking:
        #   - fish_preexec: emitted before a command runs (C mark)
        #   - fish_postexec: emitted after a command finishes (D mark)
        #   - fish_prompt: we override to emit A mark before the prompt
        #
        # Marks:
        #   A   a prompt is about to be printed
        #   C   the command is about to run, with the line as it was typed
        #   D   the command finished, with its exit status

        # Percent-encodes a command for the C mark.
        function __nymbra_encode
            set -l cmd $argv[1]
            string replace -- "%" "%25" $cmd
            | string replace -- $'\a' "%07"
            | string replace -- $'\e' "%1B"
            | string replace -- ";" "%3B"
            | string replace -- $'\t' "%09"
            | string replace -- $'\n' "%0A"
            | string replace -- $'\r' "%0D"
            | string replace -- $'\x7f' "%7F"
        end

        # fish_preexec: emitted before the command runs. $argv[1] is the command line.
        function __nymbra_on_preexec --on-event fish_preexec
            __nymbra_encode $argv[1]
            printf '\e]133;C;cmdline_url=%s\a' "$__nymbra_encoded"
        end

        # fish_postexec: emitted after the command finishes. $argv[2] is the exit status.
        function __nymbra_on_postexec --on-event fish_postexec
            if test $argv[2] -eq 0
                printf '\e]133;D;0\a'
            else
                printf '\e]133;D;%d\a' $argv[2]
            end
        end

        # Override fish_prompt to emit A mark before the real prompt.
        # We call the original prompt function (renamed) to preserve user's prompt.
        function __nymbra_original_prompt
            # The user's original prompt function, if any
            functions -q fish_prompt_original && fish_prompt_original
        end

        function fish_prompt
            printf '\e]133;A\a'
            __nymbra_original_prompt
        end

        # Rename user's original prompt on first load
        functions -q fish_prompt
        and not functions -q fish_prompt_original
        and functions -c fish_prompt fish_prompt_original
        """#

    /// One generated startup file: the user's own, then — for the interactive
    /// one — the snippet.
    ///
    /// `NYMBRA_USER_ZDOTDIR` is defaulted rather than trusted because the same
    /// file is what a person would read to find out what happened: a blank
    /// variable there must not turn into `source "/.zshrc"`.
    private static func startup(named name: String) -> String {
        let original = "${NYMBRA_USER_ZDOTDIR:-$HOME}/\(name)"
        let snippetLine = name == ".zshrc" ? "\nsource \"${ZDOTDIR}/nymbra.zsh\"\n" : ""
        return """
        # Generated by Nymbra on every launch; edits here are overwritten.
        # Loads your own \(name) first, so your shell starts the way it always
        # has. Nymbra never writes to your files: delete this directory and your
        # shell is exactly as it was.
        #
        # A user who has no \(name) leaves this file ending with a non-zero
        # status, and that is fine: zsh does not look at the status of a startup
        # file. Measured, under `err_return` and under `set -e`, rather than
        # assumed — see the changelog.
        [[ -r "\(original)" ]] && source "\(original)"
        \(snippetLine)
        """
    }

    /// The zsh snippet, kept here rather than in a bundle resource so that the
    /// one file a shell ever sources is one we can also read, copy and diff.
    ///
    /// A raw literal, so the escape sequences a terminal needs survive being
    /// written down as shell source.
    private static let snippet = #"""
    # Nymbra shell integration for zsh.
    #
    # Nymbra starts zsh with ZDOTDIR pointing at a small generated directory
    # whose startup files load your own first and then this one. Your files are
    # never edited, and turning the setting off puts your shell back exactly as it
    # was.
    #
    # This file's whole job is to tell the terminal what the shell is doing, with
    # OSC 133 marks, because the terminal cannot work it out for itself: a
    # prompt, a command, and a command's output are all just bytes coming back up
    # the pty.
    #
    #   A   a prompt is about to be printed
    #   C   the command is about to run, with the line as it was typed
    #   D   the command finished, with its exit status
    #
    # `B`, which marks where the command line begins, is deliberately not sent.
    # The only way to know when zsh has finished drawing the prompt is to define
    # its `zle-line-init` widget, and that is the line editor — the one part of a
    # shell where being second in line is worse than not being there at all.
    # Nothing built here needs it yet, so it can wait.
    #
    # Nothing here changes the prompt, and nothing here is written to disk.

    [[ -o interactive ]] || return 0
    autoload -Uz add-zsh-hook 2>/dev/null || return 0

    typeset -g __nymbra_running=0

    # Percent-encodes a command into `$__nymbra_encoded` for the `C` mark below.
    #
    # Eight bytes are rewritten, and each one is there for a reason: BEL and ESC
    # would end the sequence before the terminal had finished reading it (BEL
    # terminates an OSC, ESC begins the `ESC \` it also accepts as a terminator); a
    # semicolon separates the mark's own key/value fields; a percent sign has to
    # survive being the escape character; and tab, newline, carriage return and
    # delete are control bytes a line can contain that a sequence does not carry —
    # the parser drops them — so they are encoded rather than lost.
    #
    # Everything else, spaces and quotes and pipes and UTF-8 included, travels
    # exactly as typed, so what comes out the other end is the command rather than a
    # mangled echo of it.
    #
    # It assigns rather than prints because `$(...)` would fork a subshell on every
    # command a person runs, and this runs on every command a person runs.
    function __nymbra_encode() {
      __nymbra_encoded=$1
      __nymbra_encoded=${__nymbra_encoded//'%'/'%25'}
      __nymbra_encoded=${__nymbra_encoded//$'\a'/'%07'}
      __nymbra_encoded=${__nymbra_encoded//$'\e'/'%1B'}
      __nymbra_encoded=${__nymbra_encoded//';'/'%3B'}
      __nymbra_encoded=${__nymbra_encoded//$'\t'/'%09'}
      __nymbra_encoded=${__nymbra_encoded//$'\n'/'%0A'}
      __nymbra_encoded=${__nymbra_encoded//$'\r'/'%0D'}
      __nymbra_encoded=${__nymbra_encoded//$'\x7f'/'%7F'}
    }

    function __nymbra_preexec() {
      __nymbra_running=1
      # `$1` is the line as typed. Nothing here reads the command out of the
      # prompt or off the screen; the shell is asked, because the shell knows.
      __nymbra_encode "$1"
      printf '\e]133;C;cmdline_url=%s\a' "$__nymbra_encoded"
    }

    function __nymbra_precmd() {
      # Not `status`: zsh keeps that name read-only as a synonym for `$?`, and
      # assigning to it aborts the hook before a single mark is sent.
      local __nymbra_status=$?
      if (( __nymbra_running )); then
        printf '\e]133;D;%d\a' "$__nymbra_status"
        __nymbra_running=0
      fi
      printf '\e]133;A\a'
    }

    # Prepended rather than appended: the status being reported is the command's,
    # and a prompt framework's own precmd has run commands of its own by the time
    # an appended hook would get to look at $?.
    precmd_functions=(__nymbra_precmd $precmd_functions)
    preexec_functions=(__nymbra_preexec $preexec_functions)
    """#
}

extension Configuration {

    /// The shell integration this configuration asks for, or `nil` when it asks
    /// for none.
    ///
    /// The files are rewritten on every call, which is what makes the answer
    /// always match the setting: turning the setting off has nothing to undo,
    /// it just stops pointing the shell's startup directory at them. A shell
    /// already running keeps whatever environment it was started with, so the
    /// change lands on the next shell.
    ///
    /// Returns `nil` if the files cannot be written — a terminal that refused to
    /// open a window because it could not write its own shell helper would be a
    /// worse bug than the one it was reporting. The visible result is then the
    /// same as the setting being off: a shell that does not report its marks.
    public func shellIntegration(
        in supportDirectory: URL = Configuration.supportDirectory,
        userZDOTDIR: String = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? ""
    ) -> ShellIntegration? {
        guard behaviour.shellIntegration else { return nil }
        let shellName = (shell.path as NSString?)?.lastPathComponent ?? ""
        let shellDir = supportDirectory.appendingPathComponent("shell")
        let userHome = NSHomeDirectory()
        do {
            switch shellName {
            case "zsh", "":
                // Default to zsh when no shell is configured (backward compatibility)
                return try ShellIntegration.zsh(
                    in: shellDir, userZDOTDIR: userZDOTDIR)
            case "bash":
                return try ShellIntegration.bash(
                    in: shellDir, userHome: userHome)
            case "fish":
                return try ShellIntegration.fish(
                    in: shellDir, userHome: userHome)
            default:
                return nil
            }
        } catch {
            return nil
        }
    }
}
