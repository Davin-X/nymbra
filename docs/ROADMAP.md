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
| Scrollback buffer | ⚠️ modelled (10 000 lines) but **no way to view it yet** |
| Keyboard: Enter, Backspace, delete, arrows, control keys | ✅ arrows honour DECCKM; meta via Option; Shift-Tab |
| Function keys F1–F12 | ❌ **not mapped** |
| UTF-8 across read boundaries, wide characters | ✅ |
| Combining marks | ✅ asserted in the unit suite |
| Emoji and grapheme clusters (ZWJ sequences) | ⚠️ emoji width detected; clusters are not grouped into one cell |
| Robustness under malformed/long sequences | ⚠️ parser is total and fuzzed at ~10⁵ bytes; target is 10⁶ |

### App features

| Requirement | State | Milestone |
|---|---|---|
| Copy/paste | ⚠️ paste works (bracketed); **no selection, so no copy** | M2 |
| Search in scrollback | ❌ | M3 |
| Tabs and split panes | ❌ | M1.x (P0) |
| Configurable font, colours, keybindings | ❌ `Theme` is hardcoded | M2 |
| Shell integration: prompt/command boundaries, notifications | ⚠️ bell sounds; `OSC 133` not parsed | M3 |
| Session recovery/persistence | ❌ | M4 |

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

**Owed — tracked here rather than quietly dropped**
- Text **reflow** on resize. Resize preserves content but does not rewrap;
  moved to M2 deliberately.
- **Mouse reporting bytes.** The modes are tracked; no reports are sent yet.
- A **conformance corpus** of ≥ 300 input → expected-screen cases. There are
  roughly 100 emulation assertions today, held in-source.
- **Fuzz scale** of 10⁶ random bytes. Currently about 10⁵ per run.
- Hand verification of `vim`, `htop`, `less`, `tmux` and `lazygit` on screen.
  Headless CI covers clear, SGR, the alternate screen, wrapping and wide
  characters.

**Evidence:** 169 checks pass; `make screen-test` drives the parser with real
shell output, and CI asserts the result without a window.

**Non-goals:** ligatures, image protocols, Kitty keyboard protocol.

### M2 — Metal renderer, reflow, mouse 🔜

**Scope**
- Glyph atlas rasterised once per (font, size, style) via CoreText
- One instanced draw call per frame; damage tracking when worthwhile
- 60 fps scrolling of a full screen at 4K; steady-state idle near 0% CPU
- Block cursor, selection highlight, undercurl
- **Text reflow on resize** — carried over from M1, which preserves content but
  does not rewrap
- **Mouse reporting bytes** for the modes already tracked (1000/1002/1003,
  x10 and SGR encodings)

**Acceptance:** a full-screen `yes` flood stays at frame rate with flat memory;
CoreText drawing is removed, and `TermView` is a pure function of the model.
See [ADR-0004](adr/0004-coretext-first-metal-later.md).

### M3 — Shell integration and attention ⏳ *the differentiator*

Where Nymbra becomes something other terminals are not.

**Scope**
- **OSC 133** shell integration: prompt start, command start, command
  executed, exit status — emitted by a `zsh`/`bash`/`fish` snippet
- Per-tab **unread badge** when a command finishes in a background tab
- **Notification** when a long command finishes; click to focus the tab
- **Command timeline**: searchable history of every command, its exit status,
  duration and directory, stored locally
- A quiet **"what needs you"** digest — three things, not a firehose

**Acceptance:** run a 60-second build in a background tab; the tab badges, a
notification fires, and the command appears in the timeline with its exit code.
Fully local; no network calls.

### M4 — Sessions 🔜

**Scope**
- PTY host that outlives the window, so a crash or quit does not kill work
- Restore tabs, splits, working directories and scrollback on relaunch

**Acceptance:** `kill -9` the app during a build; relaunch and find the build
still running with its output intact.

### M5 — Distribution 🔜

**Scope**
- Universal binary (arm64 + x86_64)
- Codesigning, notarization, hardened runtime
- Tauri-free updater against GitHub Releases
- `brew install --cask nymbra`
- `THIRD_PARTY_NOTICES` and an in-app open-source licences screen

**Acceptance:** a fresh Mac downloads the DMG and opens it without a Gatekeeper
warning.

### M6 — Configuration and polish 💭

Config file, remappable keybindings, themes, font picker, `Ghostty`-style
config familiarity.

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
| Scrollback with search | P1 | M2 |
| Ligatures | P2 | M6 |
| Image protocols (sixel / Kitty) | 💭 | — |
| Kitty keyboard protocol | 💭 | — |

### Shell and attention

| Feature | Priority | Milestone |
|---|---|---|
| OSC 133 integration scripts (`zsh`/`bash`/`fish`) | P0 | M3 |
| Exit-status indicators in the gutter | P0 | M3 |
| Background-tab unread badge | P0 | M3 |
| Long-command notifications | P1 | M3 |
| Command timeline (local, searchable) | P1 | M3 |
| "What needs you" digest | P2 | M3 |
| Jump to previous/next prompt | P1 | M1 (data) / M3 (UX) |

### Application

| Feature | Priority | Milestone |
|---|---|---|
| Tabs | P0 | M1 |
| Splits (horizontal/vertical) | P0 | M1 |
| Command palette | P1 | M6 |
| Search in scrollback | P1 | M2 |
| Themes, dark + light | P1 | M6 |
| Font picker (system fonts + user Nerd Fonts) | P1 | M6 |
| Full screen | P2 | M6 |
| Config file | P1 | M6 |
| Remappable keybindings | P1 | M6 |
| Multiple windows | P2 | M4 |

### Non-functional

| Requirement | Priority | Milestone |
|---|---|---|
| No network calls of any kind | P0 | always |
| Input latency below one frame | P0 | M1 |
| Idle CPU near zero | P0 | M2 |
| Total memory below 100 MB with 10 tabs | P1 | M2 |
| VoiceOver / accessibility | P1 | M6 |

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

- [ ] M1 and M3 complete
- [ ] `vim`, `htop`, `tmux`, `lazygit`, `ssh` verified working
- [ ] Fuzzer clean
- [ ] `make check` green on a clean clone
- [ ] README, ARCHITECTURE, ROADMAP and CHANGELOG accurate
- [ ] MIT licence and third-party notices in place
- [ ] Notarized universal DMG, Homebrew cask, updater feed

## Open questions

| Question | Notes |
|---|---|
| Should the PTY host be a separate process? | Needed for M4; keep PTY behind `NymbraCore`'s interface so it is a swap |
| Do we bundle a Nerd Font, or use the user's? | A native app can resolve user fonts via CoreText, so bundling may be unnecessary |
| Do we read Ghostty-style config? | Familiarity vs. taking on someone else's format |
| Scrollback in memory or on disk? | On disk unlocks M4 restore at the cost of complexity |
