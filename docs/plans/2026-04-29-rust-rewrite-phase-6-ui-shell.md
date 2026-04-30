# Rust Rewrite — Phase 6: Slint UI Shell

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Stand up the first real UI for the Rust port — a Slint main window with a menu bar (File → Open Project, File → Quit), wired into the existing tokio-driven command bus and control socket, with all shutdown paths converging cleanly.

**Architecture:** Slint owns the **main thread** (winit/macOS NSApplication requirement); tokio runs on a **worker thread**. The bus `BusHandle` is shared into the Slint UI via `slint::ComponentHandle::global()`-attached state, and Slint UI events dispatch commands by spawning short-lived futures onto a `tokio::runtime::Handle` clone. Events flow back to the UI via `slint::invoke_from_event_loop`. A new `--headless` CLI flag suppresses Slint init entirely; `--control-socket=PORT` becomes orthogonal (the socket can attach to a real GUI app for debugging or a headless app for tests).

**Tech Stack:** Slint 1.8 (winit backend), `rfd` 0.14 for native file dialogs, existing tokio + tracing + bus/control_socket modules.

---

## Adversarial review changes baked in (from feature-dev:code-reviewer round)

1. **Bidirectional shutdown** — `Cmd-Q`, window close, File→Quit menu item, control-socket `Quit`, and OS signal must all converge. Each path calls both `slint::quit_event_loop()` and `shutdown_tx.send(true)`. Documented in Task 3.
2. **`OpenProject` uses `spawn_blocking`** for `ProjectStore::read` (parses `project.json` from disk; can be slow on NFS). Same pattern as existing `StopRecording`. Documented in Task 4.
3. **`--headless` separate from `--control-socket`** — design doc explicitly wants Claude to socket-drive a *real running UI* for debugging. Two independent flags. Documented in Task 0.
4. **`broadcast::RecvError::Lagged` logs a warning** instead of silently continuing. Documented in Task 0.
5. **`mod bus` is no longer behind `#[cfg(feature = "control-socket")]`** — UI also uses it. Move bus + protocol gating; only `control_socket` and `event_layer::ForwardLayer::events` stay feature-gated. Documented in Task 0.
6. **Command correlation IDs from the UI** — UI-originated commands use the literal string `"ui"` as `id`. Documented in Task 4. (Future phases may switch to UUIDs if id collisions become a problem in tracing.)
7. **`app.launched` event is documented as inherently racing** the control-socket connection — already known and worked around in `smoke.rs`. Add a comment to `main.rs` to note that no event emitted before `control_socket.ready` is observable to socket subscribers.
8. **No claim of menu-bar coverage** in component tests. Slint's `slint::testing` cannot drive native `MenuBar` items on macOS (those are `NSMenu`). Component test in Task 8 covers an inline `.slint` element only.

---

## Task 0: Preflight refactors (no Slint yet)

**Files:**
- Modify: `crates/video-coach-app/src/main.rs`
- Modify: `crates/video-coach-app/src/cli.rs`
- Modify: `crates/video-coach-app/src/control_socket.rs`

**Step 1: Add `--headless` flag, decoupled from `--control-socket`**

`Args` gains a new field; `--headless` is independent of `--control-socket`. Default is "show UI" (matches Phase 7+ expectations); tests pass `--headless`.

**Step 2: Un-gate `mod bus` and `mod protocol` from `control-socket` feature**

The bus is the universal command path now. `main.rs`:

```rust
mod bus;
mod cli;
mod event_layer;
mod logging;
mod protocol;

#[cfg(feature = "control-socket")]
mod control_socket;
```

Verify `cargo build -p video-coach-app --no-default-features` still succeeds (bus + protocol now live without socket).

**Step 3: Log on `broadcast::RecvError::Lagged`**

In `control_socket.rs::handle_connection`, change the silent `continue` on `Lagged(n)` to a `tracing::warn!` so test failures aren't mysteriously silent.

**Step 4: Document the `app.launched` race**

Add a comment in `main.rs` near the `tracing::info!(...event = "app.launched"...)` line: any event emitted before `control_socket::serve` calls `events.subscribe()` is unobservable to socket clients. Test harness already knows; document for future readers.

**Step 5: Verify `cargo test --workspace` still green.**

**Step 6: Commit.**

```
chore(app): preflight for Phase 6 — un-gate bus, add --headless, log lagged broadcast
```

---

## Task 1: Add Slint dependency + empty main window

**Files:**
- Modify: `Cargo.toml` (workspace-level — add slint to `[workspace.dependencies]`)
- Modify: `crates/video-coach-app/Cargo.toml` (depend on slint, add `build-dependencies` for slint-build)
- Create: `crates/video-coach-app/build.rs`
- Create: `crates/video-coach-app/ui/main.slint`
- Modify: `crates/video-coach-app/src/main.rs`

**Step 1: Workspace deps**

```toml
# Cargo.toml workspace
[workspace.dependencies]
slint = { version = "1.8", default-features = false, features = ["std", "backend-winit", "renderer-skia", "compat-1-2"] }
slint-build = "1.8"
rfd = { version = "0.14", default-features = false, features = ["xdg-portal", "tokio"] }
```

(Skia renderer chosen over default femtovg because text shaping on Linux/macOS native menus is more reliable; falls back to software where needed.)

**Step 2: app crate deps**

```toml
[dependencies]
slint = { workspace = true }
rfd = { workspace = true }

[build-dependencies]
slint-build = { workspace = true }
```

**Step 3: build.rs**

```rust
fn main() {
    slint_build::compile("ui/main.slint").unwrap();
}
```

**Step 4: ui/main.slint — minimum viable window**

```slint
export component MainWindow inherits Window {
    title: "Video Coach";
    width: 1280px;
    height: 800px;

    in property <string> project-title: "No project open";

    Text {
        x: 16px;
        y: 16px;
        text: project-title;
        font-size: 18px;
    }
}
```

**Step 5: Wire MainWindow into main.rs (only when not `--headless`)**

Outline (full integration follows in Tasks 2–3):

```rust
slint::include_modules!();

// inside main(), after bus + socket setup:
if !args.headless {
    let window = MainWindow::new()?;
    window.run()?; // blocks main thread until window closed
} else {
    // existing tokio::select! { ctrl_c, shutdown_rx }
}
```

**Step 6: `cargo run -p video-coach-app` opens a window titled "Video Coach" with the placeholder text.**

**Step 7: `cargo test --workspace` (with `--headless`-only test invocations) still green.**

**Step 8: Commit.**

```
feat(app): add Slint dependency + empty main window
```

---

## Task 2: Slint+tokio threading bridge

**Files:**
- Create: `crates/video-coach-app/src/ui.rs`
- Modify: `crates/video-coach-app/src/main.rs`

**Goal:** Restructure `main` so Slint runs on the main thread and the tokio runtime runs on a worker thread. `BusHandle` and a `tokio::runtime::Handle` are passed into the UI module so UI callbacks can dispatch bus commands.

**Step 1: Restructure main**

Drop `#[tokio::main]`. Build a multi-threaded runtime explicitly:

```rust
fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let rt_handle = runtime.handle().clone();

    let (events_tx, _) = tokio::sync::broadcast::channel(256);
    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);

    // Wire forward_layer + logging the same as today.
    let forward_layer = if args.control_socket.is_some() {
        Some(event_layer::ForwardLayer { events: events_tx.clone() })
    } else {
        None
    };
    logging::init(args.json_logs, forward_layer);
    tracing::info!(target: "app.lifecycle", event = "app.launched", version = env!("CARGO_PKG_VERSION"));

    let bus = bus::spawn_on(&rt_handle, shutdown_tx.clone());

    if let Some(port) = args.control_socket {
        let bus_for_socket = bus.clone();
        let events_for_socket = events_tx.clone();
        rt_handle.spawn(async move {
            let (listener, addr) = control_socket::bind(port).await.unwrap();
            tracing::info!(target: "app.lifecycle", event = "control_socket.ready", addr = %addr);
            control_socket::serve(listener, bus_for_socket, events_for_socket).await;
        });
    }

    if args.headless {
        // Block on shutdown_rx OR ctrl_c — current behavior.
        runtime.block_on(async move {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = shutdown_rx.changed() => {}
            }
        });
    } else {
        ui::run(bus, rt_handle, shutdown_tx)?; // blocks main thread on slint event loop
    }

    tracing::info!(target: "app.lifecycle", event = "app.shutdown");
    Ok(())
}
```

`bus::spawn` is renamed `bus::spawn_on(handle, shutdown_tx)` — caller-supplied runtime handle so we no longer rely on `#[tokio::main]`.

**Step 2: ui.rs skeleton**

```rust
pub fn run(
    bus: bus::BusHandle,
    rt: tokio::runtime::Handle,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
) -> anyhow::Result<()> {
    let window = MainWindow::new()?;
    // Hook close to shutdown_tx (Task 3)
    // Hook menu actions (Task 5)
    window.run().map_err(Into::into)
}
```

**Step 3: Verify `cargo run -p video-coach-app` still opens the window; `cargo run -- --headless --control-socket=0` still emits `control_socket.ready` and accepts `ping`.**

**Step 4: Run `cargo test --workspace` — all existing harness tests still green.**

**Step 5: Commit.**

```
feat(app): split tokio runtime onto worker thread; Slint owns main thread
```

---

## Task 3: Bidirectional shutdown plumbing

**Files:**
- Modify: `crates/video-coach-app/src/ui.rs`
- Modify: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-app/src/main.rs`

**Goal:** All five shutdown paths converge on the same final state (Slint event loop exited + tokio runtime stopped):

| Path | Trigger | Wire-up |
|---|---|---|
| Window close | winit `CloseRequested` | `MainWindow::on_close_requested` → `shutdown_tx.send(true)` + return `CloseBehavior::HideWindow` |
| Cmd-Q / File→Quit | menu item handler | dispatch `Command::Quit` via bus |
| Control socket `Quit` | bus handler | already calls `shutdown_tx.send(true)`; **also** calls `slint::quit_event_loop()` via `invoke_from_event_loop` |
| OS signal | `ctrl_c()` future | (headless only) breaks tokio `select!` |
| Crash in Slint event loop | `window.run()` returns Err | propagated via `?`; tokio runtime drops on scope exit |

**Step 1: Add a `slint::quit_event_loop()` call into the bus's `Command::Quit` handler.**

Tricky: `bus::handle` runs on tokio. `slint::quit_event_loop()` must be called from any thread (the function is thread-safe per Slint docs). Verify by reading slint 1.8 docs; if not thread-safe, route through `slint::invoke_from_event_loop`.

```rust
Command::Quit => {
    tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested");
    let _ = shutdown_tx.send(true);
    let _ = slint::quit_event_loop(); // no-op when --headless (no event loop running)
    CommandReply { ok: true, error: None }
}
```

**Step 2: Hook `MainWindow.window().on_close_requested(...)` in ui.rs**

```rust
let shutdown_tx_for_close = shutdown_tx.clone();
window.window().on_close_requested(move || {
    let _ = shutdown_tx_for_close.send(true);
    slint::CloseRequestResponse::HideWindow
});
```

**Step 3: Spawn a tokio task that watches `shutdown_rx` and calls `slint::quit_event_loop()` when it fires.**

This handles the case where `Command::Quit` arrives via the socket and Slint UI is up:

```rust
let mut shutdown_rx = shutdown_tx.subscribe();
rt.spawn(async move {
    let _ = shutdown_rx.changed().await;
    let _ = slint::quit_event_loop();
});
```

**Step 4: Smoke-test all five paths manually.**

For each path, observe that the process exits cleanly within 1s:
- `cargo run`, click red close button → exits ✅
- `cargo run`, Cmd-Q → exits ✅
- `cargo run -- --control-socket=0`, `nc 127.0.0.1 <port>`, send `{"id":"1","cmd":"quit"}` → exits ✅
- `cargo run -- --headless`, Ctrl-C → exits ✅

(Manual smoke is acceptable here because automated UI window tests come later. Document in PR description that all four paths were exercised.)

**Step 5: Existing `smoke.rs` test (headless path) still green.**

**Step 6: Commit.**

```
feat(app): bidirectional shutdown — close, menu quit, socket quit, signal all converge
```

---

## Task 4: `OpenProject` bus command + project state

**Files:**
- Modify: `crates/video-coach-app/src/bus.rs`
- Create: `crates/video-coach-harness/tests/open_project_smoke.rs`
- Possibly modify: `crates/video-coach-core/src/project_store.rs` (if a tiny fixture project doesn't exist yet)

**Step 1: Add `Command::OpenProject { path: String }` variant**

```rust
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    Quit,
    Ping,
    StartRecording { source: SourceConfig, output: String },
    StopRecording,
    OpenProject { path: String },
}
```

**Step 2: Add per-bus-task project state**

```rust
let mut current_project: Option<video_coach_core::project::Project> = None;
```

**Step 3: Handle `OpenProject` with `spawn_blocking`**

```rust
Command::OpenProject { path } => {
    let folder = std::path::PathBuf::from(&path);
    let result = tokio::task::spawn_blocking(move || {
        video_coach_core::project_store::read(&folder)
    })
    .await;
    match result {
        Ok(Ok(project)) => {
            tracing::info!(
                target: "project.lifecycle",
                event = "project.opened",
                path = %path,
                title = %project.title,
            );
            *current_project = Some(project);
            CommandReply { ok: true, error: None }
        }
        Ok(Err(e)) => CommandReply { ok: false, error: Some(e.to_string()) },
        Err(join) => CommandReply { ok: false, error: Some(format!("join: {join}")) },
    }
}
```

**Step 4: Unit tests in `bus.rs` for serialize/deserialize of `OpenProject` (mirror `start_recording_serializes_with_fixture_source`).**

**Step 5: Harness E2E test**

`open_project_smoke.rs`:

```rust
use std::time::Duration;
use video_coach_harness::App;
use tempfile::TempDir;

#[tokio::test]
async fn open_project_emits_event() -> anyhow::Result<()> {
    // Build a minimal valid project.json in a temp folder.
    let dir = TempDir::new()?;
    let project_path = dir.path();
    let json = r#"{
        "formatVersion": 2,
        "title": "Phase 6 Smoke",
        "tags": [],
        "sourceVideos": [],
        "clips": []
    }"#;
    std::fs::write(project_path.join("project.json"), json)?;

    let mut app = App::launch().await?;
    let reply = app
        .send(serde_json::json!({
            "cmd": "open_project",
            "path": project_path.to_string_lossy(),
        }))
        .await?;
    assert_eq!(reply.ok, Some(true));
    let evt = app.wait_for_event("project.opened", Duration::from_secs(2)).await?;
    assert_eq!(evt["title"], "Phase 6 Smoke");
    app.quit().await?;
    Ok(())
}
```

(Adjust the JSON shape to match the actual `Project` struct field names — read `crates/video-coach-core/src/project.rs` first.)

**Step 6: `cargo test --workspace` green.**

**Step 7: Commit.**

```
feat(app): OpenProject bus command + project.opened event + harness coverage
```

---

## Task 5: File menu — Open Project + Quit, dispatched through the bus

**Files:**
- Modify: `crates/video-coach-app/ui/main.slint`
- Modify: `crates/video-coach-app/src/ui.rs`

**Step 1: Add menu bar to MainWindow**

```slint
import { MenuBar } from "std-widgets.slint";

export component MainWindow inherits Window {
    title: "Video Coach";
    in property <string> project-title: "No project open";

    callback open-project-clicked();
    callback quit-clicked();

    MenuBar {
        Menu {
            title: "File";
            MenuItem { title: "Open Project…"; activated => { root.open-project-clicked(); } }
            MenuItem { title: "Quit"; activated => { root.quit-clicked(); } }
        }
    }

    Text { /* ... */ }
}
```

(Slint 1.8 syntax — verify `MenuBar`/`Menu`/`MenuItem` exist in `std-widgets`; if the API differs, use the actual one. Native menus on macOS are reachable via `MenuBar` from 1.6+.)

**Step 2: Wire callbacks in ui.rs**

```rust
let bus_for_quit = bus.clone();
let rt_for_quit = rt.clone();
window.on_quit_clicked(move || {
    let bus = bus_for_quit.clone();
    rt_for_quit.spawn(async move {
        bus.send("ui".into(), Command::Quit).await;
    });
});

let bus_for_open = bus.clone();
let rt_for_open = rt.clone();
let weak = window.as_weak();
window.on_open_project_clicked(move || {
    let bus = bus_for_open.clone();
    let weak = weak.clone();
    rt_for_open.spawn(async move {
        let chosen = rfd::AsyncFileDialog::new()
            .set_directory("/")
            .pick_folder()
            .await;
        let Some(folder) = chosen else { return; };
        let path = folder.path().to_string_lossy().into_owned();
        let reply = bus.send("ui".into(), Command::OpenProject { path: path.clone() }).await;
        if reply.ok {
            let title_path = path.clone();
            slint::invoke_from_event_loop(move || {
                if let Some(w) = weak.upgrade() {
                    w.set_project_title(title_path.into());
                }
            }).ok();
        } else {
            tracing::warn!(target: "ui", error = ?reply.error, "open_project failed");
        }
    });
});
```

**Step 3: Manually verify on macOS — File→Quit closes the app; File→Open Project shows a folder picker, picking a valid project folder updates the on-screen title.**

**Step 4: `cargo test --workspace` green.**

**Step 5: Commit.**

```
feat(app): File menu — Open Project + Quit, dispatched via bus
```

---

## Task 6: Slint component test (proves slint::testing wired up)

**Files:**
- Create: `crates/video-coach-app/src/ui_tests.rs` or `tests/ui_component.rs`
- Modify: `crates/video-coach-app/Cargo.toml` (slint test feature if needed)

**Step 1: Add a tiny inline component to ui/main.slint**

```slint
export component ProjectTitleLabel inherits Text {
    in property <string> name;
    text: name;
    font-size: 18px;
}
```

**Step 2: Component test**

```rust
#[test]
fn project_title_label_renders_input() {
    let label = ProjectTitleLabel::new().unwrap();
    label.set_name("Test Project".into());
    assert_eq!(label.get_text(), slint::SharedString::from("Test Project"));
}
```

**Honesty caveat:** Per the adversarial review, this test does NOT cover native menu interaction (Slint's `slint::testing` cannot drive `NSMenu` items). It proves that the `slint::include_modules!()` build pipeline works and inline `.slint` components can be instantiated headless — meaningful for future component tests, not for menu-bar coverage.

**Step 3: `cargo test -p video-coach-app` green.**

**Step 4: Commit.**

```
test(app): Slint component test scaffold for inline UI elements
```

---

## Task 7: CI matrix — verify Slint builds on all 3 OSes

**Files:**
- Modify: `.github/workflows/rust.yml`

**Step 1: Linux runner needs Skia build deps**

Slint with `renderer-skia` needs a C++ toolchain + libfontconfig + libfreetype + libxcb + libwayland on Linux. Add to `media-tests` job's apt install (already installs gstreamer-plugins-* there) — extend to the `test` job's ubuntu matrix entry too:

```yaml
- name: Install Slint Linux deps (ubuntu)
  if: matrix.os == 'ubuntu-latest'
  run: |
    sudo apt-get update
    sudo apt-get install -y \
      libfontconfig1-dev libfreetype-dev \
      libxcb-icccm4-dev libxcb-image0-dev libxcb-keysyms1-dev \
      libxcb-render-util0-dev libxcb-shape0-dev libxcb-xkb-dev \
      libxkbcommon-dev libxkbcommon-x11-dev \
      libwayland-dev
```

**Step 2: Verify CI green on push.**

**Step 3: If Windows fails to find Skia binary, switch to `--features renderer-software` for the CI test invocation only** (Skia precompiled binaries are flaky on certain Windows runner images). Production builds keep Skia.

**Step 4: Commit.**

```
ci: Slint Skia deps on Linux + Windows fallback if needed
```

---

## Task 8: Final integration check + plan close-out

**Files:**
- Modify: `docs/plans/2026-04-29-rust-rewrite-phase-6-ui-shell.md` (this file — strike completed tasks, append "Phase 6 closeout" with measurable outcomes)

**Step 1: Run the full test suite + build all targets.**

```
cargo build --workspace
cargo build --workspace --no-default-features    # release-shape build
cargo build -p video-coach-app --features media   # media-on UI shell
cargo test --workspace
cargo test --workspace --features media -- --include-ignored visual_check
```

**Step 2: Manual smoke checklist (record results in PR description).**

- [ ] `cargo run -p video-coach-app` opens a window
- [ ] File→Open Project shows folder picker
- [ ] Picking a valid project folder updates the title in the window
- [ ] Picking an invalid folder logs a warning, no crash
- [ ] File→Quit exits the app
- [ ] Cmd-Q exits the app
- [ ] Window close button exits the app
- [ ] Headless mode (`--headless --control-socket=0`) accepts socket commands
- [ ] Headless mode terminates on Ctrl-C and on socket `quit`

**Step 3: Push, verify CI matrix green.**

**Step 4: Commit the plan closeout.**

```
docs: Phase 6 closeout — UI shell shipped
```

---

## What Phase 6 deliberately does NOT include

- **Live recording surface** — Phase 8 work.
- **Compositor preview surface** in the window — Phase 9 work (visual parity gate).
- **Timeline / scrubbing** — Phase 7 work.
- **Window E2E coverage with real pixels** — defers until Phase 11 packaging work picks a virtual display strategy. Phase 6 ships menu-bar coverage as "manual smoke checklist on dev machines + automated coverage of the bus command path."
- **macOS .app bundle / Windows MSI / Linux AppImage** — Phase 11.
- **Localization, accessibility audit** — out of scope.
- **Project-creation UI** — File→New is deferred; Phase 6 only opens existing projects.

---

## Risks / unknowns

1. **Slint `MenuBar`+`Menu`+`MenuItem` API shape in 1.8.** If the actual exports differ, fall back to a custom in-window button row for File→Open and File→Quit, *and* register a native macOS menu via `slint::run_event_loop_until_quit` + a platform-specific snippet. Document the fallback in Task 5's commit message.
2. **Skia precompiled binaries on Windows runners.** Plan mentions a `renderer-software` fallback. If even that fails, drop the test job's Windows entry temporarily and file a follow-up issue.
3. **`slint::quit_event_loop()` thread-safety.** Verified by reading 1.8 docs in Task 3. If unsafe outside the main thread, route through `invoke_from_event_loop`.
4. **`rfd::AsyncFileDialog` on Linux without a portal.** Tasks run on dev machines that have xdg-portal. CI never opens dialogs. Fine.

---

## Done when

- All tasks merged.
- CI matrix green on macOS / Linux / Windows.
- All eight items in Task 8's manual smoke checklist passing.
- New `open_project_smoke.rs` harness test passing.
- New Slint component test passing.
- No regressions in existing Phase 1–5 tests.

---

## Closeout (2026-04-29)

**Status: shipped.** CI run 25140303830 green on all four jobs:

| Job | Result |
|---|---|
| `test (windows-latest)` | ✅ |
| `test (macos-latest)` | ✅ |
| `test (ubuntu-latest)` | ✅ |
| `media-tests` (Linux + GStreamer + lavapipe + Slint) | ✅ |

**Commits (in order):**

| Task | Commit | Title |
|---|---|---|
| 0 | `be474c4` | Preflight — un-gate bus, add `--headless`, log lagged broadcast |
| 1 | `a89349c` | Add Slint 1.8 dependency + empty MainWindow |
| 2 | `cda0355` | Slint owns main thread, tokio runs alongside |
| 3 | `b3ce012` | Bidirectional shutdown plumbing |
| 4 | `cf0bfb5` | OpenProject bus command + E2E harness coverage |
| 5 | `81892d3` | File menu wires Open Project + Quit through bus |
| 6 | `e195966` | Slint component test scaffold |
| 7 | `463fe06` | CI install Slint Linux deps |
| —  | `6a4167f` | (style) cargo fmt fixups |

**Test counts:** 60 → 65 (+1 Slint component round-trip, +2 OpenProject serde unit, +2 OpenProject E2E harness).

**Adversarial-review changes verified in code:**

- ✅ Bidirectional shutdown — `bus.rs::Command::Quit` calls `slint::quit_event_loop()`; `ui.rs::on_close_requested` sends `shutdown_tx`; tokio watcher in `ui.rs` calls `slint::quit_event_loop()` when shutdown_rx fires.
- ✅ `OpenProject` uses `tokio::task::spawn_blocking` for `ProjectStore::read`.
- ✅ `--headless` and `--control-socket` are independent flags.
- ✅ `broadcast::RecvError::Lagged` logs a `tracing::warn!` instead of silent continue.
- ✅ `mod bus` and `mod protocol` no longer behind `control-socket` feature.
- ✅ UI commands stamp `id="ui"`.
- ✅ `app.launched`-vs-subscriber race documented in `main.rs`.
- ✅ Component test scope explicitly excludes native `MenuBar` coverage in its docstring.

**Manual smoke checklist** — outstanding for the user to walk through:

- [ ] `cargo run -p video-coach-app` opens a window
- [ ] File→Open Project shows a folder picker
- [ ] Picking a valid project folder updates the title
- [ ] Picking an invalid folder logs a warning, no crash
- [ ] File→Quit exits the app
- [ ] Cmd-Q exits the app
- [ ] Window close button exits the app
- [x] Headless `--control-socket=0` accepts socket commands (covered by `smoke.rs`)
- [x] Headless socket-`quit` shuts down cleanly (covered by `smoke.rs`)

A Phase 11 virtual-display strategy will flip the manual checks to automated ones; deferred per the design doc.

**Phase 7 entry conditions met.** Next phase (Source-video timeline + transport) can build on the Slint shell, the bus, and the harness without further refactor.
