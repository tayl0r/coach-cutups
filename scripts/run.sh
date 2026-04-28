#!/usr/bin/env bash
# Build the Coach Cutups app and launch the freshly-built binary,
# replacing any running instance. Run from the repo root or anywhere —
# the script cd's to the project directory itself.
set -euo pipefail

cd "$(dirname "$0")/.."

# (Re)generate the .xcodeproj from project.yml when XcodeGen is installed
# and project.yml is newer than the project's pbxproj. Cheap to skip
# silently if XcodeGen isn't present.
if command -v xcodegen >/dev/null 2>&1 \
   && [ project.yml -nt VideoCoach.xcodeproj/project.pbxproj ]; then
  echo "==> regenerating Xcode project"
  xcodegen generate
fi

echo "==> building"
xcodebuild \
  -project VideoCoach.xcodeproj \
  -scheme VideoCoach \
  -configuration Debug \
  build \
  | grep -E "error:|warning:|\*\* BUILD" || true

# Resolve the BUILT_PRODUCTS_DIR (DerivedData path varies per machine).
APP=$(xcodebuild \
  -project VideoCoach.xcodeproj \
  -scheme VideoCoach \
  -configuration Debug \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+BUILT_PRODUCTS_DIR =/ {print $2; exit}')/VideoCoach.app

# Kill any existing instance so we definitely launch the new build.
pkill -x VideoCoach 2>/dev/null || true

echo "==> launching $APP"
open "$APP"
