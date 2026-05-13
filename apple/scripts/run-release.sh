#!/usr/bin/env bash
# Build and run Coach Cutups in Release configuration (optimized, no
# debug symbols stripped from the bundle but `-O` instead of `-Onone`).
# Thin wrapper around run.sh.
set -euo pipefail
exec "$(dirname "$0")/run.sh" Release
