# ADR-0004 — CoreText first, Metal later

**Status:** Accepted · 2026-10-17

## Context

A terminal renderer can be built on CoreText/CoreGraphics, on Metal, or on both
in sequence. Metal is where this has to end up: a glyph atlas and instanced
drawing are what make scrolling a flood of output smooth, and CoreText drawing
per line will not hold at high frame rates.

But starting with Metal means debugging GPU pipelines, atlases and shaders at
the same time as debugging an emulator that does not yet work.

There is also an environment constraint: without full Xcode there is no offline
`metal` compiler. Shaders can be compiled at runtime from source, which works
but is extra machinery to stand up early.

## Decision

Ship M1 (VT emulation) on CoreText. Replace the renderer with Metal in M2,
behind an unchanged boundary.

## Consequences

**Good**
- M1's correctness — the actual risk — is exercised without GPU complexity.
- CoreText gives authoritative cell metrics, which the Metal renderer will reuse.
- No full-Xcode requirement while the emulator is being built.

**Bad**
- CoreText drawing must be deleted later; some effort is written off.
- Performance will be embarrassing until M2. Acceptable: nothing is shipped yet.

**The boundary that makes this cheap**
`TermView` is a pure function of the screen model plus cell metrics. The Metal
renderer is a drop-in replacement for that function, not a redesign. Invariant 1
in `docs/ARCHITECTURE.md` exists to keep it that way.
