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

Inline adversarial pass (orchestrator, 2026-05-01). 11 findings raised;
all 11 folded (some trimmed). Phase 10's 40 baked-in fixes were treated
as off-limits. Findings are net-new to Plan #4. Triage discipline: REAL =
reproducible + cites concrete code/CI failure → fold; OVERSTATED = real
but smaller → fold trimmed; SPECULATIVE = no concrete trigger → reject.

Reference: full reviewer notes saved at
`/tmp/phase11-plans/plan-4/adv-review.md`.

### Fix #41 [HIGH, F1] — Drop cache-Mutex guard BEFORE GPU encode/submit

The plan's Task-1 lookup snippet (lines 412–445 of the original draft)
held the `pip_cache` MutexGuard for "the rest of compose" — i.e. across
`begin_render_pass`, `set_pipeline`, `draw`, `queue.submit`, and
`device.poll(Wait)`. On lavapipe `device.poll(Wait)` blocks tens of ms
waiting for the GPU; holding a Mutex that long defeats the
"theoretically-not-contended" claim AND turns any future parallel
`compose` (e.g. parallel-tag export) into a sequential bottleneck. Worse,
a panic anywhere inside the encode (e.g. `bytemuck::cast_slice`
mis-alignment) poisons the lock indefinitely.

**Baked-in requirement** (was Known-unknown #1; now mandatory): every
cache lookup MUST be `lookup → clone-handles → drop guard → encode`.
wgpu 22's `RenderPipeline`, `PipelineLayout`, `BindGroupLayout`,
`Sampler`, `ShaderModule`, and `Buffer` are all `Clone` (refcounted-Arc
internally). Pseudocode:

```rust
let (pipeline, bgl, sampler) = {
    let mut g = self.pip_cache.lock().expect("pip_cache poisoned");
    if g.as_ref().map(|c| c.key != pip_key).unwrap_or(true) {
        *g = Some(self.build_pip_cache(pip_key));
    }
    let c = g.as_ref().expect("populated above");
    (c.pipeline.clone(), c.bind_group_layout.clone(), c.sampler.clone())
}; // guard dropped here
// …encode using cloned handles…
```

Same shape for `stroke_cache` (Task 1), `stroke_vbo_pool` (Task 2 —
clone the `wgpu::Buffer` handle out, then `queue.write_buffer` +
`set_vertex_buffer` outside the lock), and `freeze_cache` (Task 3 —
clone the `Arc<Frame>` out, drop guard, return).

### Fix #42 [HIGH, F2] — `PipPassKey` cache-key intent comment

`PipPassKey { source_w, source_h }` over-keys (the pipeline + BGL are
dimension-agnostic — fullscreen-triangle vertex shader, UV-sampled
fragment) but does NOT under-key, because nothing in the cached state
depends on webcam dims (`pip_rect()`'s output goes into the per-call
uniform, not the pipeline). Adding webcam dims to the key would cause
spurious rebuilds when consecutive clips have different webcam-frame
dimensions.

**Baked-in code-comment requirement** above the `PipPassKey` struct:

```rust
// Cache key intent: the cached pipeline + BGL are dimension-agnostic
// (vs_fullscreen has no per-instance state, fs_pip samples by UV, the
// PiP rect goes through a per-call uniform buffer — see compose's
// `uniform_buf` at the call site). Including webcam_w/h or output
// dimensions would cause spurious rebuilds across clips with different
// webcam shapes WITHOUT improving correctness. If a future change adds
// dimension-baked constants to the shader (e.g. HDR / 10-bit work), the
// key MUST grow accordingly. Audit by inspecting shaders/pip.wgsl.
```

### Fix #43 [HIGH, F3] — Freeze cache key MUST resist Arc-pointer-address reuse

`Arc::as_ptr(&arc) as usize` is unstable across drop-then-allocate: the
allocator can reuse a freed slot, producing identical `usize` keys for
distinct `Arc<Frame>` allocations. In production this matters at clip
boundaries: when entry N+1's `frozen_frames` map is built after entry
N's is dropped, an address reuse collides the cache → returns the
PREVIOUS entry's composed frame. Pixel divergence; parity test catches
it post-hoc but only after a wrong export ships.

**Baked-in defense-in-depth (cheap):**

(1) Strengthen `FreezeCacheKey` with a content-derived prefix:

```rust
#[derive(Clone, PartialEq, Eq, Hash)]
pub(crate) struct FreezeCacheKey {
    pub source_ptr: usize,           // Arc::as_ptr cast
    pub source_w: u32,
    pub source_h: u32,
    pub source_pixels_len: usize,
    pub source_first16: [u8; 16],    // pixels[0..16]
    pub webcam_ptr: usize,
    pub webcam_w: u32,
    pub webcam_h: u32,
    pub webcam_pixels_len: usize,
    pub webcam_first16: [u8; 16],
    pub stroke_hash: u64,
}
```

`first16 + len + dims` cost: 64 bytes/key, two-pixel-row-prefix copy +
`(w, h, len)` reads. Negligible vs the 8 MB compose work being cached.

(2) Add `Compositor::clear_freeze_cache()` (`pub`, `&self`, locks +
clears the Vec) and call it from the export driver's `for entry in
entries` top-of-loop AND from the preview driver's segment-transition
edge. This is the principled GC: caches are bounded to one entry's
lifetime in production. Tasks 3 must wire both call sites.

### Fix #44 [HIGH, F4] — Cache stores `Arc<Frame>`; `compose_with_identity` returns `Arc<Frame>`

Storing `Frame` and returning `Frame` from the cached path means TWO 8
MB clones per cache miss + ONE per hit. At 16-entry × 8 MB peak + 16 MB
of clone-traffic per call, this can push CI lavapipe runners over their
working-set ceiling.

**Baked-in API shape (new method ships correct from day one):**

```rust
// Storage:
pub(crate) struct FreezeCache {
    pub entries: Vec<(FreezeCacheKey, Arc<Frame>)>,
}

// Public API:
pub fn compose_with_identity(
    &self,
    source: &Arc<Frame>,
    webcam: &Arc<Frame>,
    strokes: &[VisibleStroke],
) -> Result<Arc<Frame>, CompositorError> { … }
```

The two production callers (export's `compose_entry_frame` + preview's
driver loop) accept `Arc<Frame>` return + adapt their downstream
consumers (one signature change each — driver's `frame_sink.push(frame)`
takes `Frame`, so an `Arc::try_unwrap().unwrap_or_else(|a|
(*a).clone())` adapter is needed if the Arc is shared at that point;
typically not — the cache holds the only other Arc, so try_unwrap
succeeds and avoids a clone). The existing `compose` / `compose_tick`
free functions keep returning `Frame` — backward compat for the parity
tests + uncached callers.

`compose_tick_with_identity` mirrors with `Arc<Frame>` in/out.

### Fix #45 [MEDIUM, F5] — Stroke-set hash spec: explicit f64 bit-cast + length prefix

`f64: !Hash` (compile error); naive hashing of
`first_point_record_time` won't compile and sub-agent might pick a
wrong workaround.

**Baked-in spec:**

```rust
fn hash_stroke_set(strokes: &[VisibleStroke]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    (strokes.len() as u64).hash(&mut h);  // length prefix
    for vs in strokes {
        vs.stroke.id.as_u128().hash(&mut h);
        (vs.drawn_point_count as u64).hash(&mut h);
        vs.first_point_record_time.to_bits().hash(&mut h);
    }
    h.finish()
}
```

Plus a unit test `stroke_hash_distinguishes_drawn_count` (two
VisibleStrokes differing only in `drawn_point_count` produce different
hashes) AND `stroke_hash_length_prefix_disambiguates` (single empty
stroke vs no strokes hash differently).

### Fix #46 [MEDIUM, F6] — `compose_tick_perf_smoke` ceiling 60s + assert per-call max, not total

30 s ceiling on N=30 calls = 1 s/call max; lavapipe under host
contention + first-call shader compile can overrun. Total-ms is also
the wrong signal — a single GC/swap stall skews it; per-call max is
robust.

**Baked-in spec:**

```rust
let max_ms = per_call_ms.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
assert!(
    total.as_secs_f64() < 60.0,
    "compose_tick × {N} took {:.1}s (ceiling 60s) — perf regression?",
    total.as_secs_f64()
);
assert!(
    max_ms < 5_000.0,
    "compose_tick max per-call {:.1}ms (ceiling 5000ms)",
    max_ms
);
```

### Fix #47 [MEDIUM, F7] — Cache-rebuild counters: `AtomicU64` + `pub(crate)` accessor crate-local

Plan called for `#[cfg(test)] pub fn pip_cache_rebuild_count`; ambiguous
on shape and visibility. Spec:

```rust
// On Compositor:
#[cfg(test)]
pub(crate) pip_cache_rebuilds: std::sync::atomic::AtomicU64,
#[cfg(test)]
pub(crate) stroke_vbo_grows: std::sync::atomic::AtomicU64,
#[cfg(test)]
pub(crate) freeze_cache_hits: std::sync::atomic::AtomicU64,

// Accessor (crate-local; only used by compositor.rs::tests):
#[cfg(test)]
pub(crate) fn pip_cache_rebuilds(&self) -> u64 {
    self.pip_cache_rebuilds.load(std::sync::atomic::Ordering::Relaxed)
}
```

Increment with `Relaxed` ordering at each rebuild/grow/hit point. No
cross-crate exposure; the new tests live inside `compositor.rs::tests`
where `pub(crate)` is reachable. `parity_n_frames.rs` (cross-crate)
remains a behavioral parity test, not a counter-introspection test.

### Fix #48 [MEDIUM, F8] — `frozen_frames` `Arc<Frame>` wrapping happens at call-site, not in helper signatures

Plan's Task-3 file list omitted `pre_decode_freeze_frames` (preview) and
`pre_decode_all_freeze_frames` (export). Don't change those helper
signatures; wrap at the consumer boundary instead — lower blast radius,
preserves Phase 10 fix #11's stable surface.

**Baked-in pattern (preview_pipeline.rs around line 174–219):**

```rust
let frozen_frames_raw = pre_decode_freeze_frames(source_path, clip, &segments)?;
let frozen_frames: HashMap<usize, Arc<Frame>> = frozen_frames_raw
    .into_iter()
    .map(|(k, v)| (k, Arc::new(v)))
    .collect();
let frozen_frames_arc = Arc::new(frozen_frames);
```

Same pattern in export.rs at the `pre_decode_all_freeze_frames` consumer
boundary. Helper signatures unchanged.

### Fix #49 [MEDIUM, F9] — Memory-usage docstring + closeout note

128 MB peak for the freeze cache is acceptable but must be discoverable.

**Baked-in additions:**

(1) Extend `compose_tick`'s docstring with: "Internal caches total
~128 MB peak at 1080p RGBA (16-entry freeze cache of `Arc<Frame>`
composed outputs + small pipeline / VBO state). Per-process. Single
shared `Arc<Compositor>` per Phase 10 fix #15."

(2) Add a Closeout bullet (filled at READY_FOR_CLOSEOUT stage):
"Peak compositor memory: ~128 MB (16-entry freeze cache × 8 MB
1080p RGBA). Documented in compose_tick docstring."

### Fix #50 [LOW, F10] — `debug_assert!(!vertices.is_empty())` in `encode_stroke_pass`

Today's call site at line 372–373 of compositor.rs guards against empty
vertex slices reaching `encode_stroke_pass` (Vulkan validation rejects
zero-sized vertex-buffer slices on some backends). Pooled-VBO Task 2
preserves the guard; lock it in with a 1-line `debug_assert` at the top
of `encode_stroke_pass`:

```rust
fn encode_stroke_pass(...) {
    debug_assert!(
        !vertices.is_empty(),
        "encode_stroke_pass called with empty vertices; caller must guard"
    );
    ...
}
```

### Fix #51 [LOW, F11] — Poison-recovery scoped to user-data path only

The plan's `tracing::warn!` + `into_inner()` recovery applied at every
cache lookup is over-engineered for the pure-compute paths
(`pip_cache`, `stroke_cache`, `stroke_vbo_pool`) — a panic in
pipeline-build is a real bug; let the next compose panic too. KEEP the
recovery for `freeze_cache` (user-data path; corruption-free recovery
is reasonable).

**Baked-in pattern:**

- `pip_cache`, `stroke_cache`, `stroke_vbo_pool`:
  `lock().expect("compose lock poisoned")` — let panic propagate.
- `freeze_cache`: keep the `match { Ok(g) => …, Err(p) => warn! +
  p.into_inner() }` recovery.

### Rejected findings

(None — all 11 reviewer findings folded above. F2 was doc-only,
F10/F11 were OVERSTATED but the trimmed forms still ship as 1-line
fixes.)

---

## Cache infrastructure design

### `Compositor` struct extensions

```rust
pub struct Compositor {
    pub(crate) device: wgpu::Device,
    pub(crate) queue: wgpu::Queue,

    // Plan #4 Task 1: cached PiP + stroke pipelines, rebuilt only when
    // the key changes. wgpu handles inside (RenderPipeline / BGL /
    // Sampler / ShaderModule) are Clone (refcounted Arc). Per Fix #41,
    // the lock is held only for cache-lookup-and-clone-out; encode
    // happens unlocked.
    pip_cache: std::sync::Mutex<Option<PipPassCache>>,
    stroke_cache: std::sync::Mutex<Option<StrokePassCache>>,

    // Plan #4 Task 2: pooled stroke vertex buffer. Capacity grows on
    // demand; never shrinks. wgpu::Buffer is Clone — same lock
    // discipline as Task 1 (clone-out, drop, encode).
    stroke_vbo_pool: std::sync::Mutex<Option<PooledVbo>>,

    // Plan #4 Task 3: freeze-segment compose memoization. LRU bounded
    // at 16 entries (~128 MB peak at 1080p RGBA — disclosed in
    // compose_tick docstring per Fix #49). Key includes content-derived
    // prefix bytes per Fix #43 to defend against allocator address
    // reuse. Value is Arc<Frame> (Fix #44) so cache hits don't memcpy.
    freeze_cache: std::sync::Mutex<FreezeCache>,

    // Plan #4: test-only counters for cache-rebuild assertions
    // (Fix #47). Crate-local; not visible to other crates' tests.
    #[cfg(test)]
    pub(crate) pip_cache_rebuilds: std::sync::atomic::AtomicU64,
    #[cfg(test)]
    pub(crate) stroke_cache_rebuilds: std::sync::atomic::AtomicU64,
    #[cfg(test)]
    pub(crate) stroke_vbo_grows: std::sync::atomic::AtomicU64,
    #[cfg(test)]
    pub(crate) freeze_cache_hits: std::sync::atomic::AtomicU64,
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
/// **Phase 11 Plan #4 cache contract:** `Compositor` holds four
/// internal caches (PiP pipeline, stroke pipeline, pooled stroke VBO,
/// and a freeze-segment compose LRU). All are populated lazily inside
/// `compose` / `compose_with_identity` under interior-mutex'd state;
/// cache hits MUST produce byte-identical output to cache misses (a
/// parity divergence is a ship-blocker). Tests in `parity_smoke.rs`
/// and `parity_n_frames.rs` guard the invariant. Compositor is no
/// longer "stateless from the inside" but its EXTERNAL contract (same
/// input → same output) is unchanged.
///
/// Per Fix #49: internal caches total ~128 MB peak at 1080p RGBA
/// (16-entry freeze cache of `Arc<Frame>` composed outputs + small
/// pipeline / VBO state). Per-process. Single shared
/// `Arc<Compositor>` per Phase 10 fix #15.
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
    let max_ms = per_call_ms.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    eprintln!(
        "compose_tick_perf_smoke: N={N} total={:.1}ms avg={:.2}ms \
         min={:.2}ms max={:.2}ms",
        total.as_secs_f64() * 1e3,
        per_call_ms.iter().sum::<f64>() / N as f64,
        per_call_ms.iter().cloned().fold(f64::INFINITY, f64::min),
        max_ms,
    );
    // Fix #46: 60s ceiling (lavapipe + CI host contention headroom).
    assert!(
        total.as_secs_f64() < 60.0,
        "compose_tick × {N} took {:.1}s (ceiling 60s) — perf regression?",
        total.as_secs_f64()
    );
    // Fix #46: per-call max is the robust signal (total can be skewed
    // by GC/swap/host pre-emption).
    assert!(
        max_ms < 5_000.0,
        "compose_tick max per-call {:.1}ms (ceiling 5000ms)",
        max_ms
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

In `compose`, after computing `(w, h)` — **per Fix #41 + Fix #51, the
guard MUST be dropped before encoding; clone-handles-out:**

```rust
let pip_key = PipPassKey { source_w: w, source_h: h };
let (pipeline, bgl, sampler) = {
    let mut g = self.pip_cache.lock().expect("pip_cache poisoned");
    let needs_rebuild = g.as_ref().map(|c| c.key != pip_key).unwrap_or(true);
    if needs_rebuild {
        #[cfg(test)]
        self.pip_cache_rebuilds
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        *g = Some(self.build_pip_cache(pip_key));
    }
    let c = g.as_ref().expect("populated above");
    // wgpu 22: RenderPipeline / BindGroupLayout / Sampler are Clone
    // (refcounted Arc internally); cheap to clone, safe to use after
    // the guard drops.
    (c.pipeline.clone(), c.bind_group_layout.clone(), c.sampler.clone())
};
// guard dropped — encode happens unlocked
```

Then in the render-pass encode block (lines 343–362), use the cloned
`pipeline` and `bgl` (for the per-call `create_bind_group` call) instead
of the freshly-built ones.

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
written via `Queue::write_buffer`. Per Fix #41 + Fix #51 the lock is
held only for cache-lookup + clone-out (and the rare grow-allocate);
the `write_buffer` + `set_vertex_buffer` happen on the cloned handle
outside the lock:

```rust
debug_assert!(!vertices.is_empty(), "encode_stroke_pass empty"); // Fix #50
let bytes = bytemuck::cast_slice(vertices);
let needed = bytes.len();

let buffer = {
    let mut g = self.stroke_vbo_pool
        .lock()
        .expect("stroke_vbo_pool poisoned"); // Fix #51 (pure-compute path)
    let need_grow = match g.as_ref() {
        None => true,
        Some(p) => p.capacity_vertices * std::mem::size_of::<StrokeVertex>() < needed,
    };
    if need_grow {
        #[cfg(test)]
        self.stroke_vbo_grows
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        // Round up to next power-of-2 vertices to amortize regrow cost.
        // Floor of 64 vertices (~one short stroke segment).
        let new_cap = vertices.len().next_power_of_two().max(64);
        let new_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("stroke-vbo-pool"),
            size: (new_cap * std::mem::size_of::<StrokeVertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        *g = Some(PooledVbo { buffer: new_buffer, capacity_vertices: new_cap });
    }
    g.as_ref().expect("populated above").buffer.clone() // wgpu::Buffer is Clone
}; // guard dropped

self.queue.write_buffer(&buffer, 0, bytes);
// In the render pass:
rpass.set_vertex_buffer(0, buffer.slice(..bytes.len() as u64));
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

**Cache lookup flow** — per Fix #43 + Fix #44, the new method takes
`&Arc<Frame>` (not `&Frame`) and returns `Arc<Frame>`. The cache key
includes content-derived prefix bytes to defend against allocator
address reuse. Existing `compose` / `compose_tick` keep their `&Frame`
+ `Frame` shape (uncached path; backward compat for tests + simple
callers):

```rust
// New method (Plan #4):
pub fn compose_with_identity(
    &self,
    source: &Arc<Frame>,
    webcam: &Arc<Frame>,
    strokes: &[VisibleStroke],
) -> Result<Arc<Frame>, CompositorError> {
    let key = FreezeCacheKey {
        source_ptr: Arc::as_ptr(source) as usize,
        source_w: source.width,
        source_h: source.height,
        source_pixels_len: source.pixels.len(),
        source_first16: first16_or_zero(&source.pixels),
        webcam_ptr: Arc::as_ptr(webcam) as usize,
        webcam_w: webcam.width,
        webcam_h: webcam.height,
        webcam_pixels_len: webcam.pixels.len(),
        webcam_first16: first16_or_zero(&webcam.pixels),
        stroke_hash: hash_stroke_set(strokes),
    };

    // Fast path: cache hit (clone-Arc-out under lock; encode unblocked)
    if let Some(cached) = self.lookup_freeze(&key) {
        #[cfg(test)]
        self.freeze_cache_hits
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        return Ok(cached);
    }

    // Slow path: compose, then insert.
    let composed = self.compose(source, webcam, strokes)?;
    let arc_composed = Arc::new(composed);
    self.insert_freeze(key, arc_composed.clone());
    Ok(arc_composed)
}

pub fn clear_freeze_cache(&self) {
    let mut g = match self.freeze_cache.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    g.entries.clear();
}

fn first16_or_zero(pixels: &[u8]) -> [u8; 16] {
    let mut out = [0u8; 16];
    let n = pixels.len().min(16);
    out[..n].copy_from_slice(&pixels[..n]);
    out
}
```

`compose_tick` in `lib.rs` gets a sibling
`compose_tick_with_identity(compositor, &Arc<Frame>, &Arc<Frame>,
&[VisibleStroke]) -> Result<Arc<Frame>, …>`. Both wrap the same
underlying logic. Production paths (export's `compose_entry_frame` +
preview's driver loop) call the new one; tests stick with the existing
`compose_tick`. Both production sites call
`compositor.clear_freeze_cache()` at entry-segment transitions per Fix
#43 (export driver: top of `for entry in entries`; preview driver:
on segment-transition edge).

**Stroke hashing**: `hash_stroke_set(strokes: &[VisibleStroke]) -> u64`
hashes the visible-portion of each stroke (id + drawn_point_count +
first_point_record_time). The full point-list isn't needed — strokes
are immutable once captured; (id, drawn_count) uniquely identifies the
visible state. Use `std::hash::DefaultHasher` (cheap, non-crypto). The
hash is for cache keying, not security.

**LRU eviction (`insert_freeze`)** — per Fix #44 stores `Arc<Frame>`,
per Fix #51 keeps poison-recovery on this user-data path:

```rust
fn insert_freeze(&self, key: FreezeCacheKey, frame: Arc<Frame>) {
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

fn lookup_freeze(&self, key: &FreezeCacheKey) -> Option<Arc<Frame>> {
    let g = match self.freeze_cache.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    g.entries.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
}
```

**`Frame::clone` cost** — eliminated by storing `Arc<Frame>` per Fix
#44. Cache hit clones an Arc handle (cheap atomic refcount bump), not
8 MB of pixels. Cache miss allocates one `Arc<Frame>`. Net memcpy on
cache hit: zero. Net allocation on cache miss: one (the `Arc::new`
boxing of the composed frame). The cache win is amortizing the **GPU
compose** (~5–15 ms Apple Silicon, ~50–100 ms lavapipe); the
Arc-handle-clone is sub-microsecond.

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

**LOC budget: ~180.** Cache lookup helpers + content-prefix key (Fix
#43) + `clear_freeze_cache` + segment-edge call sites + `Arc<Frame>`
type-threading in preview + export + parity test. Original ~150 + ~30
for Fix #43's content-prefix key + clear_freeze_cache wiring.

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
| **Total** | | **~385 LOC** (+30 for adv-review fixes #43/#48) |

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
