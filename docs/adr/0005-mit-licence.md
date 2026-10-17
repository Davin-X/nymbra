# ADR-0005 — MIT licence

**Status:** Accepted · 2026-10-17

## Context

The project is intended to be public and freely usable. The realistic options:

| Licence | Effect |
|---|---|
| MIT | Permissive; anyone may use, modify, sell. Maximum adoption. |
| Apache-2.0 | Permissive plus an explicit patent grant and contribution terms. |
| GPL-3.0 | Copyleft; derivative works must also be GPL. |

Two facts shaped the decision. First, the entire dependency surface is Apple's
SDK, so there is no copyleft obligation to inherit. Second, a terminal is
infrastructure that people embed in workflows and sometimes in products;
permissive licensing removes friction.

## Decision

MIT. Copyright holder as stated in `LICENSE`.

## Consequences

**Good**
- Trivially compatible with everything; no legal review needed to use Nymbra.
- Matches most of the ecosystem (Ghostty, Alacritty, `xterm.js`).

**Bad**
- No patent grant, unlike Apache-2.0.
- Others may relicense derivatives; that is accepted.

**Related**
- Never copy code from GPL-licensed emulators such as iTerm2 or `cmux`: doing so
  would relicense this project. Emulation is implemented from specifications —
  see ADR-0001 and ADR-0003.
- No font is redistributed today. If one is bundled later it will be under the
  SIL Open Font License, with the full text in the repository and attribution in
  `THIRD_PARTY_NOTICES.md`.
