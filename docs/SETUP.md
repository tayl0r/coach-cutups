# Local development setup

## Prerequisites

- Rust stable (the workspace pins via `rust-toolchain.toml`).
- macOS / Linux / Windows.

## GStreamer (Phase 3+)

Recording requires GStreamer 1.24+ with the standard plugin set.

**macOS (Homebrew):**

```bash
brew install gstreamer
```

The `gstreamer` formula is a meta-package that pulls in `gst-plugins-base`, `gst-plugins-good`, `gst-plugins-bad`, `gst-plugins-ugly`, and `gst-libav`. Total install ~700 MB.

**Ubuntu / Debian:**

```bash
sudo apt-get install -y \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-tools
```

**Windows:**

```powershell
choco install gstreamer
choco install gstreamer-devel
```

After install, ensure the GStreamer `bin/` and `lib/pkgconfig` directories are on `PATH` and `PKG_CONFIG_PATH`.

**Verify the install:**

```bash
gst-launch-1.0 --version
pkg-config --modversion gstreamer-1.0
```

## Test fixtures (Phase 2+)

Real media fixtures (sports source video, webcam clip) live in a GitHub Release, not in git. Fetch them once after clone:

```bash
./scripts/fetch-fixtures.sh
```

Fixtures land in `fixtures/` (gitignored). The script verifies SHA256s against `fixtures/manifest.json` and skips downloads when the local copy already matches.
