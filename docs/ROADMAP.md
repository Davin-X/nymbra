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

## Milestones

### M0 — Foundation ✅

PTY, native window, CoreText grid, keyboard input, live resize, test harness
and CI.

**Acceptance (met):** `make check` passes; `--pty-test` runs a login shell;
the architecture guard passes.

### M1 — VT emulation ⏳ *next*

The milestone that makes this a terminal rather than a demo.

**Scope**
- Table-driven parser: ground, escape, CSI, OSC, DCS, charset, SOS/PM/APC
- Cursor: position, visibility, save/restore, movement, tab stops
- SGR: 16-colour, 256-colour, truecolour; bold/italic/underline/reverse/strike
- Screen: erase (line/screen), insert/delete (char/line), scroll region,
  wrapping (DECAWM), origin mode
- Alternate screen (`ESC [?1049h/l`) — required by `vim`, `less`, `htop`
- Bracketed paste, mouse reporting enums, focus reporting
- Resize that preserves content and reflows sanely

**Acceptance**
- `vim`, `htop`, `less`, `git log`, `tmux` and `lazygit` render correctly
- A conformance corpus of ≥ 300 input → expected-screen cases passes
- A fuzzer runs 10⁶ random byte sequences with no crash, hang or unbounded growth

**Non-goals:** ligatures, image protocols, Kitty keyboard protocol.

### M2 — Metal renderer 🔜

**Scope**
- Glyph atlas rasterised once per (font, size, style) via CoreText
- One instanced draw call per frame; damage tracking when worthwhile
- 60 fps scrolling of a full screen at 4K; steady-state idle near 0% CPU
- Block cursor, selection highlight, undercurl

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
