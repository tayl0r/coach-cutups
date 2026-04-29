use crate::event::EventKind;
use crate::project::Clip;
use crate::stroke::Stroke;

#[derive(Debug, Clone, PartialEq)]
pub struct VisibleStroke {
    pub stroke: Stroke,
    pub first_point_record_time: f64,
    pub drawn_point_count: usize,
}

pub fn visible_strokes(clip: &Clip, t: f64) -> Vec<VisibleStroke> {
    let clear_all_times: Vec<f64> = clip
        .events
        .iter()
        .filter_map(|e| match e.kind {
            EventKind::ClearAll if e.record_time <= t => Some(e.record_time),
            _ => None,
        })
        .collect();

    let mut out = Vec::new();
    for ev in &clip.events {
        let s = match &ev.kind {
            EventKind::Stroke(s) => s,
            _ => continue,
        };
        let first_t = ev.record_time - s.points.last().map(|p| p.t).unwrap_or(0.0);
        if t < first_t {
            continue;
        }
        if let Some(auto) = s.auto_clear_after_seconds {
            if t >= first_t + auto {
                continue;
            }
        }
        if clear_all_times.iter().any(|c| *c > first_t && *c <= t) {
            continue;
        }

        let elapsed = t - first_t;
        let k = s
            .points
            .iter()
            .position(|p| p.t > elapsed)
            .unwrap_or(s.points.len());
        out.push(VisibleStroke {
            stroke: s.clone(),
            first_point_record_time: first_t,
            drawn_point_count: k,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::CommentaryEvent;
    use crate::stroke::{Rgba, StrokePoint};
    use crate::test_fixtures::{deterministic_uuid, test_clip};

    /// Mouse-down == mouse-up at the event's recordTime: a single point at
    /// t=0 in stroke-local time, so `firstPointRecordTime == event.recordTime`.
    fn instant_stroke(id_tag: &str) -> Stroke {
        Stroke {
            id: deterministic_uuid(id_tag),
            color: Rgba::RED,
            line_width: 0.005,
            points: vec![StrokePoint {
                x: 0.5,
                y: 0.5,
                t: 0.0,
            }],
            auto_clear_after_seconds: None,
        }
    }

    /// `point_count` evenly-spaced points over `duration_seconds`. The hosting
    /// event's recordTime is the END of the stroke.
    fn drag_stroke(id_tag: &str, duration_seconds: f64, point_count: usize) -> Stroke {
        debug_assert!(point_count >= 2, "drag_stroke needs >=2 points to space");
        let dt = duration_seconds / (point_count as f64 - 1.0);
        let points = (0..point_count)
            .map(|i| StrokePoint {
                x: 0.5,
                y: 0.5,
                t: i as f64 * dt,
            })
            .collect();
        Stroke {
            id: deterministic_uuid(id_tag),
            color: Rgba::RED,
            line_width: 0.005,
            points,
            auto_clear_after_seconds: None,
        }
    }

    fn make_clip(events: Vec<CommentaryEvent>) -> Clip {
        Clip {
            events,
            recording_duration: 100.0,
            ..test_clip()
        }
    }

    // The case the naive forward-walk misses: strokes added to `out` BEFORE
    // the .clearAll event is encountered. A correct algorithm must know about
    // every clearAll up to t before deciding stroke visibility.
    #[test]
    fn later_clear_all_clears_earlier_strokes_even_in_forward_order() {
        let a = instant_stroke("A");
        let b = instant_stroke("B");
        let c = instant_stroke("C");
        let clip = make_clip(vec![
            CommentaryEvent {
                record_time: 1.0,
                kind: EventKind::Stroke(a),
            },
            CommentaryEvent {
                record_time: 3.0,
                kind: EventKind::Stroke(b),
            },
            CommentaryEvent {
                record_time: 4.0,
                kind: EventKind::ClearAll,
            },
            CommentaryEvent {
                record_time: 5.0,
                kind: EventKind::Stroke(c.clone()),
            },
        ]);
        let visible = visible_strokes(&clip, 6.0);
        assert_eq!(
            visible.iter().map(|v| v.stroke.id).collect::<Vec<_>>(),
            vec![c.id]
        );
    }

    #[test]
    fn stroke_is_invisible_before_first_point_record_time() {
        // 1-second drag stroke ending at recordTime 5 → firstPointRecordTime = 4.
        let s = drag_stroke("S", 1.0, 10);
        let clip = make_clip(vec![CommentaryEvent {
            record_time: 5.0,
            kind: EventKind::Stroke(s),
        }]);
        assert!(visible_strokes(&clip, 3.5).is_empty());
        assert!(
            !visible_strokes(&clip, 4.0).is_empty(),
            "stroke should be visible at firstPointRecordTime"
        );
    }

    #[test]
    fn stroke_partially_visible_mid_draw_yields_correct_drawn_point_count() {
        // 10 points spaced 0.1s apart; stroke ends at recordTime 5 → firstPointRecordTime = 4.
        let s = drag_stroke("S", 1.0, 10);
        let clip = make_clip(vec![CommentaryEvent {
            record_time: 5.0,
            kind: EventKind::Stroke(s),
        }]);
        // At record-time 4.45 we're 0.45s into the stroke; points with t in
        // {0, 0.1, 0.2, 0.3, 0.4} are drawn (5). Point with t=0.5 is NOT yet drawn.
        let visible = visible_strokes(&clip, 4.45);
        assert_eq!(visible.len(), 1);
        assert_eq!(visible[0].drawn_point_count, 5);
        assert!((visible[0].first_point_record_time - 4.0).abs() < 1e-9);
    }

    #[test]
    fn auto_clear_makes_stroke_invisible_after_duration() {
        let s = Stroke {
            id: deterministic_uuid("S"),
            color: Rgba::RED,
            line_width: 0.005,
            points: vec![StrokePoint {
                x: 0.5,
                y: 0.5,
                t: 0.0,
            }],
            auto_clear_after_seconds: Some(5.0),
        };
        let clip = make_clip(vec![CommentaryEvent {
            record_time: 2.0, // firstPointRecordTime = 2
            kind: EventKind::Stroke(s),
        }]);
        assert_eq!(
            visible_strokes(&clip, 6.99).len(),
            1,
            "still visible just before auto-clear deadline"
        );
        assert_eq!(
            visible_strokes(&clip, 7.00).len(),
            0,
            "invisible at exactly firstPointRecordTime + autoClearAfterSeconds"
        );
    }

    #[test]
    fn clear_all_affects_earlier_strokes_but_not_later() {
        // Asymmetric: a stroke drawn BEFORE clearAll is gone; one drawn AFTER survives.
        let a = instant_stroke("A");
        let b = instant_stroke("B");
        let clip = make_clip(vec![
            CommentaryEvent {
                record_time: 1.0,
                kind: EventKind::Stroke(a),
            },
            CommentaryEvent {
                record_time: 2.0,
                kind: EventKind::ClearAll,
            },
            CommentaryEvent {
                record_time: 3.0,
                kind: EventKind::Stroke(b.clone()),
            },
        ]);
        assert_eq!(
            visible_strokes(&clip, 4.0)
                .iter()
                .map(|v| v.stroke.id)
                .collect::<Vec<_>>(),
            vec![b.id]
        );
    }
}
