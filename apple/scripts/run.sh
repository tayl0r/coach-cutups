#!/usr/bin/env bash
# Build the Coach Cutups app and launch the freshly-built binary,
# replacing any running instance. Run from the repo root or anywhere —
# the script cd's to the project directory itself.
#
# Usage: run.sh [CONFIG]   # CONFIG defaults to Debug; pass Release for prod.
set -euo pipefail

CONFIG="${1:-Debug}"

cd "$(dirname "$0")/.."

# (Re)generate the .xcodeproj from project.yml when XcodeGen is installed
# and project.yml is newer than the project's pbxproj. Cheap to skip
# silently if XcodeGen isn't present.
if command -v xcodegen >/dev/null 2>&1 \
   && [ project.yml -nt VideoCoach.xcodeproj/project.pbxproj ]; then
  echo "==> regenerating Xcode project"
  xcodegen generate
fi

# Stamp App/BuildInfo.swift with the current git SHA + timestamp so the
# running app can render its own build identity in the window subtitle.
# The placeholder ("dev"/"") is restored after launch so `git status`
# stays clean — see "restore BuildInfo" block below.
SHA=$(git rev-parse --short HEAD)
DIRTY=""
if ! git diff --quiet HEAD -- ':!App/BuildInfo.swift'; then
  DIRTY="-dirty"
fi
BUILT_AT=$(date '+%Y-%m-%d %H:%M:%S')
cat > App/BuildInfo.swift <<EOF
import Foundation

/// Build-time identification baked in by \`scripts/run.sh\`. The script
/// rewrites this file with the current short git SHA and timestamp before
/// each \`xcodebuild\`, then restores the placeholder afterward so the
/// working tree stays clean. \`ContentView\` reads \`BuildInfo.commit\` and
/// renders it as the window's navigation subtitle so the user can verify
/// which build is actually running.
enum BuildInfo {
    static let commit: String = "${SHA}${DIRTY}"
    static let builtAt: String = "$BUILT_AT"
}
EOF

echo "==> building ($CONFIG)"
xcodebuild \
  -project VideoCoach.xcodeproj \
  -scheme VideoCoach \
  -configuration "$CONFIG" \
  build \
  | grep -E "error:|warning:|\*\* BUILD" || true

# Restore the placeholder so the working tree doesn't show this file as
# perpetually modified between runs. The compiled binary already captured
# the real SHA above, so restoring the source has no effect on the running
# app.
git checkout HEAD -- App/BuildInfo.swift 2>/dev/null || true

# Resolve the BUILT_PRODUCTS_DIR (DerivedData path varies per machine).
APP=$(xcodebuild \
  -project VideoCoach.xcodeproj \
  -scheme VideoCoach \
  -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR =/ {print $2; exit}')/CoachCuts.app

# Kill any existing instance so we definitely launch the new build.
# Brief sleep gives macOS a moment to release the camera/mic + finalize
# the shutdown — `open` racing pkill produces error -600.
if pkill -x CoachCuts 2>/dev/null; then
  sleep 0.4
fi

SHA=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --pretty=%s)
echo "==> launching $APP"
echo "    commit: $SHA  $SUBJECT"
open "$APP"
