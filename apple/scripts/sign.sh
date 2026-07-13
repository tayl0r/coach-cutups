#!/usr/bin/env bash
set -euo pipefail
APP="${1:-build/Debug/CoachCuts.app}"
IDENTITY="${VIDEO_COACH_IDENTITY:-Apple Development}"
codesign --force --deep --options runtime \
  --entitlements App/VideoCoach.entitlements \
  --sign "$IDENTITY" "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | head -10
