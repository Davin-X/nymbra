# ADR-0006 — Configuration is one validated JSON file, with a UI-free model

**Status:** Accepted · 2026-10-17

## Context

Settings are not a polish item. A terminal with a fixed font, no theme choice
and no way to change the shell is one a beginner cannot make comfortable and an
experienced user will not keep, which is why settings are a milestone (M2) and
not a footnote.

Three decisions come with that, each easy to get wrong in a way that is
expensive later:

1. **Where settings live.** A bespoke binary format is opaque; a plist is
   awkward to hand-edit; `UserDefaults` hides the file and makes "reset" murky.
2. **What happens when the file is wrong.** A hand-edited config with a typo
   must not stop the app from launching. A terminal is the tool people use to
   repair a broken machine; one that refuses to start is worse than useless.
3. **Where the model lives.** If views read settings directly, settings stop
   being testable without a window, which breaks principle 4.

## Decision

- Configuration is **one JSON file** at
  `~/Library/Application Support/Nymbra/config.json`. The format is documented
  and part of the public surface: stable, hand-editable, diffable.
- The settings **model is UI-free** (`NymbraCore`), `Codable`, with a documented
  default for every field. Views read an immutable snapshot of it.
- Loading is **total**. A missing file means defaults. An unreadable or invalid
  file means defaults *plus a visible warning*, never a failed launch. Unknown
  keys are ignored, so a file written by a newer version does not break an older
  one.
- **Reset** writes the defaults back and reports what changed, rather than
  silently wiping a file the user may have edited.

## Consequences

**Good**
- Settings are testable headlessly: round-trip, validation, forward
  compatibility and reset are assertions rather than manual checks.
- Live preview needs no restart: the model changes, views re-read a snapshot.
- The Metal renderer (M3) is written once, against configuration, instead of
  being rewritten when settings arrive.

**Bad**
- A file, a decoder and a validator is more code than `UserDefaults` would be.
- We own a format, and with it the obligation to keep it stable.

**Alternatives considered**
- `UserDefaults` — least code, but hides the file, and reset means deleting keys
  one by one and hoping none is missed.
- A plist — native, but verbose to hand-edit and noisy in diffs.
- Reading Ghostty's config format — familiar to some users, at the cost of
  inheriting another project's semantics along with its mistakes.
