# ADR-0003 — A built-in test harness instead of XCTest

**Status:** Accepted · 2026-10-17

## Context

`swift test` needs `XCTest` or `swift-testing`. Neither ships with the Xcode
**Command Line Tools**; both require a full Xcode installation (~15 GB). Nymbra
targets a Command Line Tools-only environment deliberately (ADR-0001
consequences, and a 15 GB prerequisite for a contributor is a real cost).

Testing also has to run *identically* locally and in CI. GitHub Actions macOS
runners have full Xcode, so an XCTest suite would pass in CI and fail on a
contributor's machine with only the Command Line Tools — the worst possible
arrangement.

Separately, the work ahead is VT conformance: thousands of `input bytes →
expected screen` pairs. That wants a runner that can stream fixtures, not an
assertion library designed for a handful of unit tests.

## Decision

Tests live in an executable target, `NymbraCheck`, built on a small in-repo
harness (`Harness.swift`). It is run by `make test` and by CI. No test framework
is a dependency.

## Consequences

**Good**
- `make check` works on a clean machine with only the Command Line Tools.
- Local and CI behaviour cannot diverge.
- The harness is ours, so fixture-driven conformance and fuzzing can be added
  without fighting a framework.
- It has already earned its keep: it caught an OSC parsing bug on first run.

**Bad**
- No IDE test integration, no `.xctest` bundles, no coverage from `xcodebuild`.
- Roughly 60 lines of harness to maintain.

**Revisit if**
- Full Xcode becomes a stated prerequisite, or contributors need IDE
  integration. Migration is mechanical: the suites are plain functions.

**Related:** the same reasoning makes GPL-licensed emulators off-limits as a
source to copy. Nymbra's emulation is written from ECMA-48 and the `xterm`
control-sequence reference, so the code remains unambiguously MIT.
