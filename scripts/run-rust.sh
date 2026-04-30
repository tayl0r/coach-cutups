#!/usr/bin/env bash
# Build and launch the Rust port of Video Coach. Mirrors scripts/run.sh
# (which builds the legacy Swift app via xcodebuild) but for the
# Cargo-based v2 binary on branch rust-rewrite.
#
# Defaults to `cargo build --release` for snappier launches; pass
# `--debug` for a debug build or `--features media` to compile in the
# GStreamer recording machinery.
#
# After build it kills any prior video-coach-app instance and launches
# the new binary with --json-logs piped to stderr (so tracing events
# scroll in the terminal where you ran the script).
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE_FLAG="--release"
PROFILE_DIR="release"
EXTRA_FEATURES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --debug)
      PROFILE_FLAG=""
      PROFILE_DIR="debug"
      shift
      ;;
    --features)
      EXTRA_FEATURES="--features $2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--debug] [--features <list>]" >&2
      exit 1
      ;;
  esac
done

SHA=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --pretty=%s)
echo "==> building (profile=$PROFILE_DIR${EXTRA_FEATURES:+, $EXTRA_FEATURES})"
# shellcheck disable=SC2086
cargo build -p video-coach-app $PROFILE_FLAG $EXTRA_FEATURES

BIN="target/$PROFILE_DIR/video-coach-app"
if [ ! -x "$BIN" ]; then
  echo "==> build produced no binary at $BIN" >&2
  exit 1
fi

# Kill any previous instance so we definitely launch the new build.
# Brief sleep gives Slint/winit a moment to release the window + GPU
# context before the new instance grabs them.
if pkill -x video-coach-app 2>/dev/null; then
  sleep 0.3
fi

echo "==> launching $BIN"
echo "    commit: $SHA  $SUBJECT"
# Run in the foreground so Ctrl-C stops it. Prefix every log line with
# the build's short SHA so it's clear which run it came from when
# multiple terminals are scrolling.
exec "$BIN" --json-logs 2>&1
