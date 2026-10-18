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
    /// `OSC 133 ; C` — the command is about to run.
    case commandExecuted
    /// `OSC 133 ; D` — the command finished, with its exit status when the shell
    /// reported one.
    case commandFinished(Int32?)
}
