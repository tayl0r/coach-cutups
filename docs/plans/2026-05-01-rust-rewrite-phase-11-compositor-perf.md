# Rust Rewrite — Phase 11 Plan #4: Compositor Performance

Branch: `rust-rewrite`. Phase 11 is Polish + deferred items from Phase 10's
closeout. This plan picks up three engine-side performance optimizations
flagged in Phase 9's closeout and Phase 10's "Known performance risks"
section: per-frame `wgpu::RenderPipeline` rebuild, per-frame stroke `VertexBuffer`
allocation, and redundant compose during Freeze segments. **No behavior
change** — Phase 9's `parity_smoke` (single-frame) and Phase 10's
`parity_n_frames` (30-frame) tests must continue passing byte-for-byte.
Wins are measured as wall-clock reduction in `cargo test -p
video-coach-media --features media` and in eventual end-user export speed.

---

## Goal (one paragraph)

Plan #4 reduces wall-clock time per `compose_tick(...)` call without
introducing any pixel-level non-determinism. Three optimizations land:
(1) cache the wgpu `RenderPipeline` for both the PiP pass and the stroke
pass on the `Compositor` struct, keyed by `(source_w, source_h, has_strokes)`;
(2) replace the per-call stroke `VertexBuffer` allocation with a pooled
buffer that's `write_buffer`-d on each compose, growing only on capacity
miss; (3) memoize Freeze-segment compose output via an LRU cache on
`Compositor`, keyed by `Arc<Frame>` pointer-equality (not pixel hash —
the export driver's freeze pre-decode and the preview driver both pass
the same `Arc<Frame>` for the duration of a freeze segment, per Phase 10
fix #11 and Phase 9 fix #6). The Compositor's API contract shifts from
"stateless function holder" to "stateless from the outside, perf-cache
holder inside" — documented in `compose_tick`'s docstring. All three
caches use interior mutability (`Mutex` / `RwLock`) so `compose` keeps
its `&self` signature; the existing call sites (`Arc<Compositor>` shared
between preview's 30 Hz driver thread and export's `spawn_blocking` task)
continue to work unchanged. A new perf-regression test lives in
`crates/video-coach-compositor/benches/` (or `tests/perf_smoke.rs` if
benches are too heavy for CI) that asserts `compose_tick` averages under
a generous threshold over N=30 calls; baseline numbers captured in Task 0
guard against future regressions.

---

## What Phase 11 Plan #4 deliberately does NOT include

1. **Texture-upload caching for the source / webcam frames.** Both `compose`
   call sites currently re-upload source + webcam textures on every call.
   Phase 9 considered this but `Frame` has no `id` / generation counter,
   and Arc-pointer-eq alone is racy across hot-swap (preview's
   latest_source_frame slot rewrites the Arc when a new decoded frame
   lands). Adding a generation counter is its own design pass; deferred
   to a future plan. The Freeze cache (Task 3) sidesteps this by caching
   the FINAL composed RGBA, which incidentally amortizes the texture
   upload too.
2. **Cross-`Compositor`-instance cache.** Each `Compositor::new_headless()`
   builds its own caches. Bus + preview share one `Arc<Compositor>` per
   process (per Phase 10 fix #15) so this is fine; tests that build a
   fresh Compositor per test (the existing pattern in
   `compositor.rs::tests` and `parity_smoke.rs`) get a fresh cache, also
   fine.
3. **Async / deferred compose.** `compose_tick` stays synchronous and
   blocking. The cache reads + writes happen inside the existing
   `&self` call, with whatever lock contention that implies. The 30 Hz
   preview driver and `spawn_blocking` export driver each call into
   the same `Arc<Compositor>`, so a Mutex on cache fields can serialize
   them — but the preview thread is the only one running during preview
   (export is gated by `is_busy`), and the export thread is the only one
   running during export. Contention is theoretical, not actual. A
   `tracing::warn!` log if the lock is poisoned + a panic-recovery fall
   through to the un-cached path documents the safety story.
4. **Pipeline cache for the readback / staging buffer.** The output
   readback `wgpu::Buffer` is sized by `padded_bytes_per_row(w) * h`;
   caching it keyed by output dimensions is a follow-on optimization
   if Tasks 1-3 don't move the needle enough. Out of scope here; flag
   in closeout if measurements show readback alloc is the next bottleneck.
5. **HashMap / DashMap for the freeze cache.** The cache is sized at 16
   entries (per scope.md), bounded by export driver's per-entry freeze
   pre-decode set. A simple `Vec<(key, frame)>` with linear scan + LRU
   eviction is faster than HashMap at N=16 and cheaper to lock. Don't
   over-engineer.
6. **Behavior change for the `compose_tick` signature or
   `compose_entry_frame` signature.** Both stay unchanged. The cache is
   purely an internal optimization on `Compositor`'s state.
7. **Texture-format / color-space variants in the pipeline cache key.**
   `Rgba8Unorm` is hardcoded throughout (texture upload, render target,
   output format) — verified by the source. Future HDR / 10-bit work
   would need to extend the key; for now the key is just
   `(source_w, source_h, has_strokes)`.

---

## Verified pre-plan known-unknowns

Per scope.md's "Known unknowns" section, the orchestrator verified these
at plan-write time by reading the current `Compositor::compose` impl in
`crates/video-coach-compositor/src/compositor.rs` (commit `b9d8db9` on
`rust-rewrite`):

- **Known unknown #1 (RenderPipeline rebuilt every call?)** — **CONFIRMED
  REAL WORK**. Lines 222–310 build the PiP shader + bind group layout +
  pipeline layout + render pipeline fresh on every `compose` call. Lines
  452–526 (`encode_stroke_pass`) do the same for the stroke pipeline.
  Task 1 is NOT a no-op; it stays in the plan.
- **Known unknown #2 (VBO allocated per-call?)** — **CONFIRMED REAL WORK**.
  Lines 446–451 (`encode_stroke_pass`) call `create_buffer_init` for the
  stroke vertices on every compose with strokes. Task 2 is NOT a no-op;
  it stays in the plan.
- **Known unknown #3 (freeze cache hit-rate worth it?)** — Phase 10
  ships a freeze pre-decode per (entry, segment) caching the frozen
  `Frame` for the entry's lifetime (per fix #11). Both preview's driver
  (Phase 9 fix #6: `frozen_frames: Arc<HashMap<usize, Frame>>` held on
  the struct) and export's driver (Phase 10's
  `compose_entry_frame(... frozen_frames: &HashMap<usize, Frame>)`) pass
  the SAME `Frame` instance into `compose_tick` for every tick of a
  Freeze segment. At 30 fps × ~2 s typical freeze = 60 hits per freeze.
  Worth caching — but the cache key must avoid hashing 8 MB of pixels.
  Plan picks `Arc<Frame>` pointer-equality (after first wrapping the
  cached frozen frames in `Arc` at the call sites — minor refactor in
  Task 3). See Task 3 for the trade-off.

---

## Required reading (sub-agent does this BEFORE coding)

1. This plan top-to-bottom.
2. `docs/plans/2026-05-01-rust-rewrite-phase-10-export-sheet.md` —
   especially "Adversarial-review fixes baked in" (40 fixes). The
   compositor cache MUST NOT regress any of #3 (compose_tick is THE
   entry point), #15 (shared Arc<Compositor>), #21 (parity test), #24
   (sequential per-tag), #40 (Frame derives PartialEq).
3. `docs/plans/2026-04-30-rust-rewrite-phase-9-clip-preview.md` — closeout
   section's "Deferred to Phase 11" list (the three items Plan #4
   addresses).
4. `crates/video-coach-compositor/src/compositor.rs` — current
   `Compositor::compose` impl. Lines 137–433 (PiP pass + stroke pass +
   readback). Lines 439–547 (`encode_stroke_pass`). The cache fields go
   on the `Compositor` struct (lines 45–48).
5. `crates/video-coach-compositor/src/lib.rs` — `compose_tick`
   docstring. Plan #4 extends the docstring to document the new cache
   contract.
6. `crates/video-coach-compositor/tests/parity_smoke.rs` — Phase 9's
   single-frame parity. Two `compose_tick` calls back-to-back must
   byte-match.
7. `crates/video-coach-media/tests/parity_n_frames.rs` — Phase 10's
   30-frame parity. `compose_entry_frame` called twice over 30
   record_times must produce byte-identical sequences.
8. `crates/video-coach-media/src/preview_pipeline.rs` — preview's
   `frozen_frames: Arc<HashMap<usize, Frame>>` field (line 124). Task 3
   bumps these `Frame` values into `Arc<Frame>` (or threads the `&Frame`
   pointer's identity through differently — see Task 3).
9. `crates/video-coach-media/src/export.rs::compose_entry_frame` (lines
   349–376) — the export driver's freeze cache. Same `Arc<Frame>` change
   required.
10. `PROGRESS.txt` — Phase 11 Plan #4 row appears under
    "Phase 11 — pending" (last section).

---

## Adversarial-review fixes baked in

(Filled in by orchestrator at the `ADV_REVIEWED` stage with the
adversarial reviewer's net-new findings + their disposition. Orchestrator
notes: reviewer must read Phase 10's "Adversarial-review fixes baked in"
first to find NET-NEW issues only.)

---

## Cache infrastructure design

### `Compositor` struct extensions

```rust
pub struct Compositor {
    pub(crate) device: wgpu::Device,
    pub(crate) queue: wgpu::Queue,

    // Plan #4 Task 1: cached PiP + stroke pipelines, rebuilt only when
    // the key changes. The bind group layout + sampler are key-
    // independent (no source-dim or stroke dependency); the pipeline +
    // pipeline-layout depend on the format (hardcoded Rgba8Unorm) +
    // shader (constant). So in practice the cache is a single Option
    // per pass, not a multi-entry map. Mutex-wrapped for &self compose.
    pip_cache: std::sync::Mutex<Option<PipPassCache>>,
    stroke_cache: std::sync::Mutex<Option<StrokePassCache>>,

    // Plan #4 Task 2: pooled stroke vertex buffer. Capacity grows on
    // demand; never shrinks. Mutex'd for &self.
    stroke_vbo_pool: std::sync::Mutex<Option<PooledVbo>>,

    // Plan #4 Task 3: freeze-segment compose memoization. LRU bounded
    // at 16 entries (~128 MB at 1080p RGBA — see "Memory" review note).
    // Key: (Arc<Frame> pointer of source, Arc<Frame> pointer of webcam,
    //       u64 stroke-set hash). Value: Frame.
    freeze_cache: std::sync::Mutex<FreezeCache>,
}
```

Each cache is its own Mutex so a Task-1 cache hit doesn't block a
Task-3 cache lookup. (`RwLock` is tempting but the write path on cache
miss is the expensive path — read-locking + then upgrading would just
add complexity.)

### Cache miss → fall-through

Every cache is BEST-EFFORT. On poison, log `tracing::warn!(target =
"compositor.cache", event = "compositor.cache_poisoned", which = ...)`,
clear the cache, fall through to the un-cached path. Never panic.
Plan-level invariant (codified in code comments at each cache lookup
site):

> Cache hits MUST produce byte-identical output to cache misses. If
> this contract breaks, parity_smoke + parity_n_frames fail loudly.
> The cache is a perf optimization, not a behavior change.

### Thread-safety story

`compose_tick` is called from two thread contexts in the production
codebase:

- **Preview**: 30 Hz driver thread spawned by `PreviewPipeline::open`
  (`crates/video-coach-media/src/preview_pipeline.rs`).
- **Export**: a `spawn_blocking` task on Tokio's blocking pool, owning
  the export pipeline (`crates/video-coach-app/src/bus.rs::handle_export_compilations`).

These two thread contexts are MUTUALLY EXCLUSIVE — `is_busy` returns true
for both `AppMode::Previewing` and `AppMode::Exporting` (Phase 10 fix #9
+ #22), so the bus rejects starting one while the other is running. The
shared `Arc<Compositor>` therefore sees only one writer at a time in
practice. A `Mutex` per cache field is safe and not contended; we use
`Mutex` (not `parking_lot`) to keep the dependency tree small.

In tests, two compose_tick calls run sequentially on the same thread —
no contention. The `parity_n_frames` test runs two N=30 sequences
back-to-back on one thread — no contention.

If a future change introduces real concurrent compose calls (e.g.
parallel multi-tag export), the `Mutex` becomes a serialization point.
Documented; out of scope here.

---

## Tasks

### Task 0: Preflight — perf-regression test + cache scaffolding

**Files:**
- Create: `crates/video-coach-compositor/tests/perf_smoke.rs` (or
  `benches/compose_bench.rs` — see decision below).
- Modify: `crates/video-coach-compositor/src/compositor.rs` — add the
  three cache field types as `pub(crate)` structs + `Default` impls;
  add fields to `Compositor`; initialize them in `new_headless_async`;
  do NOT yet wire them into `compose`.
- Modify: `crates/video-coach-compositor/src/lib.rs` — extend
  `compose_tick` docstring documenting the cache invariant.

**Decision: tests/perf_smoke.rs (NOT bench/criterion)** — keep the
dependency tree thin. The test runs N=30 `compose_tick` calls and
asserts `total_ms < BASELINE_MS * 2.0`, where `BASELINE_MS` is captured
in Task 0 by running the test once locally on the orchestrator's box
+ once on lavapipe via CI. Two-times headroom because lavapipe is
~5-10× slower than Apple Silicon — we can't pin a single baseline.
Instead: log the per-call ms in the test (so future regressions show up
as a wall-clock spike in CI logs even if the assertion holds). The
assertion is just a sanity floor.

**Cache types (no behavior yet — just the shape):**

```rust
pub(crate) struct PipPassCache {
    pub key: PipPassKey,        // (source_w, source_h)  —  stroke-pass
                                // bool lives in StrokePassCache instead
    pub bind_group_layout: wgpu::BindGroupLayout,
    pub pipeline_layout: wgpu::PipelineLayout,
    pub pipeline: wgpu::RenderPipeline,
    pub sampler: wgpu::Sampler,
    pub shader: wgpu::ShaderModule,
}

#[derive(Copy, Clone, PartialEq, Eq)]
pub(crate) struct PipPassKey {
    pub source_w: u32,
    pub source_h: u32,
}

pub(crate) struct StrokePassCache {
    pub key: StrokePassKey,
    pub pipeline_layout: wgpu::PipelineLayout,
    pub pipeline: wgpu::RenderPipeline,
    pub shader: wgpu::ShaderModule,
}

#[derive(Copy, Clone, PartialEq, Eq)]
pub(crate) struct StrokePassKey {
    // Phase 11: format hardcoded Rgba8Unorm so the key is empty in
    // practice. Future HDR work extends with format/color-space.
    pub _placeholder: u8,
}

pub(crate) struct PooledVbo {
    pub buffer: wgpu::Buffer,
    pub capacity_vertices: usize,
}

pub(crate) struct FreezeCache {
    /// LRU. Newest at end. 16-entry cap. Linear scan is fine at N=16.
    pub entries: Vec<(FreezeCacheKey, Frame)>,
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) struct FreezeCacheKey {
    pub source_ptr: usize,    // Arc::as_ptr cast to usize
    pub webcam_ptr: usize,
    pub stroke_hash: u64,
}
```

(`PipPassKey` exists for Task 1 but the only thing varying is `(source_w,
source_h)` since Phase 9's parity tests pin format / shader / blend
state. In practice the production cache hits 100% after the first
compose for each (source-dim) — typically one entry per export.)

**Compose_tick docstring extension (added in this task):**

```rust
/// Canonical "one tick of preview/export work" entry point. Per phase-9
/// adversarial fix #24: ...
///
/// **Phase 11 Plan #4 cache contract:** `Compositor` holds three
/// internal caches (PiP pipeline, stroke pipeline, pooled stroke VBO,
/// freeze-segment compose). All three are populated lazily inside
/// `compose` under interior-mutex'd state. Cache hits MUST produce
/// byte-identical output to cache misses; a parity divergence is a
/// ship-blocker. Tests in `parity_smoke.rs` and `parity_n_frames.rs`
/// guard the invariant. Compositor is no longer "stateless from the
/// inside" but its EXTERNAL contract (same input → same output) is
/// unchanged.
```

**perf_smoke.rs content:**

```rust
//! Phase 11 Plan #4 perf-regression smoke. Runs N=30 compose_tick calls
//! on the same Compositor and logs per-call wall-clock ms. Asserts the
//! total stays under a generous 30s ceiling (lavapipe headroom). The
//! ASSERTION is a regression floor; the LOG is the actual signal.

use std::time::Instant;
use video_coach_compositor::{compose_tick, Compositor, Frame};

#[test]
fn compose_tick_perf_smoke() {
    let comp = Compositor::new_headless().expect("compositor");
    let src = Frame::solid(640, 360, [128, 64, 200, 255]);
    let cam = Frame::solid(160, 90, [64, 200, 64, 255]);

    const N: usize = 30;
    let start = Instant::now();
    let mut per_call_ms: Vec<f64> = Vec::with_capacity(N);
    for _ in 0..N {
        let t0 = Instant::now();
        let _ = compose_tick(&comp, &src, &cam, &[]).expect("compose");
        per_call_ms.push(t0.elapsed().as_secs_f64() * 1e3);
    }
    let total = start.elapsed();
    eprintln!(
        "compose_tick_perf_smoke: N={N} total={:.1}ms avg={:.2}ms \
         min={:.2}ms max={:.2}ms",
        total.as_secs_f64() * 1e3,
        per_call_ms.iter().sum::<f64>() / N as f64,
        per_call_ms.iter().cloned().fold(f64::INFINITY, f64::min),
        per_call_ms.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
    );
    assert!(
        total.as_secs_f64() < 30.0,
        "compose_tick × {N} took {:.1}s — perf regression?",
        total.as_secs_f64()
    );
}
```

The `eprintln!` lands in CI logs (`cargo test -- --nocapture` is
default-on for failing tests; for passing tests it requires a flag
locally but CI's verbose output captures stderr). Future regressions
show up as a spike from baseline.

**Task 0 verification:**
- `cargo build -p video-coach-compositor`
- `cargo test -p video-coach-compositor` (all existing tests pass +
  the new `compose_tick_perf_smoke`).
- `cargo clippy -p video-coach-compositor --all-targets -- -D warnings`.
- `cargo fmt --check`.
- Cache fields exist + initialize, but `compose` doesn't read them yet.
  Existing parity tests pass unchanged.

**LOC budget: ~120.** Cache types + initialization + docstring + test
file. No actual cache-using code yet.

**Commit message:** `phase11(compositor-perf, task 0): preflight + perf
smoke + cache scaffolding`.

---

### Task 1: RenderPipeline cache (PiP + stroke passes)

**Files:**
- Modify: `crates/video-coach-compositor/src/compositor.rs` — `compose`
  method (lines 222–310 PiP pipeline construction) and
  `encode_stroke_pass` (lines 452–526 stroke pipeline construction).
  Replace with cache lookups.

**Behavior:**

In `compose`, after computing `(w, h)`:

```rust
let pip_key = PipPassKey { source_w: w, source_h: h };
let pip_cache_guard = self.pip_cache.lock();  // poison-tolerant; see below
let cache = match pip_cache_guard {
    Ok(mut g) => {
        let needs_rebuild = g.as_ref().map(|c| c.key != pip_key).unwrap_or(true);
        if needs_rebuild {
            *g = Some(self.build_pip_cache(pip_key));
        }
        // SAFETY: `g` lives until end of compose; we hold the mutex
        // for the whole render. Cache fields are wgpu handles which
        // are themselves Arc-shared internally, so re-using them
        // across submits is safe per wgpu 22 docs.
        g  // hold the guard for the rest of compose
    }
    Err(poisoned) => {
        tracing::warn!(target: "compositor.cache",
            event = "compositor.cache_poisoned", which = "pip");
        // Fall through: rebuild ad-hoc, drop poisoned lock
        let mut g = poisoned.into_inner();
        *g = Some(self.build_pip_cache(pip_key));
        g
    }
};
```

(In practice, the simpler shape is to wrap the lookup in a
`with_pip_cache(key, |cache| { ... })` helper closure, holding the lock
for the duration of the render-pass encode. Sub-agent picks the cleaner
shape — both are byte-equivalent.)

Then in the render-pass encode block (lines 343–362), use
`&cache.pipeline` and `&cache.bind_group_layout` instead of the freshly-
built ones.

The bind group itself (lines 314–335) STAYS per-call — bind groups
reference the per-call source/webcam textures + uniform buffer, so they
can't be cached across calls. Only the bind-group LAYOUT + pipeline +
shader + sampler are cached.

`encode_stroke_pass` gets the same treatment: `with_stroke_cache(key,
|cache| { ... })`. Stroke key is empty-ish (just a placeholder for
future format variants), so the cache is effectively a single Option.

**`build_pip_cache(key)` and `build_stroke_cache(key)` helpers** — extract
the existing pipeline-construction code lines 222–310 and 452–526 into
private methods. Keep the wgsl `include_wgsl!` calls inside (they're
cheap — the shader module is built once per cache rebuild, then reused).

**Test changes:**
- `parity_smoke.rs` — assertions unchanged. `compose_tick_is_deterministic_with_no_strokes`
  and `_with_strokes` pass byte-for-byte after Task 1.
- `parity_n_frames.rs` — assertions unchanged. 30 ticks back-to-back +
  byte-for-byte.
- `compositor.rs::tests` — existing 6 tests pass unchanged.
  `compose_with_no_strokes_matches_phase5_baseline` is the structural
  guard — if Task 1 introduces ANY pixel divergence, this fails.
- New unit test `pip_cache_hit_count`: spy on cache rebuild count via
  a `#[cfg(test)] pub fn pip_cache_rebuild_count()` helper; assert that
  N back-to-back `compose` calls with the same source dim trigger
  exactly 1 rebuild.

**Task 1 verification:**
- `cargo build -p video-coach-compositor`
- `cargo test -p video-coach-compositor` (parity_smoke + new cache-hit
  unit test pass).
- `cargo test -p video-coach-media --features media parity_n_frames`
  (parity holds across the cache).
- `cargo test -p video-coach-compositor compose_tick_perf_smoke` (logs
  show meaningfully lower per-call ms after the first call).
- `cargo clippy -p video-coach-compositor --all-targets -- -D warnings`.
- `cargo fmt --check`.

**LOC budget: ~100.** Two `with_*_cache` helper methods + two extracted
`build_*` helper methods + 1 new unit test.

**Commit message:** `phase11(compositor-perf, task 1): cache RenderPipeline
on Compositor`.

---

### Task 2: Pooled stroke VBO

**Files:**
- Modify: `crates/video-coach-compositor/src/compositor.rs` —
  `encode_stroke_pass` (line 446 `create_buffer_init` for stroke vertices).

**Behavior:**

Replace the per-call `create_buffer_init` with a pooled buffer that's
written via `Queue::write_buffer`:

```rust
let bytes = bytemuck::cast_slice(vertices);
let needed = bytes.len();

let mut pool_guard = self.stroke_vbo_pool.lock().unwrap_or_else(|p| {
    tracing::warn!(target: "compositor.cache",
        event = "compositor.cache_poisoned", which = "stroke_vbo");
    p.into_inner()
});

let need_grow = match pool_guard.as_ref() {
    None => true,
    Some(p) => p.capacity_vertices * std::mem::size_of::<StrokeVertex>() < needed,
};
if need_grow {
    // Round up to next power-of-2 vertices to amortize regrow cost.
    // Floor of 64 vertices (~one short stroke segment). Cap on regrow
    // is unbounded — strokes can be arbitrarily long, but in practice
    // a multi-thousand-vertex stroke is rare enough that doubling
    // works.
    let new_cap = vertices.len().next_power_of_two().max(64);
    let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("stroke-vbo-pool"),
        size: (new_cap * std::mem::size_of::<StrokeVertex>()) as u64,
        usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    *pool_guard = Some(PooledVbo { buffer, capacity_vertices: new_cap });
}

let pool = pool_guard.as_ref().expect("populated above");
self.queue.write_buffer(&pool.buffer, 0, bytes);

// In the render pass:
rpass.set_vertex_buffer(0, pool.buffer.slice(..bytes.len() as u64));
```

**Critical detail (`write_buffer` ordering vs render-pass encode):**
`Queue::write_buffer` schedules a DMA copy that's submitted *before* the
encoder's commands when both are submitted in the same `queue.submit`
call. wgpu 22 docs guarantee this ordering. The render pass reads the
written bytes correctly. Confirmed by: the existing
`PipParamsUniform` upload at line 217 uses `create_buffer_init` (not
`write_buffer`) — different shape but same ordering story. The stroke
pool's `write_buffer` slots in cleanly.

**Slice the buffer to `bytes.len()`:** the pool buffer is sized larger
than the current draw's vertex count, so the buffer-bind slice must be
clipped to `0..bytes.len()`. `set_vertex_buffer` accepts arbitrary
sub-ranges; no padding-bytes-cause-vertex-format-error problems.

**Test changes:**
- Existing `stroke_pass_changes_pixels_along_path` test passes
  byte-equivalent.
- New unit test `pooled_vbo_grows_on_capacity_miss`: drive two compose
  calls — one with a small stroke, one with a many-vertex stroke that
  exceeds the small one's capacity. Assert (via `#[cfg(test)] pub fn
  stroke_vbo_grow_count() -> usize`) that exactly 1 grow happened.

**Task 2 verification:**
- `cargo build -p video-coach-compositor`
- `cargo test -p video-coach-compositor` (existing stroke test +
  new grow-counter test).
- `cargo test -p video-coach-media --features media parity_n_frames`
  (the parity test's clip has a stroke; pooled VBO must produce
  byte-identical output).
- `cargo test -p video-coach-compositor compose_tick_perf_smoke`.
- `cargo clippy` + `cargo fmt --check`.

**LOC budget: ~80.** One pool helper + buffer slice change + one new
unit test.

**Commit message:** `phase11(compositor-perf, task 2): pooled stroke VBO
via write_buffer`.

---

### Task 3: Freeze-segment compose memoization

**Files:**
- Modify: `crates/video-coach-compositor/src/compositor.rs` — add
  `compose_with_cache_lookup` private helper that wraps the existing
  `compose` body. Public `compose` becomes the cache-lookup entry point.
- Modify: `crates/video-coach-compositor/src/lib.rs::compose_tick` — no
  signature change; the cache is interior to `compose`.
- Modify: `crates/video-coach-media/src/preview_pipeline.rs` — change
  `frozen_frames: Arc<HashMap<usize, Frame>>` to
  `Arc<HashMap<usize, Arc<Frame>>>`. Threads through the driver
  closure. Pass `&Arc<Frame>` into compose where it currently passes
  `&Frame`.
- Modify: `crates/video-coach-media/src/export.rs::compose_entry_frame`
  — same change: `frozen_frames: &HashMap<usize, Arc<Frame>>`. Update
  the lone caller in `export.rs`'s driver loop.
- Modify: `crates/video-coach-media/src/export.rs` — wherever
  `frozen_frames` is built (the freeze pre-decode block per fix #11),
  wrap each `Frame` in `Arc::new` at insertion time.
- Modify: `crates/video-coach-media/tests/parity_n_frames.rs` — update
  `frozen_frames: HashMap<usize, Frame>` → `HashMap<usize, Arc<Frame>>`.
  Update the `for (i, seg) in entry.segments.iter().enumerate()` loop
  to insert `Arc::new(...)`.

**Cache lookup flow:**

```rust
// In compose's entry point:
pub fn compose(
    &self,
    source: &Frame,
    webcam: &Frame,
    strokes: &[VisibleStroke],
) -> Result<Frame, CompositorError> {
    // Plan #4 Task 3: Freeze cache. Only check if BOTH source + webcam
    // are stable across calls — pointer-eq via Arc means the caller is
    // passing the same Arc. Since `compose` accepts &Frame (not
    // &Arc<Frame>), callers that ARE working with Arc<Frame> must
    // funnel through a separate compose_arc(...) entry point. To keep
    // the public API single-shaped, we instead ask the caller to pass
    // an OPTIONAL identity hint via a new pub fn.

    // NO CACHE HIT for the &Frame entry point — preserves backward
    // compat for direct callers like the existing tests.
    self.compose_uncached(source, webcam, strokes)
}

pub fn compose_with_identity(
    &self,
    source: &Frame, source_id: Option<usize>,
    webcam: &Frame, webcam_id: Option<usize>,
    strokes: &[VisibleStroke],
) -> Result<Frame, CompositorError> {
    if let (Some(sid), Some(wid)) = (source_id, webcam_id) {
        let stroke_hash = hash_stroke_set(strokes);
        let key = FreezeCacheKey {
            source_ptr: sid, webcam_ptr: wid, stroke_hash,
        };
        // Fast path: cache hit
        if let Some(cached) = self.lookup_freeze(&key) {
            return Ok(cached);
        }
        let composed = self.compose_uncached(source, webcam, strokes)?;
        self.insert_freeze(key, composed.clone());
        return Ok(composed);
    }
    self.compose_uncached(source, webcam, strokes)
}
```

**Wait — this changes the public API.** Reconsider: keep `compose`'s
`&Frame` shape; have the caller (export driver / preview driver) pass
identity via a thread-local or via `Arc::as_ptr(&arc) as usize` in a
new param. Decision: **add an optional `identity` param via a new
helper method** rather than reshaping `compose`. Tests + simple callers
keep using `compose`; the production drivers (preview + export) call
the new identity-aware entry point.

`compose_tick` in `lib.rs` gets a sibling: `compose_tick_with_identity`.
Both wrap the same underlying logic. Production paths call the new one;
tests stick with the existing `compose_tick`.

**Stroke hashing**: `hash_stroke_set(strokes: &[VisibleStroke]) -> u64`
hashes the visible-portion of each stroke (id + drawn_point_count +
first_point_record_time). The full point-list isn't needed — strokes
are immutable once captured; (id, drawn_count) uniquely identifies the
visible state. Use `std::hash::DefaultHasher` (cheap, non-crypto). The
hash is for cache keying, not security.

**LRU eviction (`insert_freeze`):**

```rust
fn insert_freeze(&self, key: FreezeCacheKey, frame: Frame) {
    const LRU_CAP: usize = 16;
    let mut g = match self.freeze_cache.lock() {
        Ok(g) => g,
        Err(p) => {
            tracing::warn!(target: "compositor.cache",
                event = "compositor.cache_poisoned", which = "freeze");
            p.into_inner()
        }
    };
    // Remove existing entry with same key (refresh).
    g.entries.retain(|(k, _)| k != &key);
    // Evict oldest if at cap.
    if g.entries.len() >= LRU_CAP {
        g.entries.remove(0);
    }
    g.entries.push((key, frame));
}
```

**`Frame::clone` cost:** `Frame { width, height, pixels: Vec<u8> }` —
clone copies 8 MB at 1080p. To avoid pixel-Vec re-clone on every cache
hit, store `Arc<Frame>` in the cache: `entries: Vec<(FreezeCacheKey,
Arc<Frame>)>`. `lookup_freeze` returns `Arc<Frame>`; the caller (the
production path) must accept either `Frame` or `Arc<Frame>` from
compose. **Decision**: change `compose_with_identity`'s return to
`Result<Frame, ...>` but on cache hit do `(*arc).clone()` — the clone is
unavoidable at the API boundary. The cache win is amortizing the
**GPU compose** (~5-15 ms on Apple Silicon, ~50-100 ms on lavapipe);
the 8 MB memcpy on cache hit is ~1-2 ms. Net win is still significant.
Future plan can change return type to `Arc<Frame>` if memcpy dominates.

**Test changes:**
- `parity_n_frames.rs` — the test calls `compose_entry_frame`, which
  receives `frozen_frames: &HashMap<usize, Arc<Frame>>` after Task 3.
  Test updates the type + wraps in `Arc::new`. Assertions unchanged.
  This is the structural guard: cache hits during the freeze segment
  must return byte-identical pixels to the un-cached path. The test's
  N=30 frames includes ~6 frames inside the Freeze segment (0.4s–0.6s
  at 30 fps), so the second pass through the loop hits the cache 6×.
- New unit test in `compositor.rs::tests`:
  `freeze_cache_hit_returns_byte_identical_output`. Build a Compositor,
  Arc-wrap a source + webcam + empty strokes, call
  `compose_with_identity` twice. Assert second call hit the cache (via
  `#[cfg(test)] pub fn freeze_cache_hit_count() -> usize`) AND the two
  Frame outputs are byte-equal.
- Existing `compose_tick_matches_compose_method` test STAYS passing —
  the `compose_tick` free function still routes through the un-cached
  `compose` (no identity param), so that path is unaffected.

**Task 3 verification:**
- `cargo build -p video-coach-compositor`
- `cargo build -p video-coach-media --features media`
- `cargo test -p video-coach-compositor` (existing 6 + 1 new freeze test).
- `cargo test -p video-coach-media --features media parity_n_frames`
  (cache hits 6× during freeze segment; byte-identical output).
- `cargo test -p video-coach-compositor compose_tick_perf_smoke`.
- `cargo build -p video-coach-app` (preview_pipeline.rs change compiles
  + bus.rs unaffected).
- `cargo build --workspace --no-default-features` (no media; export.rs
  cfg-gated paths still compile).
- `cargo clippy --workspace --all-targets --features media -- -D warnings`.
- `cargo fmt --check`.

**LOC budget: ~150.** Cache lookup helpers + `Arc<Frame>` type-
threading in preview + export + parity test.

**Commit message:** `phase11(compositor-perf, task 3): freeze-segment
compose cache via Arc<Frame> identity`.

---

## Files-touched summary

| File | Tasks | Net LOC |
|---|---|---|
| `crates/video-coach-compositor/src/compositor.rs` | 0, 1, 2, 3 | +250 |
| `crates/video-coach-compositor/src/lib.rs` | 0, 3 | +30 |
| `crates/video-coach-compositor/tests/perf_smoke.rs` | 0 | +50 |
| `crates/video-coach-media/src/preview_pipeline.rs` | 3 | +10 |
| `crates/video-coach-media/src/export.rs` | 3 | +10 |
| `crates/video-coach-media/tests/parity_n_frames.rs` | 3 | +5 |
| **Total** | | **~355 LOC** |

Each task individually fits under 700 LOC; aggregate fits the plan's
~300-500 LOC scope estimate.

---

## Done criteria

- All 4 tasks committed (Task 0, Task 1, Task 2, Task 3).
- CI matrix green on macOS / Linux / Windows + media-tests.
- `parity_smoke.rs` (Phase 9) passes byte-for-byte.
- `parity_n_frames.rs` (Phase 10) passes byte-for-byte (N=30 frames
  including ~6 freeze-cache hits).
- `compose_tick_perf_smoke` (Plan #4 Task 0) passes; per-call ms log
  visible in CI.
- `pip_cache_rebuild_count` test asserts exactly 1 rebuild for N
  back-to-back compose calls with same source dim.
- `pooled_vbo_grows_on_capacity_miss` test asserts the pool grows
  exactly once for a capacity-doubling stroke.
- `freeze_cache_hit_returns_byte_identical_output` test asserts cache
  hits + byte-equality.
- No regressions in Phase 1–10 tests.
- PROGRESS.txt reflects each task + the Plan #4 SHIPPED line + CI
  run id.

---

## Known unknowns (sub-agent may need to make calls)

1. **Mutex-while-encoding ergonomics.** Holding the
   `pip_cache.lock()` for the duration of the render-pass encode is
   the simplest implementation but pessimal for theoretical concurrent
   compose calls. The clean alternative is to clone the `Arc`-wrapped
   pipeline OUT of the mutex, drop the lock, and use the cloned handle
   in the render pass. wgpu's `RenderPipeline` is `Arc`-shared
   internally (verified via wgpu 22 docs: handles are cheap
   reference-counted clones). Sub-agent picks the cleanest pattern;
   both produce byte-identical output.
2. **`write_buffer` semantics on lavapipe.** lavapipe's GL backend may
   defer the `write_buffer` to a different queue submission than the
   render-pass encode. wgpu 22's API contract says they're ordered
   within a single `queue.submit` call regardless of backend; the
   `parity_n_frames` test will catch any divergence. If lavapipe
   surfaces a real bug, fall back to `create_buffer_init` per call for
   the stroke VBO (Task 2 partial revert) and document.
3. **`Arc<Frame>` ergonomics across `Frame::clone`.** If
   threading `Arc<Frame>` through `compose_entry_frame` causes
   borrow-checker friction (e.g. the live source/webcam `Frame`s are
   held by-value in the driver loop, not by `Arc`), the alternative
   is to use `&Frame` as the cache identity via
   `std::ptr::from_ref(frame) as usize`. Pointer-eq holds for the
   lifetime of the borrow, which matches the call duration. Less
   robust than Arc-eq if the caller re-uses a stack buffer for
   different content (a slot rewrite pattern); acceptable for the
   Freeze case where the same `Frame` is re-passed each tick.
4. **`compose_tick_perf_smoke` baseline drift across CI runners.** If
   the 30-second ceiling is hit on a particularly slow lavapipe run
   (rare; current N=30 × baseline ~50ms = 1.5s on lavapipe), the
   ceiling stays generous. If the test flakes, relax to 60s; only
   the eprintln! log is the real signal.

---

## Closeout

(Filled in at the `READY_FOR_CLOSEOUT` stage with the final SHA, CI
run id, and any deviation notes from the orchestrator's pass through.
PROGRESS.txt's "Plan #4: compositor-perf" line gets flipped to
`[x] … SHIPPED <date>. CI run <id> green on all 4 jobs.` at the same
time.)
