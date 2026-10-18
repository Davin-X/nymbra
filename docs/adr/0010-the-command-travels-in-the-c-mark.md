# ADR-0010 — The command travels in the `C` mark, percent-encoded

**Status:** Accepted · 2026-10-18

## Context

`OSC 133` says *when* things happen — `A`, `C`, `D` — and that is all the
notification work needed (ADR-0009). The command timeline needs one more thing:
*what* ran.

A terminal cannot work that out for itself, and it is worth being precise about why,
because the obvious answers are all wrong:

- **The echo is not the command.** What comes back up the pty while somebody types
  is the line editor redrawing its buffer: cursor moves, rewrites, and every
  keystroke that was later deleted. Reconstructing a command from that is a
  screen-scraper, and the screen belongs to the shell, not to us.
- **The output is not the command either.** `echo hi` and a program that prints
  `hi` are the same bytes.
- **The command line the terminal *has* is not the command.** Nymbra knows the
  bytes it sent to the pty, which is what the keyboard and the pasteboard
  produced — not what the shell decided to run.

So the shell has to say it. The only question is what form it arrives in, and the
form has one hard requirement: a command is arbitrary bytes, and two of those bytes
are hostile to the sequence carrying them. `BEL` ends an OSC, and `ESC` begins the
`ESC \` terminator that this terminal also accepts.

## Decision

**`OSC 133 ; C ; cmdline_url=<percent-encoded line>`.**

1. **A key in the mark's key/value list**, which is the shape the terminals that
   report commands already share — kitty documents `cmdline` and `cmdline_url` for
   exactly this, and Contour reads `cmdline_url`. What Nymbra records is therefore
   legible to them and theirs to Nymbra, which is worth more than a private format
   would be for one line of parser.
2. **`cmdline_url` rather than kitty's `cmdline`.** kitty's `cmdline` is the line
   shell-quoted with `%q`: the form you could feed back to a shell. Nymbra wants the
   line as text, to show and to search, and un-quoting is a shell lexer. The URL
   form is already the text.
3. **Percent-encoded, because the command is arbitrary bytes.** Eight of them are
   rewritten, and the list is finite and arguable: `BEL` and `ESC` end the sequence
   or its terminator; `;` separates the mark's own fields; `%` is the escape
   character; and tab, newline, carriage return and delete are control bytes a line
   can contain that a sequence does not carry — this terminal's parser drops them.
   Everything else, UTF-8 included, travels verbatim, so the recorded text is the
   command rather than a sanitised echo of it.
4. **As typed, not as run.** `preexec`'s `$1` is the line the person wrote: aliases
   are not expanded and a variable is recorded as the name that was typed, not the
   value it held. That is the honest record — a terminal that showed you the
   expanded command would be showing you something you never wrote — and it is
   also the only thing the shell offers without re-implementing expansion.
5. **Absent means unknown, and that is not an error.** A bare `C` — what every
   Nymbra snippet before this one sent, and what a shell that reports marks but not
   commands sends — is `nil`, and an empty value is `nil` too: an empty command is
   not a command.

The escaping is done in the shell, by eight parameter substitutions in a function
that *assigns* rather than prints, because `$(...)` forks — and this runs on every
command a person runs. A subshell per command, in a terminal, is a real cost paid
for nothing.

## Consequences

- The snippet grew a function and three lines in `preexec`. It still does not
  touch the prompt, write a file, or run anything the user did not ask for.
- `ShellMark.commandExecuted` carries a `String?`, so every consumer has to say
  what it does about the command — including the ones that ignore it, which is
  currently all of them. **Nothing reads the payload yet.** It is the half of the
  timeline that has to exist before anything can show one, and until then
  `--shell-integration-test` is the only thing asserting it, against a real zsh.
- The parser's decoder is total: a `%` not followed by two hex digits is a `%`, and
  input that is not UTF-8 becomes the replacement character rather than an error. It
  runs on whatever a shell sends.
- A command line is now on the wire between the shell and the terminal, where before
  only its timing was. It was already on the wire in the other direction — the
  terminal wrote it to the pty — so this is not a new exposure, but it is the first
  time anything keeps it, which is why the recording that uses it should not
  default to on.

## References

- [kitty, shell integration](https://sw.kovidgoyal.net/kitty/shell-integration/)
  — `cmdline` and `cmdline_url` on `OSC 133 ; C`
- [Contour, OSC 133](https://contour-terminal.org/vt-extensions/osc-133-shell-integration/)
  — `OSC 133 ; C [; <Key>=<Value>...] ST`, `cmdline_url`
- [ADR-0009](0009-shell-integration-without-touching-dotfiles.md) — how the shell
  is taught to send any of this at all
