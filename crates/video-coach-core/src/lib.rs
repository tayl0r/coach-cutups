pub mod compilation_plan;
pub mod denormalize;
pub mod event;
pub mod export_settings;
pub mod project;
pub mod project_store;
pub mod stroke;
pub mod stroke_replay;
pub mod tag_aggregation;
pub mod timeline;

#[cfg(test)]
pub(crate) mod test_fixtures;

// Top-level re-exports for the load-bearing data types so downstream crates
// (Phase 2+) can `use video_coach_core::Project` without long module paths.
// Functions and module-private types stay at their module paths.
pub use compilation_plan::{CompilationEntry, CompilationPlan};
pub use event::{CommentaryEvent, EventKind};
pub use project::{Clip, Preferences, Project, Quality, Resolution, SourceRef};
pub use project_store::ProjectStoreError;
pub use stroke::{Rgba, Stroke, StrokePoint};
pub use stroke_replay::VisibleStroke;
pub use tag_aggregation::TagSummary;
pub use timeline::{PlaybackSegment, SegmentKind};
