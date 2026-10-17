#!/bin/bash
# Architecture guard.
#
# The core targets must never depend on a UI framework. If this fails, the
# dependency direction in docs/ARCHITECTURE.md has been violated and the
# layered design is no longer real.
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='^import[[:space:]]+(AppKit|SwiftUI|Metal|MetalKit|CoreText|QuartzCore)'
violations=$(grep -rnE "$PATTERN" Sources/NymbraCore Sources/CPTY 2>/dev/null || true)

if [ -n "$violations" ]; then
  echo "Architecture violation: UI framework imported by a core target."
  echo "Only Sources/Nymbra may import AppKit/Metal/CoreText."
  echo
  echo "$violations"
  exit 1
fi

echo "architecture OK: core targets are UI-free"
