use crate::project::{Clip, Project};
use crate::timeline::{playback_segments, PlaybackSegment};
use std::collections::HashMap;
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq)]
pub struct CompilationEntry {
    pub clip_id: Uuid,
    pub index_in_output: usize,
    pub composition_start: f64,
    pub segments: Vec<PlaybackSegment>,
    pub recording_duration: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CompilationPlan {
    pub total_duration_seconds: f64,
    pub entries: Vec<CompilationEntry>,
}

impl Project {
    pub fn compilation_plan_for(
        &self,
        tag: &str,
        source_durations: &HashMap<usize, f64>,
    ) -> CompilationPlan {
        let filtered: Vec<&Clip> = self
            .clips
            .iter()
            .filter(|c| c.tags.iter().any(|t| t == tag))
            .collect();
        build_plan(&filtered, source_durations)
    }

    pub fn all_clips_compilation_plan(
        &self,
        source_durations: &HashMap<usize, f64>,
    ) -> CompilationPlan {
        let all: Vec<&Clip> = self.clips.iter().collect();
        build_plan(&all, source_durations)
    }
}

fn build_plan(clips: &[&Clip], source_durations: &HashMap<usize, f64>) -> CompilationPlan {
    let mut ordered: Vec<&Clip> = clips.to_vec();
    ordered.sort_by_key(|c| c.sort_index);
    let mut entries = Vec::with_capacity(ordered.len());
    let mut cursor = 0.0_f64;
    for (i, clip) in ordered.iter().enumerate() {
        // Fall back to a duration that never causes the segment builder to clamp
        // a forward skip (the only place it consults sourceDuration). The sum
        // start_source + recording_duration is the smallest value guaranteed to
        // cover any in-range source position the clip visits at rate=1.
        let source_duration = source_durations
            .get(&clip.source_index)
            .copied()
            .unwrap_or(clip.start_source_seconds + clip.recording_duration);
        let segments = playback_segments(clip, source_duration);
        entries.push(CompilationEntry {
            clip_id: clip.id,
            index_in_output: i,
            composition_start: cursor,
            segments,
            recording_duration: clip.recording_duration,
        });
        cursor += clip.recording_duration;
    }
    CompilationPlan {
        total_duration_seconds: cursor,
        entries,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{CommentaryEvent, EventKind};
    use crate::test_fixtures::test_clip;

    fn make_clip(
        name: &str,
        tags: Vec<&str>,
        source_index: usize,
        start_source_seconds: f64,
        recording_duration: f64,
        sort_index: i64,
        events: Vec<CommentaryEvent>,
    ) -> Clip {
        Clip {
            name: name.to_string(),
            tags: tags.into_iter().map(String::from).collect(),
            source_index,
            start_source_seconds,
            recording_duration,
            recording_filename: format!("{name}.mov"),
            events,
            sort_index,
            ..test_clip()
        }
    }

    fn durations(pairs: &[(usize, f64)]) -> HashMap<usize, f64> {
        pairs.iter().copied().collect()
    }

    #[test]
    fn compilation_plan_filters_by_tag_excluding_clips_without_tag() {
        let mut project = Project::new("p");
        project.clips = vec![
            make_clip("a", vec!["forehand"], 0, 0.0, 5.0, 0, vec![]),
            make_clip("b", vec!["backhand"], 0, 10.0, 4.0, 1, vec![]),
            make_clip("c", vec!["forehand", "serve"], 0, 20.0, 3.0, 2, vec![]),
        ];

        let plan = project.compilation_plan_for("forehand", &durations(&[(0, 100.0)]));

        let ids: Vec<Uuid> = plan.entries.iter().map(|e| e.clip_id).collect();
        assert_eq!(ids, vec![project.clips[0].id, project.clips[2].id]);
    }

    #[test]
    fn compilation_plan_sorts_by_sort_index_ascending() {
        let mut project = Project::new("p");
        project.clips = vec![
            make_clip("later", vec!["t"], 0, 0.0, 5.0, 9, vec![]),
            make_clip("earlier", vec!["t"], 0, 0.0, 5.0, 1, vec![]),
            make_clip("middle", vec!["t"], 0, 0.0, 5.0, 4, vec![]),
        ];

        let plan = project.compilation_plan_for("t", &durations(&[(0, 100.0)]));

        let ids: Vec<Uuid> = plan.entries.iter().map(|e| e.clip_id).collect();
        assert_eq!(
            ids,
            vec![
                project.clips[1].id,
                project.clips[2].id,
                project.clips[0].id
            ]
        );
    }

    #[test]
    fn compilation_plan_composition_start_accumulates_preceding_durations() {
        let mut project = Project::new("p");
        project.clips = vec![
            make_clip("a", vec!["t"], 0, 0.0, 4.0, 0, vec![]),
            make_clip("b", vec!["t"], 0, 0.0, 7.0, 1, vec![]),
            make_clip("c", vec!["t"], 0, 0.0, 2.0, 2, vec![]),
        ];

        let plan = project.compilation_plan_for("t", &durations(&[(0, 100.0)]));

        assert_eq!(plan.entries.len(), 3);
        assert!((plan.entries[0].composition_start - 0.0).abs() < 1e-9);
        assert!((plan.entries[1].composition_start - 4.0).abs() < 1e-9);
        assert!((plan.entries[2].composition_start - 11.0).abs() < 1e-9);
        assert!((plan.total_duration_seconds - 13.0).abs() < 1e-9);
    }

    #[test]
    fn compilation_plan_index_in_output_is_zero_based_and_monotonic() {
        let mut project = Project::new("p");
        project.clips = vec![
            make_clip("a", vec!["t"], 0, 0.0, 1.0, 5, vec![]),
            make_clip("b", vec!["t"], 0, 0.0, 1.0, 7, vec![]),
        ];

        let plan = project.compilation_plan_for("t", &durations(&[(0, 10.0)]));

        let idxs: Vec<usize> = plan.entries.iter().map(|e| e.index_in_output).collect();
        assert_eq!(idxs, vec![0, 1]);
    }

    #[test]
    fn compilation_plan_empty_tag_yields_zero_entries_and_zero_duration() {
        let mut project = Project::new("p");
        project.clips = vec![make_clip("a", vec!["forehand"], 0, 0.0, 5.0, 0, vec![])];

        let plan = project.compilation_plan_for("missing", &durations(&[(0, 100.0)]));

        assert!(plan.entries.is_empty());
        assert!((plan.total_duration_seconds - 0.0).abs() < 1e-9);
    }

    #[test]
    fn all_clips_compilation_plan_includes_every_clip_ordered_by_sort_index() {
        let mut project = Project::new("p");
        project.clips = vec![
            make_clip("tagged", vec!["t"], 0, 0.0, 3.0, 1, vec![]),
            make_clip("untagged", vec![], 0, 0.0, 2.0, 0, vec![]),
            make_clip("another", vec!["x", "y"], 0, 0.0, 4.0, 2, vec![]),
        ];

        let plan = project.all_clips_compilation_plan(&durations(&[(0, 100.0)]));

        let ids: Vec<Uuid> = plan.entries.iter().map(|e| e.clip_id).collect();
        assert_eq!(
            ids,
            vec![
                project.clips[1].id,
                project.clips[0].id,
                project.clips[2].id
            ]
        );
        let idxs: Vec<usize> = plan.entries.iter().map(|e| e.index_in_output).collect();
        assert_eq!(idxs, vec![0, 1, 2]);
        assert!((plan.total_duration_seconds - 9.0).abs() < 1e-9);
        assert!((plan.entries[0].composition_start - 0.0).abs() < 1e-9);
        assert!((plan.entries[1].composition_start - 2.0).abs() < 1e-9);
        assert!((plan.entries[2].composition_start - 5.0).abs() < 1e-9);
    }

    #[test]
    fn compilation_plan_segments_use_source_duration_for_corresponding_clip() {
        // A clip with a forward skip event near the source's end exercises
        // playback_segments' clamp-to-sourceDuration path, proving the plan
        // forwards the right per-clip duration.
        let clip = make_clip(
            "edge",
            vec!["t"],
            7,
            998.0,
            3.0,
            0,
            vec![CommentaryEvent {
                record_time: 1.0,
                kind: EventKind::Skip { delta: 100.0 },
            }],
        );
        let mut project = Project::new("p");
        project.clips = vec![clip.clone()];

        let plan = project.compilation_plan_for("t", &durations(&[(7, 1000.0)]));

        assert_eq!(plan.entries.len(), 1);
        let segs = &plan.entries[0].segments;
        let expected = playback_segments(&clip, 1000.0);
        assert_eq!(segs, &expected);
        assert!((segs[1].source_start - 1000.0).abs() < 1e-9);
    }

    #[test]
    fn compilation_plan_recording_duration_per_entry_matches_clip() {
        let mut project = Project::new("p");
        project.clips = vec![make_clip("a", vec!["t"], 0, 0.0, 6.25, 0, vec![])];

        let plan = project.compilation_plan_for("t", &durations(&[(0, 100.0)]));

        assert!((plan.entries[0].recording_duration - 6.25).abs() < 1e-9);
    }

    #[test]
    fn compilation_plan_missing_source_duration_falls_back_gracefully() {
        let clip = make_clip("fb", vec!["t"], 3, 0.0, 5.0, 0, vec![]);
        let mut project = Project::new("p");
        project.clips = vec![clip];

        let plan = project.compilation_plan_for("t", &HashMap::new());

        assert_eq!(plan.entries.len(), 1);
        let segs = &plan.entries[0].segments;
        assert!(!segs.is_empty());
        let total: f64 = segs.iter().map(|s| s.out_duration).sum();
        assert!((total - 5.0).abs() < 1e-9);
    }
}
