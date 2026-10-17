#!/bin/bash
# Architecture guard.
#
# The core targets must never depend on a UI framework. If this fails, the
# dependency direction in docs/ARCHITECTURE.md has been violated and the
# layered design is no longer real.
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='^import[[:space:]]+(AppKit|SwiftUI|Metal|MetalKit|CoreText|QuartzCore)'
violations=$(grep -rnE "$PATTERN" Sources/NymbraCore Sources/NymbraInput Sources/CPTY Sources/NymbraSpawn 2>/dev/null || true)

if [ -n "$violations" ]; then
  echo "Architecture violation: UI framework imported by a core target."
  echo "Only Sources/Nymbra may import AppKit/Metal/CoreText."
  echo
  echo "$violations"
  exit 1
fi

# The spawn helper is exec'd for every shell, so it stays a C program with no
# imports of ours at all: no NymbraCore, no Foundation, nothing that would make
# starting a terminal depend on starting a runtime first (ADR-0008).
if grep -rnE '^#include[[:space:]]+"(Nymbra|Foundation)' Sources/NymbraSpawn 2>/dev/null; then
  echo "Architecture violation: the spawn helper pulled in more than libc."
  exit 1
fi

echo "architecture OK: core targets are UI-free"
