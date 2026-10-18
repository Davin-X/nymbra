# Configuration reference

Nymbra's settings live in one hand-editable JSON file:

```
~/Library/Application Support/Nymbra/config.json
```

Set `$NYMBRA_CONFIG` to point somewhere else — that is how tests and CI run
without touching a real user's settings.

Loading is deliberately **total**: a missing file means defaults, a malformed
file means defaults plus a warning, and an unknown key from a newer version is
ignored. A terminal must never refuse to start because of its own settings file.

## Top-level sections

| Section | Description |
|---------|-------------|
| `appearance` | Font family and size |
| `colours` | Colour preset and per-colour overrides |
| `behaviour` | Cursor, scrollback, confirm-on-close, shell integration, notifications |
| `keyboard` | Keybinding overrides |
| `shell` | Login shell path |

## appearance

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `fontFamily` | string | `"Menlo"` | Must resolve to a monospaced family; falls back silently to Menlo |
| `fontSize` | number | `13.0` | Clamped to `6.0...72.0` |

## colours

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `preset` | string | `"dark"` | One of `"dark"`, `"light"`, `"highContrast"` |
| `overrides` | object | `{}` | Keys are colour names; values are `#rrggbb` |

### Colour names that may be overridden

ANSI colours (normal then bright):

- `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`
- `bright-black`, `bright-red`, `bright-green`, `bright-yellow`
- `bright-blue`, `bright-magenta`, `bright-cyan`, `bright-white`

Interface colours:

- `foreground`, `background`, `cursor`, `selection`

An unknown name or a value that is not `#rrggbb` is dropped with a warning.

## behaviour

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `cursorShape` | string | `"block"` | One of `"block"`, `"bar"`, `"underline"` |
| `cursorBlinks` | boolean | `true` | |
| `scrollbackLines` | integer | `10000` | |
| `confirmBeforeClosingRunningSession` | boolean | `true` | |
| `shellIntegration` | boolean | `false` | `OSC 133` marks; zsh only, and only for shells started afterwards |
| `notifyAfterSeconds` | number | `10` | Announce a finished command that took at least this long; `0` never |

### Shell integration

`shellIntegration` asks the shell to report what it is doing, with `OSC 133`
marks: where a prompt starts, when a command runs, and when it finishes and with
what status. zsh only, so far — a *login* bash reads `.bash_profile` and never
`.bashrc`, so it needs a different mechanism again.

Turning it on does not edit anything of yours. Nymbra starts the shell with
`ZDOTDIR` pointing at a directory of its own inside the application support
folder, whose files load your own startup files first and then a small snippet.
Turning it off stops pointing at them; there is nothing to undo.

It takes effect for shells started *after* the change. A shell already running
keeps the environment it was born with, and an environment cannot be handed to a
process that has already started — so open a tab or a window.

### Notifications

`notifyAfterSeconds` is how long a command must run before Nymbra mentions it when
it finishes — but only when you were not looking at that tab. `0` turns them off.

Ten seconds by default, because the alternative is a terminal that will not stop
talking: a shell runs dozens of commands a minute, and a notification for each is
a firehose rather than a feature. Nothing under the threshold is announced however
it went, including a command that failed fast — which is exactly what a mistyped
command does.

It needs `shellIntegration` on, for a shell started afterwards. How long a command
took is not visible in a terminal's output: a prompt and a command's output are
the same bytes, and only the shell itself knows where one ended and the other
began.

Clicking the notification brings that tab to the front. It appears even while
Nymbra is the active application, which the system does not do by default — the
case this is for is a command finishing in a tab behind the one you are looking
at. If the tab has been closed by the time you click, nothing happens.

## keyboard

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `overrides` | object | `{}` | Command name → shortcut string, e.g. `"copy": "cmd+c"` |

Shortcut syntax: `cmd+shift+t`, `ctrl+left`, `cmd+comma`. Parsing is strict —
a typo is refused rather than silently ignored.

Command names: `copy`, `paste`, `selectAll`, `clearBuffer`, `settings`,
`increaseFontSize`, `decreaseFontSize`.

## shell

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `path` | string\|null | `null` | `$SHELL`, then `/bin/zsh`. Must be an absolute path or it is ignored |

## Example

```json
{
  "appearance": {
    "fontFamily": "Menlo",
    "fontSize": 14
  },
  "colours": {
    "preset": "dark",
    "overrides": {
      "blue": "#6e8cf0"
    }
  },
  "behaviour": {
    "cursorShape": "block",
    "cursorBlinks": true,
    "scrollbackLines": 10000,
    "confirmBeforeClosingRunningSession": true,
    "shellIntegration": false,
    "notifyAfterSeconds": 10
  },
  "keyboard": {
    "overrides": {}
  },
  "shell": {
    "path": null
  }
}
```

## Forward compatibility

Unknown keys are ignored on load. If a future version changes the format in a
breaking way, the config file will be regenerated from defaults with a warning.