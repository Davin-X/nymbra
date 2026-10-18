# Roadmap and Plan

The single source of truth for **what we are building and in what order**.
Anything not listed here is out of scope until this document changes.

**Status legend:** ✅ done · ⏳ in progress · 🔜 planned · 💭 candidate

## Product thesis

The terminal is the one tool a developer never closes. The market is split
between dated (Terminal.app), heavy (Electron/WebView terminals), and
expert-but-spartan (Ghostty). Nymbra's position is **native, calm, and
attentive** — a terminal that stays out of the way and tells you what needs you,
rather than one that tries to out-feature iTerm2.

We do **not** compete on emulation breadth. We compete on a small number of
things done properly.

## Principles

These decide arguments. When in doubt, the higher principle wins.

1. **Correctness before features.** A terminal that renders `vim` wrongly is
   worthless no matter how many features it has.
2. **Native before clever.** Prefer an Apple framework over a reconstruction of
   it. AppKit, CoreText and Metal are the platform, not dependencies.
3. **Quiet by default.** No telemetry, no account, no network. Ever.
4. **Testable headlessly.** If a feature cannot be asserted without a human
   looking at a window, it is designed wrongly.
5. **Every dependency is a liability.** See [ADR-0001](adr/0001-native-swift-zero-runtime-dependencies.md).

## Coverage against a minimally usable terminal

The checklist a terminal must satisfy to be worth opening. Kept here so gaps are
visible rather than discovered later.

### Core emulation

| Requirement | State |
|---|---|
| Shell + PTY: launch, input, output, exit, resize via `TIOCSWINSZ` | ✅ |
| Escape sequences: cursor, clear line/screen, scroll regions, save/restore | ✅ |
| SGR: colour, bold, underline, reverse, reset | ✅ 16/256/truecolour, plus italic/faint/conceal/strike/underline styles |
| Normal + alternate screen | ✅ 47/1047/1048/1049 |
| Scrollback buffer | ✅ 10 000 lines, scrolled with the wheel or trackpad; typing returns to the live screen |
| Keyboard: Enter, Backspace, delete, arrows, control keys | ✅ arrows honour DECCKM and carry xterm's modifier encoding; Option is meta; Shift-Tab is CBT |
| Function keys F1–F12 | ✅ F1–F20, in the SS3 and `CSI n ~` forms |
| UTF-8 across read boundaries, wide characters | ✅ |
| Combining marks | ✅ asserted in the unit suite |
| Emoji and grapheme clusters (ZWJ sequences) | ⚠️ emoji width detected; clusters are not grouped into one cell |
| Robustness under malformed/long sequences | ⚠️ parser is total and fuzzed at ~10⁵ bytes; target is 10⁶ |

### App features

| Requirement | State | Milestone |
|---|---|---|
| Copy/paste | ✅ selection (click, word, line, drag), Cmd+C and Cmd+V with bracketed paste | — |
| Scrollback buffer | ✅ 10 000 lines, scrolled with the wheel or trackpad; typing returns to the live screen | — |
| Search in scrollback | ✅ find overlay, next/previous, matches highlighted in history and the live screen | — |
| Tabs and split panes | ✅ | M1.x (P0) |
| Text reflow on resize | ✅ live screen and history rewrap on resize; soft-wrapped rows are rejoined and rewrapped | — |
| Mouse reporting | ✅ modes 1000/1002/1003 in the X10 and SGR encodings | — |
| Settings: theme, font, colours, cursor, keybindings | ✅ one JSON file, a settings window with live preview, and a readable palette | M2 |
| Shell integration: prompt/command boundaries, notifications | ⚠️ `OSC 133` marks (`A`/`B`/`C`/`D` with the exit status) parse into `ShellMark` events, a bundled zsh integration emits `A`/`C`/`D`, and `behaviour.shellIntegration` turns it on; `B`, the settings-window toggle, `bash`/`fish`, and the badge, notification and timeline built on the marks remain | M4 |
| Per-tab unread badge | ✅ a tab marks itself with a dot when it prints in the background, cleared by looking at it; the "command finished" form needs the `OSC 133` marks, which now parse | M4 |
| Session recovery/persistence | ❌ | M5 |
| Colour legibility for program-chosen colours | ✅ `Palette.readable` lifts any foreground below 4.5:1 | — |

`Scripts/emulation-checks.sh` asserts the emulation rows above end to end, on a
real PTY, with no window — the same script `make check` and CI run.

## Milestones

### M0 — Foundation ✅

PTY, native window, CoreText grid, keyboard input, live resize, test harness
and CI.

**Acceptance (met):** `make check` passes; `--pty-test` runs a login shell;
the architecture guard passes.

### M1 — VT emulation ✅ *core complete*

The milestone that makes this a terminal rather than a demo.

**Delivered**
- A state machine over the ground, escape, CSI, OSC, DCS, charset and
  SOS/PM/APC families, with ECMA-48 parameters including colon sub-parameters
- Cursor: position, visibility, shape (DECSCUSR), save/restore, movement and
  tab stops (HTS/TBC/CBT)
- SGR: 16-, 256- and 24-bit colour; underline styles; bold, faint, italic,
  reverse, conceal and strike
- Screen: erase (ED/EL/ECH), insert and delete (IL/DL/ICH/DCH), scroll regions
  (DECSTBM) whose margins are respected by cursor movement, DECAWM with deferred
  wrap, origin mode (DECOM)
- Alternate screen (47, 1047, 1048, 1049)
- Bracketed paste, focus reporting, and mouse mode/encoding flags
- Resize that preserves content
- Keyboard: F1–F20, arrows with DECCKM and xterm's modifier encoding, meta via
  Option, control combinations (`NymbraInput`)
- Viewport scrolling through 10 000 lines of scrollback

**Owed — tracked here rather than quietly dropped**
- Text **reflow** on resize. Resize preserves content but does not rewrap;
  moved to M3 deliberately.
- **Mouse reporting bytes.** The modes are tracked; no reports are sent yet.
- A **conformance corpus** of ≥ 300 input → expected-screen cases. There are
  roughly 200 emulation assertions today, held in-source.
- **Fuzz scale** of 10⁶ random bytes. Currently about 10⁵ per run.
- Hand verification of `vim`, `htop`, `less`, `tmux` and `lazygit` on screen.
  Headless CI covers clear, SGR, the alternate screen, wrapping and wide
  characters.

**Evidence:** 968 checks pass; `--resize-test` proves the shell and the view
agree on the grid; `Scripts/emulation-checks.sh` drives real shell output through
the parser, and CI asserts the result without a window.

**Non-goals:** ligatures, image protocols, Kitty keyboard protocol.

### M1.x — Tabs and splits ✅

A terminal with one pane is a toy. Broken out of M1 deliberately, so that the
emulation core could be finished and verified first — and now the natural next
step, since M2 has landed.

**Done first, because it blocked all of this:** a shell can be started at any
time. `forkpty()` forks the application and is only safe before AppKit starts, so
nothing could open a second shell — not a new window, not a tab, not a split.
Shells are started with `openpty()` + `posix_spawn()` (ADR-0007), the first window
is made by the same code path as every other, and closing a window is no longer a
dead end: `⌘N` and a Dock click both bring one back, with a live shell in it.

**And a second one, found by asking four shells at once:** every shell the
application started ran **without a controlling terminal**. The prompt worked,
input echoed, commands ran — and Ctrl+C, Ctrl+Z and job control did nothing,
because the terminal had no foreground process group for a signal to be delivered
to. ADR-0007's file action could not claim one: POSIX runs file actions before
the session is created, so the open happened in the parent's session, where
claiming a terminal is not possible. The claim now lives in a helper program that
`posix_spawn` execs and that execs the shell in turn (ADR-0008). This is the M1.x
test earning its keep before the feature it was written for even exists: the
shells that look correct cannot answer the question, and the witness that can is
`/bin/sleep`, which never touches its terminal.

**Done**
- **Tabs**, with a visible tab strip, each tab holding its own panes, and a title
  that follows the focused shell — `⌘⇧T`, `⌘⇧W`, `⌘⇧[` / `⌘⇧]`. The per-tab
  **unread badge** followed in M3 (a dot while a tab prints in the background);
  its finished-command form needs `OSC 133` and stays in M4.
- **Horizontal and vertical splits** — `⌘D` and `⌘⇧D`, closed with `⌘W`, resized
  with the window.
- **Focus follows a click**, and `⌘[` / `⌘]` move it between panes.
- Each pane owns an independent shell; the view draws the focused model.

**Acceptance:** four panes, each running a different program, resized and closed
independently, with no shared mutable state between them. — met: `make
split-test` reports `panes=4 … jobControl=1 … closed=3 sameShells=1`.

### M2 — Settings and configuration ✅

Settings cannot be added late. Live preview means the renderer must be a
function of configuration rather than of a hardcoded `Theme`, so this milestone
landed before the renderer is rewritten — otherwise that rewrite is paid for
twice.

**Delivered**

- `Configuration`: a `Codable` value type with documented defaults, validated on
  load. Loading is total — a missing file is the defaults, a malformed one is
  the defaults plus a warning, a wrong-typed field falls back per field, and an
  unknown key is ignored. See
  [ADR-0006](adr/0006-configuration-as-a-validated-json-file.md).
- Plain JSON at `~/Library/Application Support/Nymbra/config.json`, overridable
  with `$NYMBRA_CONFIG` so tests and CI never touch a real user's settings.
- A settings window (`SettingsWindow.swift`) with tabs for Appearance, Colours,
  Behaviour, Keyboard and Shell, and a **live preview** that draws with the same
  `Theme` and palette the terminal does. Changes apply to the open terminal as
  they are made; saving is debounced.
- `Palette` in the UI-free core: eight presets, per-colour overrides, WCAG
  contrast arithmetic and the xterm 256-colour table. Only the `CGColor`
  conversion lives in the app (`Theme`).
- `Selection`: click, double-click, triple-click and drag, with the text
  extraction in the core, so copy is testable without a window.
- `Command`/`Shortcut` in `NymbraInput`: one list of application commands read by
  *both* the menu bar and the settings window, so an advertised shortcut cannot
  drift from a honoured one. Shortcut parsing is strict and duplicates are
  refused at the moment they are typed.
- `--theme-test` and `--menu-test`: the palettes and the menu bar printed as text,
  for the same reason `--screen-test` exists.

| Setting | Detail |
|---|---|
| Appearance | Preset, font family and size, with a live preview |
| Colours | Presets — dark (Dark, Ember, Fern, Violet), light (Light, Paper, Dawn), High contrast — plus per-colour overrides |
| Behaviour | Cursor style and blink, scrollback size, confirm before closing a session that is still running |
| Keyboard | The default shortcuts, shown in full, and every one of them remappable |
| Shell | The default shell, read from `/etc/shells`, defaulting to `$SHELL` |
| Reset | Restore the original settings, as a diff rather than a silent wipe |

**Fixed in this milestone: legibility.** The first palette was the traditional
xterm one, whose blue is RGB(0,0,238) — 2:1 against a dark background. `ls -G`
and `ls -l` print directories in exactly that blue, so the filenames looked
*missing* rather than dim. Two changes: every colour in every preset now clears
4.5:1 (WCAG AA) against its own background, and `Palette.readable(_:on:)` lifts
any foreground a program chooses for itself until it can be read, which is what
protects `LS_COLORS`, `git` and true-colour output. `SGR 8` (conceal) and `SGR 2`
(faint) opt out, because hiding and dimming are what those codes are *for*.

**Owed — tracked here rather than quietly dropped**
- The **command palette** row in the feature catalogue. Not in this milestone.
- Accessibility: VoiceOver labels and full keyboard traversal of the settings
  window are not written yet.
- The settings window has been verified headlessly and by hand on one machine; it
  has no snapshot tests.

**Acceptance:** change the font size and theme in the settings window and watch
an open terminal update immediately; quit, relaunch, and find the settings
intact; delete the config file and start on defaults; hand-edit it into an
invalid state and start on defaults *with a warning*, rather than failing to
launch. All four hold; the first is what the live preview is for.

**Testable headlessly?** Yes, and that is where the work went. The settings
model, the colour tables, the selection model and the shortcut table are all
UI-free and asserted in `NymbraCheck`; the window and the menu bar are thin, and
both can print themselves (`--menu-test`, `--theme-test`) for CI to read.

See [ADR-0006](adr/0006-configuration-as-a-validated-json-file.md) for why the
file is JSON, why loading can never fail, and why the model is UI-free.

### M3 — Metal renderer, reflow, mouse 🔨 *in progress*

**Done**
- **Text reflow on resize** — the live screen and history rewrap; soft-wrapped
  rows are rejoined before they are recut, so a resize does not leave a paragraph
  half on one row.
- **Mouse reporting** for the modes already tracked — 1000/1002/1003, in the X10
  and SGR encodings.
- **Search in scrollback** — a find overlay, next/previous, matches highlighted
  in history and on the live screen.

**Remaining**
- Glyph atlas rasterised once per (font, size, style) via CoreText
- One instanced draw call per frame; damage tracking when worthwhile
- 60 fps scrolling of a full screen at 4K; steady-state idle near 0% CPU
- Undercurl, and the block cursor and selection highlight drawn by the GPU

**Acceptance:** a full-screen `yes` flood stays at frame rate with flat memory;
CoreText drawing is removed, and `TermView` is a pure function of the model.
See [ADR-0004](adr/0004-coretext-first-metal-later.md).

### M4 — Shell integration and attention ⏳ *the differentiator*

Where Nymbra becomes something other terminals are not.

See [ADR-0009](adr/0009-shell-integration-without-touching-dotfiles.md) for why
Nymbra loads the integration itself instead of adding a line to your dotfiles.

**Scope**
- **OSC 133** shell integration: prompt start, command start, command
  executed, exit status — the marks are parsed into `ShellMark` events, a bundled
  zsh integration emits them, and `behaviour.shellIntegration` turns it on for
  shells started afterwards (so far `A`/`C`/`D`: see the changelog for why `B`
  waits, and `bash`/`fish` with it)
- Per-tab **unread badge** when a command finishes in a background tab — the
  *output* form has landed (a tab marks itself with a dot while printing in the
  background, cleared by looking at it); the *finished* form needs the `OSC 133`
  above, so it needs the prompt boundaries first
- **Notification** when a long command finishes; click to focus the tab
- **Command timeline**: searchable history of every command, its exit status,
  duration and directory, stored locally
- A quiet **"what needs you"** digest — three things, not a firehose

**Acceptance:** run a 60-second build in a background tab; the tab badges, a
notification fires, and the command appears in the timeline with its exit code.
Fully local; no network calls.

### M5 — Sessions 🔜

**Scope**
- PTY host that outlives the window, so a crash or quit does not kill work
- Restore tabs, splits, working directories and scrollback on relaunch

**Acceptance:** `kill -9` the app during a build; relaunch and find the build
still running with its output intact.

### M6 — Distribution 🔜

**Scope**
- ~~An application bundle, with an icon~~ ✅ `make app`
- Universal binary (arm64 + x86_64)
- Codesigning, notarization, hardened runtime
- **A stable identity, which is not only about Gatekeeper.** macOS records Full
  Disk Access and the Desktop/Documents/Downloads grants against a *code
  signature*: an ad-hoc-signed build is a different program every time it is
  rebuilt, so the grant does not survive, and the prompt that would explain why
  never appears. A terminal that cannot read the user's files is not a terminal,
  so the `Info.plist` usage strings for the folders it asks for belong here too.
- Tauri-free updater against GitHub Releases
- `brew install --cask nymbra`
- `THIRD_PARTY_NOTICES` and an in-app open-source licences screen

**Done so far:** `Scripts/make-app.sh` assembles `Nymbra.app` from the release
binary with a generated `Info.plist` and an icon drawn by
`Scripts/make-icon.swift`; `make app`, `make launch`, `make install` and
`make dist` are wired up. What remains is everything a *downloaded* copy needs:
a universal binary, signing, notarisation, and a DMG.

**Acceptance:** a fresh Mac downloads the DMG and opens it without a Gatekeeper
warning.

## Feature catalogue

Priority: **P0** required for v0.1 · **P1** v0.1 if cheap · **P2** later.

### Emulation

| Feature | Priority | Milestone |
|---|---|---|
| Cursor movement, visibility, save/restore | P0 | M1 |
| SGR colour (16/256/truecolour) | P0 | M1 |
| Alternate screen | P0 | M1 |
| Erase / insert / delete | P0 | M1 |
| Scroll region and DECAWM | P0 | M1 |
| Resize with content preservation | P0 | M1 |
| Bracketed paste | P0 | M1 |
| Mouse reporting | P1 | M1 |
| Ligatures | P2 | M3 |
| Image protocols (sixel / Kitty) | 💭 | — |
| Kitty keyboard protocol | 💭 | — |

### Shell and attention

| Feature | Priority | Milestone |
|---|---|---|
| OSC 133 integration scripts (`zsh`/`bash`/`fish`) | P0 | M4 |
| Exit-status indicators in the gutter | P0 | M4 |
| Background-tab unread badge | P0 | M4 |
| Long-command notifications | P1 | M4 |
| Command timeline (local, searchable) | P1 | M4 |
| "What needs you" digest | P2 | M4 |
| Jump to previous/next prompt | P1 | M1 (data) / M4 (UX) |

### Application

| Feature | Priority | Milestone |
|---|---|---|
| Tabs | P0 | M1.x |
| Splits (horizontal/vertical) | P0 | M1.x |
| Settings window with live preview | P1 | ✅ M2 |
| Theme presets: dark, light, high contrast | P1 | ✅ M2 |
| Theme presets: ember, fern, violet, paper, dawn | P1 | ✅ M2 |
| Font family and size, with a preview | P1 | ✅ M2 |
| Cursor style and blink | P1 | ✅ M2 |
| Scrollback size | P1 | ✅ M2 |
| Confirm before closing a running session | P1 | ✅ M2 |
| Default shell selection | P1 | ✅ M2 |
| Remappable keybindings | P1 | ✅ M2 |
| Config file | P1 | ✅ M2 |
| Reset to defaults | P1 | ✅ M2 |
| Legible colours for program-chosen output | P0 | ✅ M2 |
| Command palette | P1 | M3 |
| Full screen | P2 | ✅ M2 |
| Search in scrollback | P1 | M3 |
| Text selection and copy | P0 | ✅ M2 |
| Multiple windows | P2 | M5 |
| VoiceOver / accessibility | P1 | M2 |

### Non-functional

| Requirement | Priority | Milestone |
|---|---|---|
| No network calls of any kind | P0 | always |
| Input latency below one frame | P0 | M1 |
| Idle CPU near zero | P0 | M3 |
| Total memory below 100 MB with 10 tabs | P1 | M3 |

## Differentiators

The only three claims that matter. If a feature does not serve one of these,
it is probably out of scope.

1. **It remembers.** Sessions, scrollback and command history survive quits and
   crashes. Reopen the laptop and your work is where you left it.
2. **It tells you what needs you.** Command boundaries, exit statuses, unread
   badges and a calm digest — instead of a wall of output you must re-read.
3. **It is quiet and native.** Instant launch, no account, no telemetry, no
   embedded browser, and it looks like a macOS application.

## Explicitly out of scope

- Windows and Linux ports.
- A plugins or scripting runtime.
- AI chat inside the terminal. We integrate with agent CLIs; we do not become one.
- Any cloud service, sync, account or telemetry.
- Feature-for-feature parity with iTerm2.

## Release criteria for v0.1

- [ ] M1.x, M3, M4 and M5 complete (M0–M2 are done)
- [ ] `vim`, `htop`, `tmux`, `lazygit`, `ssh` verified working
- [ ] Fuzzer clean
- [ ] `make check` green on a clean clone
- [ ] README, ARCHITECTURE, ROADMAP and CHANGELOG accurate
- [ ] MIT licence and third-party notices in place
- [ ] Notarized universal DMG, Homebrew cask, updater feed

## Open questions

| Question | Notes |
|---|---|
| Should the PTY host be a separate process? | Needed for M5; keep PTY behind `NymbraCore`'s interface so it is a swap |
| Do we bundle a Nerd Font, or use the user's? | A native app can resolve user fonts via CoreText, so bundling may be unnecessary |
| Do we read Ghostty-style config? | Familiarity versus taking on someone else's format. Our own documented JSON is the answer for M2; revisit once it is stable |
| Scrollback in memory or on disk? | On disk unlocks M5 restore at the cost of complexity |
