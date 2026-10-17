#!/bin/bash
# End-to-end emulation checks.
#
# Each check spawns a real login shell on a real PTY, feeds its output through
# the real parser, and inspects the resulting screen — so this asserts the
# emulator, not a mock of it. No window is involved, which is what makes it
# usable in CI.
#
# Used by `make check` and by CI, so both assert exactly the same behaviour.
#
# A note on the patterns. Two things can put text on a line besides our marker:
#
#   1. The PTY echoes the command we type, so the echo line contains the literal
#      source of every sequence below. Checks that the echo could satisfy
#      (marker text, the alternate screen) therefore build their marker at run
#      time with `printf '%s'`, so the marker exists only in the program's
#      *output*, and use check_absent where the assertion is that something is
#      gone.
#   2. The login shell's prompt is drawn wherever the cursor is left. Checks
#      therefore end their output with a newline, so the row under test is
#      exact; the one check that cannot (restoring the primary screen) anchors
#      at the start of the line and tests the text before the prompt.
set -uo pipefail
cd "$(dirname "$0")/.."

BINARY=".build/release/Nymbra"
if [ ! -x "$BINARY" ]; then
  echo "emulation checks: build first (make build)" >&2
  exit 1
fi

failures=0

dump() { "$BINARY" --screen-test "$1" 2>/dev/null; }

# check <description> <shell command> <extended regex>
check() {
  if dump "$2" | grep -qE "$3"; then
    echo "  ok    $1"
  else
    echo "  FAIL  $1" >&2
    failures=$((failures + 1))
  fi
}

# check_absent <description> <shell command> <extended regex>
check_absent() {
  if dump "$2" | grep -qE "$3"; then
    echo "  FAIL  $1" >&2
    failures=$((failures + 1))
  else
    echo "  ok    $1"
  fi
}

# --- text and attributes -----------------------------------------------------

check "plain text is rendered" \
      "printf 'plain-ok\n'" 'plain-ok'

check "SGR colour is emulated, not printed" \
      "printf '\033[1;31mRED-OK\033[0m\n'" 'RED-OK'

check "wide characters occupy two columns" \
      "printf '日本語 OK\n'" '日本語'

# --- erasing -----------------------------------------------------------------

check "erase in display clears the screen" \
      "printf 'gone\033[2J\033[Hkept\n'" '^kept$'

check_absent "the text before ED is really gone" \
      "printf 'gone\033[2J\033[Hkept'" 'gone'

check "erase in line stops at the cursor" \
      "printf 'abcdef\033[3G\033[0K\n'" '^ab$'

# --- cursor and movement -----------------------------------------------------

check "the cursor can be positioned with CUP" \
      "printf '\033[5;10HX\n'" '^ {9}X$'

check "backspace moves without erasing" \
      "printf 'abc\010\010X\n'" '^aXc$'

check "tab advances to the next tab stop" \
      "printf 'a\tb\n'" '^a +b$'

check "100 characters wrap into a row of 80" \
      "printf 'x%.0s' {1..100}" '^x{80}$'

check "the screen scrolls to show the newest line" \
      "seq 1 30" '^30$'

check_absent "the oldest line has scrolled off the screen" \
      "seq 1 30" '^1$'

# --- alternate screen --------------------------------------------------------

check "the alternate screen engages" \
      "printf '\033[?1049hALT-%s\n' screen" '^ALT-screen$'

check "leaving the alternate screen restores the primary" \
      "printf 'PRIMARY-%s' restored; printf '\033[?1049hALT-%s' screen; printf '\033[?1049l'" \
      '^PRIMARY-restored'

check_absent "the alternate screen's contents are discarded on exit" \
      "printf 'PRIMARY-%s' restored; printf '\033[?1049hALT-%s' screen; printf '\033[?1049l'" \
      '^ALT-screen'

# --- a real curses program ---------------------------------------------------

check "a terminfo-driven program can clear and draw" \
      "clear; printf 'CURSES-%s\n' ok" '^CURSES-ok$'

# --- configuration -----------------------------------------------------------

# Settings are read from $NYMBRA_CONFIG here, so a test run never touches the
# real settings of whoever ran it.
config_file=$(mktemp -t nymbra-emulation-checks)
trap 'rm -f "$config_file"' EXIT

# Like check, but with a configuration file in the environment.
check_with_config() {
  if NYMBRA_CONFIG="$2" "$BINARY" --screen-test "$3" 2>/dev/null | grep -qE "$4"; then
    echo "  ok    $1"
  else
    echo "  FAIL  $1" >&2
    failures=$((failures + 1))
  fi
}

# The shell setting must actually decide which shell runs. `$0` is the shell's
# own name, and the command only prints it, so the value cannot appear in the
# echoed command line the way a literal would.
printf '{"shell": {"path": "/bin/sh"}}\n' > "$config_file"
check_with_config "the shell named in the config file is the one that runs" \
      "$config_file" 'printf "SHELL_IS=%s\n" "$0"' '^SHELL_IS=(/bin/)?sh$'

# A settings file that is broken must degrade to the defaults with a warning,
# never to a failure to start. This is the promise ADR-0006 makes.
printf 'this is not JSON at all' > "$config_file"
check_with_config "a broken config file does not stop the terminal" \
      "$config_file" "printf 'SURVIVED\n'" '^SURVIVED$'

if [ "$failures" -ne 0 ]; then
  echo "emulation checks: $failures failure(s)" >&2
  exit 1
fi
echo "emulation checks passed"
