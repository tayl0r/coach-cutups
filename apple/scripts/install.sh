#!/usr/bin/env bash
# Build a Release Coach Cuts and install it to /Applications, replacing
# any prior copy. Signs with the local Apple Development identity and
# strips Gatekeeper's quarantine attribute so the freshly-copied bundle
# launches without a right-click prompt.
#
# Usage: install.sh [--launch]
#   --launch   open the installed app after copying (default: don't)
set -euo pipefail

LAUNCH=0
if [ "${1:-}" = "--launch" ]; then LAUNCH=1; fi

cd "$(dirname "$0")/.."

# (Re)generate the .xcodeproj from project.yml when XcodeGen is installed
# and project.yml is newer than the project's pbxproj.
if command -v xcodegen >/dev/null 2>&1 \
   && [ project.yml -nt VideoCoach.xcodeproj/project.pbxproj ]; then
  echo "==> regenerating Xcode project"
  xcodegen generate
fi

# Stamp App/BuildInfo.swift with the current git SHA + timestamp so the
# installed app can render its build identity in the window subtitle.
# The placeholder is restored after xcodebuild so the working tree stays
# clean — see "restore BuildInfo" block below.
SHA=$(git rev-parse --short HEAD)
DIRTY=""
if ! git diff --quiet HEAD -- ':!App/BuildInfo.swift'; then
  DIRTY="-dirty"
fi
BUILT_AT=$(date '+%Y-%m-%d %H:%M:%S')
cat > App/BuildInfo.swift <<EOF
import Foundation

enum BuildInfo {
    static let commit: String = "${SHA}${DIRTY}"
    static let builtAt: String = "$BUILT_AT"
}
EOF

echo "==> building (Release)"
xcodebuild \
  -project VideoCoach.xcodeproj \
  -scheme VideoCoach \
  -configuration Release \
  build \
  | grep -E "error:|warning:|\*\* BUILD" || true

git checkout HEAD -- App/BuildInfo.swift 2>/dev/null || true

# Resolve the BUILT_PRODUCTS_DIR (DerivedData path varies per machine).
BUILT=$(xcodebuild \
  -project VideoCoach.xcodeproj \
  -scheme VideoCoach \
  -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR =/ {print $2; exit}')
SRC="$BUILT/CoachCuts.app"
DEST="/Applications/CoachCuts.app"

if [ ! -d "$SRC" ]; then
  echo "error: built bundle not found at $SRC" >&2
  exit 1
fi

# Quit any running instance so the file copy succeeds and the freshly
# installed bundle is what the next launch picks up.
if pkill -x CoachCuts 2>/dev/null; then
  sleep 0.4
fi

echo "==> installing to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# Re-sign in place so the installed bundle's signature matches its new
# location. Uses the existing sign.sh; VIDEO_COACH_IDENTITY overrides the
# default "Apple Development".
echo "==> signing"
scripts/sign.sh "$DEST" >/dev/null

# Strip the quarantine bit Finder/curl/etc add so /Applications copies
# launch without the Gatekeeper "downloaded from Internet" prompt.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

SUBJECT=$(git log -1 --pretty=%s)
echo "==> installed $DEST"
echo "    commit: $SHA  $SUBJECT"

if [ "$LAUNCH" = "1" ]; then
  echo "==> launching"
  open "$DEST"
fi
