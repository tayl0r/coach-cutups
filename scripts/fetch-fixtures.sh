#!/usr/bin/env bash
#
# Download fixture binaries from the GitHub Release listed in
# fixtures/manifest.json. Skips downloads when an existing local file
# already matches the recorded SHA256.
#
# Usage: ./scripts/fetch-fixtures.sh
# Requires: bash, curl, shasum (or sha256sum), jq.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/fixtures/manifest.json"
FIX_DIR="$REPO_ROOT/fixtures"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to parse fixtures/manifest.json" >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Ubuntu: sudo apt-get install jq" >&2
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  echo "manifest not found: $MANIFEST" >&2
  exit 1
fi

# Pick a SHA256 implementation that exists on the host.
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "no shasum/sha256sum on PATH" >&2
    exit 1
  fi
}

release_tag=$(jq -r '.releaseTag' "$MANIFEST")
url_base=$(jq -r '.downloadUrlBase' "$MANIFEST")
names=$(jq -r '.fixtures | keys[]' "$MANIFEST")

for name in $names; do
  expected_sha=$(jq -r --arg n "$name" '.fixtures[$n].sha256' "$MANIFEST")
  out="$FIX_DIR/$name"

  if [ -f "$out" ]; then
    actual=$(sha256 "$out")
    if [ "$actual" = "$expected_sha" ]; then
      echo "ok  $name (cached)"
      continue
    fi
    echo "stale $name (sha mismatch — refetching)"
  fi

  url="$url_base/$release_tag/$name"
  echo "get $name from $url"
  mkdir -p "$FIX_DIR"
  # --connect-timeout: bail if no TCP handshake in 30s (CDN unreachable).
  # --max-time:        bail on any single transfer that runs over 5 min.
  curl -fLsS --connect-timeout 30 --max-time 300 -o "$out" "$url"

  actual=$(sha256 "$out")
  if [ "$actual" != "$expected_sha" ]; then
    echo "SHA mismatch for $name: expected $expected_sha got $actual" >&2
    exit 1
  fi
  echo "ok  $name (downloaded)"
done

echo "all fixtures present and verified"
