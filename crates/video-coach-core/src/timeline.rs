use crate::event::EventKind;
use crate::project::Clip;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SegmentKind {
    Play,
    Freeze,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlaybackSegment {
    pub kind: SegmentKind,
    pub source_start: f64,
    pub out_duration: f64,
}

pub fn source_time_at(clip: &Clip, t: f64) -> f64 {
    let mut source_time = clip.start_source_seconds;
    let mut record_cursor = 0.0_f64;
    let mut rate = 1.0_f64;
    for ev in clip.events.iter().filter(|e| e.record_time <= t) {
        source_time += (ev.record_time - record_cursor) * rate;
        record_cursor = ev.record_time;
        match ev.kind {
            EventKind::Play => rate = 1.0,
            EventKind::Pause => rate = 0.0,
            EventKind::Skip { delta } => source_time += delta,
            EventKind::Stroke(_) | EventKind::ClearAll => {}
        }
    }
    source_time + (t - record_cursor) * rate
}

fn emit_segment(
    record_end: f64,
    segments: &mut Vec<PlaybackSegment>,
    source_cursor: &mut f64,
    record_cursor: &mut f64,
    rate: f64,
) {
    let dur = record_end - *record_cursor;
    if dur <= 0.0 {
        return;
    }
    let kind = if rate == 0.0 {
        SegmentKind::Freeze
    } else {
        SegmentKind::Play
    };
    segments.push(PlaybackSegment {
        kind,
        source_start: *source_cursor,
        out_duration: dur,
    });
    if rate == 1.0 {
        *source_cursor += dur;
    }
    *record_cursor = record_end;
}

pub fn playback_segments(clip: &Clip, source_duration: f64) -> Vec<PlaybackSegment> {
    let mut segments: Vec<PlaybackSegment> = Vec::new();
    let mut source_cursor = clip.start_source_seconds;
    let mut record_cursor = 0.0_f64;
    let mut rate = 1.0_f64;

    for ev in &clip.events {
        emit_segment(
            ev.record_time,
            &mut segments,
            &mut source_cursor,
            &mut record_cursor,
            rate,
        );
        match ev.kind {
            EventKind::Play => rate = 1.0,
            EventKind::Pause => rate = 0.0,
            EventKind::Skip { delta } => {
                source_cursor = (source_cursor + delta).clamp(0.0, source_duration);
            }
            EventKind::Stroke(_) | EventKind::ClearAll => {}
        }
    }
    emit_segment(
        clip.recording_duration,
        &mut segments,
        &mut source_cursor,
        &mut record_cursor,
        rate,
    );
    segments
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::CommentaryEvent;
    use crate::project::Clip;
    use crate::stroke::{Rgba, Stroke};
    use crate::test_fixtures::test_clip;
    use uuid::Uuid;

    fn clip_with(events: Vec<CommentaryEvent>, recording_duration: f64, start_source: f64) -> Clip {
        Clip {
            events,
            recording_duration,
            start_source_seconds: start_source,
            ..test_clip()
        }
    }

    #[test]
    fn empty_event_log_implies_constant_rate_one() {
        // Per Swift PlaybackTimelineTests.test_noEvents_advancesAtRate1:
        // sourceTime advances 1:1 with recordTime when there are no events.
        let c = clip_with(vec![], 10.0, 100.0);
        assert!((source_time_at(&c, 0.0) - 100.0).abs() < 1e-9);
        assert!((source_time_at(&c, 5.0) - 105.0).abs() < 1e-9);
        let segs = playback_segments(&c, 1000.0);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].kind, SegmentKind::Play);
        assert!((segs[0].out_duration - 10.0).abs() < 1e-9);
    }

    #[test]
    fn pause_event_creates_freeze_segment() {
        // Per Swift PlaybackTimelineTests.test_segments_pauseProducesFreezeAndPlaySegments.
        let evs = vec![
            CommentaryEvent {
                record_time: 2.0,
                kind: EventKind::Pause,
            },
            CommentaryEvent {
                record_time: 4.0,
                kind: EventKind::Play,
            },
        ];
        let c = clip_with(evs, 10.0, 10.0);
        let segs = playback_segments(&c, 1000.0);
        assert_eq!(segs.len(), 3);
        assert_eq!(segs[0].kind, SegmentKind::Play);
        assert_eq!(segs[1].kind, SegmentKind::Freeze);
        assert_eq!(segs[2].kind, SegmentKind::Play);
        assert!((segs[0].out_duration - 2.0).abs() < 1e-9);
        assert!((segs[1].out_duration - 2.0).abs() < 1e-9);
        assert!((segs[2].out_duration - 6.0).abs() < 1e-9);
    }

    #[test]
    fn pause_and_resume_freezes_source() {
        // Per Swift PlaybackTimelineTests.test_pauseAndResume_freezesSource.
        let evs = vec![
            CommentaryEvent {
                record_time: 2.0,
                kind: EventKind::Pause,
            },
            CommentaryEvent {
                record_time: 4.0,
                kind: EventKind::Play,
            },
        ];
        let c = clip_with(evs, 10.0, 100.0);
        assert!((source_time_at(&c, 1.0) - 101.0).abs() < 1e-9);
        assert!((source_time_at(&c, 3.0) - 102.0).abs() < 1e-9);
        assert!((source_time_at(&c, 5.0) - 103.0).abs() < 1e-9);
    }

    #[test]
    fn skip_forward_jumps_source_without_advancing_record() {
        // Per Swift PlaybackTimelineTests.test_skipForwardJumpsSourceWithoutAdvancingRecord.
        let evs = vec![CommentaryEvent {
            record_time: 2.0,
            kind: EventKind::Skip { delta: 3.0 },
        }];
        let c = clip_with(evs, 10.0, 100.0);
        assert!((source_time_at(&c, 1.0) - 101.0).abs() < 1e-9);
        assert!((source_time_at(&c, 2.0) - 105.0).abs() < 1e-9);
        assert!((source_time_at(&c, 3.0) - 106.0).abs() < 1e-9);
    }

    #[test]
    fn stroke_and_clear_all_are_no_ops_for_source_time() {
        // Per Swift PlaybackTimelineTests.test_strokeAndClearAllAreNoOps_forSourceTime.
        let stroke = Stroke {
            id: Uuid::nil(),
            color: Rgba::RED,
            line_width: 0.005,
            points: vec![],
            auto_clear_after_seconds: None,
        };
        let evs = vec![
            CommentaryEvent {
                record_time: 1.0,
                kind: EventKind::Stroke(stroke),
            },
            CommentaryEvent {
                record_time: 2.0,
                kind: EventKind::ClearAll,
            },
        ];
        let c = clip_with(evs, 10.0, 100.0);
        assert!((source_time_at(&c, 3.0) - 103.0).abs() < 1e-9);
    }

    #[test]
    fn segments_simple_clip_one_segment_entire_duration() {
        // Per Swift PlaybackTimelineTests.test_segments_simpleClip_oneSegmentEntireDuration.
        let c = clip_with(vec![], 10.0, 10.0);
        let segs = playback_segments(&c, 1000.0);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].kind, SegmentKind::Play);
        assert!((segs[0].source_start - 10.0).abs() < 1e-9);
        assert!((segs[0].out_duration - 10.0).abs() < 1e-9);
    }

    #[test]
    fn segments_clamp_source_to_bounds_on_skip() {
        // Per Swift PlaybackTimelineTests.test_segments_clampSourceToBounds_onSkip:
        // skip(delta: 100) from start 998 with sourceDuration 1000 clamps the
        // second segment's sourceStart to 1000.
        let evs = vec![CommentaryEvent {
            record_time: 1.0,
            kind: EventKind::Skip { delta: 100.0 },
        }];
        let c = clip_with(evs, 10.0, 998.0);
        let segs = playback_segments(&c, 1000.0);
        assert!((segs[1].source_start - 1000.0).abs() < 1e-9);
    }
}
