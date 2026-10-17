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
| `behaviour` | Cursor, scrollback, confirm-on-close |
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
    "confirmBeforeClosingRunningSession": true
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