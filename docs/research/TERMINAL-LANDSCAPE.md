# The terminal landscape, and where Nymbra fits

A working brief, not a survey: what each serious terminal is best at, what
the industry now treats as table stakes, and what that means for Nymbra's
next steps. November 2026.

## The field

| Terminal | Core idea | What it gets right | What it costs |
|---|---|---|---|
| **Terminal.app** | The system default | Native, very low input latency, IME and accessibility done properly, secure keyboard entry | Dated look, no splits, weak modern protocol support |
| **iTerm2** | The power-user Mac terminal | Shell integration marks, triggers, profiles, `tmux -CC`, session restore | Heavy, settings sprawl, renderer latency |
| **Ghostty** | Native *and* fast, zero config | Shared Zig core (`libghostty`) with a real AppKit/SwiftUI app; Metal renderer; Quick Look, secure input, window restore, quick terminal | Config is a text file; few "smart" features |
| **Kitty** | Protocols first | Defined the keyboard and graphics protocols everyone else adopts; kittens (scriptable extensions) | Not native-feeling on macOS |
| **WezTerm** | Programmable multiplexer | Lua config, built-in mux with remote domains | Lua is a barrier; heavier |
| **Alacritty** | Minimal and GPU-fast | Throughput, simplicity | No tabs/splits by design |
| **Warp** | The terminal as an app | **Blocks** (each command + output is an object), a real text editor for input, rich UI | Account/AI-centric, not a plain terminal, closed source |

## Table stakes in 2026

Things a person notices within an hour if they are missing:

1. **Input methods (IME)**: CJK input, dead keys, press-and-hold accents and
   the emoji picker work through `NSTextInputClient`.
2. **Working-directory awareness (OSC 7)**: tab names, "new tab here", and
   session restore all hang off it.
3. **Synchronized output (DEC mode 2026)**: no tearing in Neovim, Helix or lazygit.
4. **The kitty keyboard protocol**: modern editors can tell ⇧↩ from ↩.
5. **True colour, undercurl, OSC 8 hyperlinks, OSC 52 clipboard**.
6. **Input latency under ~10 ms**, measured rather than claimed (Typometer).
7. **Signed, notarized, auto-updating**, with secure keyboard entry.

## Where Nymbra is different

Nymbra already has three of Warp's ideas without Warp's weight: OSC 133
command marks, per-tab attention, and a bounded inbox. The opportunity is to
be **Ghostty-native and Warp-aware**:

- **Blocks without a custom shell**: command boundaries come from OSC 133, so
  "copy this output", "jump to previous prompt" and "rerun" work in any
  zsh/bash/fish with integration on, and nothing breaks with it off.
- **Calm attention**: a short list of what needs you, not a stream of
  notifications. Nobody else does this well.
- **Zero dependencies, readable code**: an auditable terminal.

## Design language (from `design/nymbra-ui-concept.html`)

- One continuous dark surface: the title bar, tab strip, path bar and terminal
  read as one object, not stacked system chrome.
- The window title and tab names come from **where you are** (folder or
  running program), never the app name.
- A thin **path bar** under the tabs: `⌂ › ~/src/nymbra`, then on the right
  `● shell running · zsh · ⌘⇧P commands`.
- Quiet chips: flat, the selected one raised a step; a dot for unread.
- Generous padding; a tinted (not pure black) canvas; a thin scrollbar.

## Sequencing

1. **Look and know where you are**: OSC 7, tab and window titles, unified
   chrome, path bar, padding and canvas. *(in progress)*
2. **Input correctness**: IME, synchronized output, kitty keyboard.
3. **Blocks**: prompt navigation (⌘↑/⌘↓), copy last output, command timeline.
4. **Metal renderer**, with latency and fps budgets in CI.
5. **Sessions**: restore tabs, splits, folders and scrollback.
6. **Ship**: universal, signed, notarized, updater, Homebrew cask.

## Sources

- [About Ghostty](https://ghostty.org/docs/about) and [Zig and SwiftUI](https://mitchellh.com/writing/zig-and-swiftui)
- [How Warp works](https://www.warp.dev/blog/how-warp-works), [Warp blocks](https://docs.warp.dev/features/blocks)
- [kitty keyboard protocol](https://sources.debian.org/src/kitty/0.46.1-1/docs/keyboard-protocol.rst)
- [Terminal latency (Dan Luu)](https://danluu.com/term-latency/), [Measuring terminal latency](https://dev.to/lkhrs/measuring-terminal-latency-26m7)
