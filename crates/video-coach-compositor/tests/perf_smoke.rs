//! Phase 11 Plan #4 perf-regression smoke. Runs N=30 `compose_tick` calls
//! on the same `Compositor` and logs per-call wall-clock ms. Asserts
//! per-call max stays under a generous 5000 ms ceiling and total under a
//! generous 60 s ceiling (lavapipe + CI host contention headroom). The
//! ASSERTIONS are regression floors; the LOG is the actual signal future
//! readers diff against.
//!
//! Per Fix #46: per-call max is the robust signal — total can be skewed
//! by GC/swap/host pre-emption. Both checks ship.

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
    let max_ms = per_call_ms
        .iter()
        .cloned()
        .fold(f64::NEG_INFINITY, f64::max);
    let min_ms = per_call_ms.iter().cloned().fold(f64::INFINITY, f64::min);
    let avg_ms = per_call_ms.iter().sum::<f64>() / N as f64;
    eprintln!(
        "compose_tick_perf_smoke: N={N} total={:.1}ms avg={:.2}ms \
         min={:.2}ms max={:.2}ms",
        total.as_secs_f64() * 1e3,
        avg_ms,
        min_ms,
        max_ms,
    );
    // Fix #46: 60 s total ceiling (lavapipe + CI host contention headroom).
    assert!(
        total.as_secs_f64() < 60.0,
        "compose_tick × {N} took {:.1}s (ceiling 60s) — perf regression?",
        total.as_secs_f64()
    );
    // Fix #46: per-call max is the robust signal (total can be skewed
    // by GC/swap/host pre-emption).
    assert!(
        max_ms < 5_000.0,
        "compose_tick max per-call {max_ms:.1}ms (ceiling 5000ms)",
    );
}
