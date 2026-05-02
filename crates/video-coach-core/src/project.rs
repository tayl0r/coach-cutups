use crate::event::CommentaryEvent;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Resolution {
    Source,
    R1080,
    R720,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Quality {
    Low,
    Medium,
    High,
}

/// Output codec selection for compilation export.
///
/// Default is `H264` so an existing v2 project.json (post-Phase 10,
/// pre-Plan #3) without a `lastExportCodec` field deserializes cleanly
/// when combined with `#[serde(default)]` on `Preferences::last_export_codec`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Codec {
    #[default]
    H264,
    Hevc,
}

/// Phase 11 Plan #6. Selects whether a batch export overwrites
/// pre-existing per-tag .mp4 files (`OverwriteAll`, the Phase 10
/// behavior) or skips them when they already exist on disk and look
/// structurally complete (`Resume`, the new default).
///
/// `#[serde(default = "default_overwrite_policy")]` on
/// `Preferences::export_overwrite_policy` (named-function form below)
/// makes a pre-Plan-#6 project.json deserialize as `Resume` — i.e.
/// existing users opt INTO the new behavior on first open. This is a
/// behavior change from Phase 10's silent-overwrite default; documented
/// in the Phase 11 Plan #6 closeout.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ExportOverwritePolicy {
    /// Skip a per-tag output if it exists on disk and passes the
    /// structural validation (size > 50 KB AND `ftyp` magic at offset
    /// 4..8 AND `moov` atom in the last 64 KiB tail). Default for new
    /// projects and the migration path for pre-Plan-#6 projects.
    #[default]
    Resume,
    /// Always re-encode every selected tag, deleting any prior output
    /// silently before encode starts. Reproduces the Phase 10 behavior
    /// for users who explicitly want it (the export-sheet "Overwrite
    /// existing" checkbox).
    OverwriteAll,
}

/// Default value for `Preferences::export_overwrite_policy`. Declared
/// `pub` (not `pub(crate)`) so cross-crate callers in `video-coach-app`
/// (the bus's `default_overwrite_policy_for_command`) can reference it
/// as the single source of truth. Phase 11 Plan #6.
pub fn default_overwrite_policy() -> ExportOverwritePolicy {
    ExportOverwritePolicy::Resume
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preferences {
    pub scan_volume: f64,
    pub preview_source_volume: f64,
    pub preview_commentary_volume: f64,
    pub last_export_resolution: Resolution,
    pub last_export_quality: Quality,
    /// `#[serde(default)]` so a pre-Plan #3 project.json without this
    /// field deserializes to `Codec::H264` (preserves Phase 10 behavior).
    #[serde(default)]
    pub last_export_codec: Codec,
    /// Phase 11 Plan #7. Free-form template with `{tag}`, `{project}`,
    /// `{date}` placeholders. Default = `"{tag} - {project}"` which
    /// reproduces Phase 10's hard-coded format byte-for-byte.
    /// `#[serde(default = "default_filename_template")]` so a
    /// pre-Plan-#7 project.json deserializes cleanly with the legacy
    /// behavior preserved. The named-function form is used (instead of
    /// `#[serde(default)]` falling back to `String::default()`) because
    /// `""` would sanitize to `"untitled"` — wrong default behavior.
    #[serde(default = "default_filename_template")]
    pub export_filename_template: String,
    /// Phase 11 Plan #6. Selects skip-if-exists (`Resume`, the new
    /// default) vs always-re-encode (`OverwriteAll`, the Phase 10
    /// behavior). See `ExportOverwritePolicy` doc-comment.
    /// `#[serde(default = "default_overwrite_policy")]` so a pre-Plan-#6
    /// project.json deserializes as `Resume`. The named-function form
    /// is used (instead of `#[serde(default)]` falling back to
    /// `<ExportOverwritePolicy as Default>::default()`) for parallel
    /// structure with `default_filename_template` and to keep the
    /// resolved default visible at the field site.
    #[serde(default = "default_overwrite_policy")]
    pub export_overwrite_policy: ExportOverwritePolicy,
    pub preferred_camera_id: Option<String>,
    pub preferred_mic_id: Option<String>,
}

/// Default value for `Preferences::export_filename_template`. Declared
/// `pub` (not `pub(crate)`) so cross-crate callers in `video-coach-app`
/// (the bus's `default_command_filename_template`) can reference it as
/// the single source of truth. Phase 11 Plan #7.
pub fn default_filename_template() -> String {
    "{tag} - {project}".to_string()
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            scan_volume: 1.0,
            preview_source_volume: 1.0,
            preview_commentary_volume: 1.0,
            last_export_resolution: Resolution::R1080,
            last_export_quality: Quality::Medium,
            last_export_codec: Codec::H264,
            export_filename_template: default_filename_template(),
            export_overwrite_policy: default_overwrite_policy(),
            preferred_camera_id: None,
            preferred_mic_id: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceRef {
    /// v2 SCHEMA CHANGE: was `bookmark: Data` in v1 (macOS security-scoped
    /// bookmark). Now a path relative to the project folder, so the project
    /// folder is a self-contained, cross-platform unit.
    pub relative_path: String,
    pub display_name: String,
    pub duration_seconds: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clip {
    pub id: Uuid,
    pub name: String,
    pub notes: String,
    pub tags: Vec<String>,
    pub source_index: usize,
    pub start_source_seconds: f64,
    pub recording_duration: f64,
    pub recording_filename: String,
    pub events: Vec<CommentaryEvent>,
    pub sort_index: i64,
    /// Serialized as RFC 3339 with sub-second precision (chrono default).
    /// Not parseable by Swift `JSONDecoder.dateDecodingStrategy = .iso8601`
    /// — v2 has no Swift reader, so this is intentional.
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub format_version: i32,
    pub name: String,
    pub source_videos: Vec<SourceRef>,
    pub clips: Vec<Clip>,
    pub preferences: Preferences,
}

impl Project {
    /// v2 deliberately differs from v1 in two on-disk shape details:
    ///   - `SourceRef.bookmark` (macOS security-scoped bookmark) is replaced
    ///     by `SourceRef.relative_path`, so a project folder is a
    ///     self-contained, cross-platform unit.
    ///   - JSON output emits keys in struct declaration order via
    ///     `serde_json::to_vec_pretty`. v1 used Swift `JSONEncoder` with
    ///     `.sortedKeys` (alphabetic). v2 has no Swift writer; declaration
    ///     order is more readable in diffs.
    pub const FORMAT_VERSION: i32 = 2;
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            format_version: Self::FORMAT_VERSION,
            name: name.into(),
            source_videos: vec![],
            clips: vec![],
            preferences: Preferences::default(),
        }
    }
}

pub fn normalize_tag_input(input: &str) -> Vec<String> {
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut out = Vec::new();
    for fragment in input.split(',') {
        let trimmed = fragment.trim().to_lowercase();
        if trimmed.is_empty() || seen.contains(&trimmed) {
            continue;
        }
        seen.insert(trimmed.clone());
        out.push(trimmed);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_project_uses_format_version_2() {
        let p = Project::new("My Project");
        assert_eq!(p.format_version, 2);
        assert_eq!(p.name, "My Project");
        assert!(p.clips.is_empty());
        assert_eq!(p.preferences, Preferences::default());
    }

    #[test]
    fn tag_normalize_dedupes_lowercases_trims() {
        assert_eq!(
            normalize_tag_input("  Attack ,  ATTACK,defense ,, , offense"),
            vec!["attack", "defense", "offense"]
        );
    }

    #[test]
    fn tag_normalize_empty_string_yields_empty() {
        assert_eq!(normalize_tag_input(""), Vec::<String>::new());
    }

    #[test]
    fn project_roundtrips_through_json() {
        let p = Project::new("Test");
        let s = serde_json::to_string(&p).unwrap();
        let back: Project = serde_json::from_str(&s).unwrap();
        assert_eq!(p, back);
    }

    #[test]
    fn preferences_default_codec_is_h264() {
        assert_eq!(Preferences::default().last_export_codec, Codec::H264);
    }

    #[test]
    fn preferences_deserializes_without_codec_field() {
        // A legacy v2 project.json (post-Phase 10, pre-Plan #3) lacks the
        // `lastExportCodec` key. Confirm `#[serde(default)]` fills in H264.
        let legacy_json = r#"{
            "scanVolume": 1.0,
            "previewSourceVolume": 1.0,
            "previewCommentaryVolume": 1.0,
            "lastExportResolution": "r1080",
            "lastExportQuality": "medium",
            "preferredCameraId": null,
            "preferredMicId": null
        }"#;
        let prefs: Preferences = serde_json::from_str(legacy_json).unwrap();
        assert_eq!(prefs.last_export_codec, Codec::H264);
        assert_eq!(prefs, Preferences::default());
    }

    #[test]
    fn preferences_default_template_is_phase_10_format() {
        // Default template reproduces Phase 10's hard-coded
        // `<tag> - <project>` format byte-for-byte.
        assert_eq!(
            Preferences::default().export_filename_template,
            "{tag} - {project}"
        );
    }

    #[test]
    fn preferences_deserializes_without_template_field() {
        // A pre-Plan #7 project.json lacks `exportFilenameTemplate`.
        // Confirm `#[serde(default = "default_filename_template")]` fills
        // in the Phase 10 format default rather than `String::default()`
        // (which would yield `""` and mis-sanitize to `"untitled"`).
        let legacy_json = r#"{
            "scanVolume": 1.0,
            "previewSourceVolume": 1.0,
            "previewCommentaryVolume": 1.0,
            "lastExportResolution": "r1080",
            "lastExportQuality": "medium",
            "lastExportCodec": "h264",
            "preferredCameraId": null,
            "preferredMicId": null
        }"#;
        let prefs: Preferences = serde_json::from_str(legacy_json).unwrap();
        assert_eq!(prefs.export_filename_template, "{tag} - {project}");
        assert_eq!(prefs, Preferences::default());
    }

    #[test]
    fn default_filename_template_returns_phase_10_format() {
        // The free function is the single source of truth referenced by
        // both the serde default attribute and (in Task 2) the bus's
        // `default_command_filename_template`.
        assert_eq!(default_filename_template(), "{tag} - {project}");
    }

    #[test]
    fn export_overwrite_policy_serializes_to_camel_case() {
        // Phase 11 Plan #6. Wire form is camelCase per the
        // enum-level `#[serde(rename_all = "camelCase")]`.
        assert_eq!(
            serde_json::to_string(&ExportOverwritePolicy::Resume).unwrap(),
            r#""resume""#,
        );
        assert_eq!(
            serde_json::to_string(&ExportOverwritePolicy::OverwriteAll).unwrap(),
            r#""overwriteAll""#,
        );
        let r: ExportOverwritePolicy = serde_json::from_str(r#""resume""#).unwrap();
        assert_eq!(r, ExportOverwritePolicy::Resume);
        let oa: ExportOverwritePolicy = serde_json::from_str(r#""overwriteAll""#).unwrap();
        assert_eq!(oa, ExportOverwritePolicy::OverwriteAll);
    }

    #[test]
    fn export_overwrite_policy_default_is_resume() {
        // Phase 11 Plan #6. Both the enum-level Default and the
        // Preferences-level field default land on Resume.
        assert_eq!(
            ExportOverwritePolicy::default(),
            ExportOverwritePolicy::Resume,
        );
        assert_eq!(default_overwrite_policy(), ExportOverwritePolicy::Resume);
        assert_eq!(
            Preferences::default().export_overwrite_policy,
            ExportOverwritePolicy::Resume,
        );
    }

    #[test]
    fn preferences_deserializes_without_overwrite_policy_field() {
        // Phase 11 Plan #6. A pre-Plan-#6 project.json lacks the
        // `exportOverwritePolicy` key. With
        // `#[serde(default = "default_overwrite_policy")]` the field
        // fills in to `Resume`, the new default. This is a behavior
        // change from Phase 10 (silent overwrite); documented in
        // closeout.
        let legacy_json = r#"{
            "scanVolume": 1.0,
            "previewSourceVolume": 1.0,
            "previewCommentaryVolume": 1.0,
            "lastExportResolution": "r1080",
            "lastExportQuality": "medium",
            "lastExportCodec": "h264",
            "exportFilenameTemplate": "{tag} - {project}",
            "preferredCameraId": null,
            "preferredMicId": null
        }"#;
        let prefs: Preferences = serde_json::from_str(legacy_json).unwrap();
        assert_eq!(prefs.export_overwrite_policy, ExportOverwritePolicy::Resume,);
        assert_eq!(prefs, Preferences::default());
    }

    #[test]
    fn source_ref_serializes_with_relative_path_key() {
        let s = SourceRef {
            relative_path: "sources/match1.mp4".into(),
            display_name: "Match 1".into(),
            duration_seconds: 5400.0,
        };
        let json = serde_json::to_value(&s).unwrap();
        let obj = json.as_object().unwrap();
        assert!(obj.contains_key("relativePath"));
        assert!(obj.contains_key("displayName"));
        assert!(obj.contains_key("durationSeconds"));
        assert!(
            !obj.contains_key("bookmark"),
            "v2 must not emit bookmark field"
        );
    }
}
