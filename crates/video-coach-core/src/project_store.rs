use crate::project::Project;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use thiserror::Error;

pub const PROJECT_FILE_NAME: &str = "project.json";
pub const RECORDINGS_DIR_NAME: &str = "recordings";

#[derive(Debug, Error)]
pub enum ProjectStoreError {
    #[error("project.json not found in {0}")]
    MissingProjectJson(PathBuf),
    #[error("unsupported formatVersion {0} (this build only opens v2)")]
    UnsupportedFormatVersion(i32),
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

pub fn read(folder: &Path) -> Result<Project, ProjectStoreError> {
    let url = folder.join(PROJECT_FILE_NAME);
    if !url.exists() {
        return Err(ProjectStoreError::MissingProjectJson(folder.to_path_buf()));
    }
    let data = fs::read(&url)?;
    let project: Project = serde_json::from_slice(&data)?;
    if project.format_version != Project::FORMAT_VERSION {
        return Err(ProjectStoreError::UnsupportedFormatVersion(
            project.format_version,
        ));
    }
    Ok(project)
}

pub fn write(project: &Project, folder: &Path) -> Result<(), ProjectStoreError> {
    fs::create_dir_all(folder)?;
    fs::create_dir_all(folder.join(RECORDINGS_DIR_NAME))?;

    let target = folder.join(PROJECT_FILE_NAME);
    let tmp = folder.join("project.json.tmp");

    // Pretty-printed; key order is BTreeMap-stable (alphabetic) by serde's struct serialization.
    let data = serde_json::to_vec_pretty(project)?;
    fs::write(&tmp, &data)?;
    if target.exists() {
        fs::remove_file(&target)?;
    }
    fs::rename(&tmp, &target)?;
    Ok(())
}

pub fn recordings_dir(folder: &Path) -> PathBuf {
    folder.join(RECORDINGS_DIR_NAME)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn write_then_read_roundtrips() {
        let dir = TempDir::new().unwrap();
        let p = Project::new("Roundtrip");
        write(&p, dir.path()).unwrap();
        let back = read(dir.path()).unwrap();
        assert_eq!(p, back);
    }

    #[test]
    fn read_missing_returns_typed_error() {
        let dir = TempDir::new().unwrap();
        match read(dir.path()) {
            Err(ProjectStoreError::MissingProjectJson(_)) => {}
            other => panic!("expected MissingProjectJson, got {:?}", other),
        }
    }

    #[test]
    fn read_v1_project_returns_unsupported_format_error() {
        let dir = TempDir::new().unwrap();
        let v1 = serde_json::json!({
            "formatVersion": 1,
            "name": "old",
            "sourceVideos": [],
            "clips": [],
            "preferences": {
                "scanVolume": 1.0, "previewSourceVolume": 1.0, "previewCommentaryVolume": 1.0,
                "lastExportResolution": "r1080", "lastExportQuality": "medium",
                "preferredCameraId": null, "preferredMicId": null
            }
        });
        std::fs::write(
            dir.path().join("project.json"),
            serde_json::to_vec(&v1).unwrap(),
        )
        .unwrap();
        match read(dir.path()) {
            Err(ProjectStoreError::UnsupportedFormatVersion(1)) => {}
            other => panic!("expected UnsupportedFormatVersion(1), got {:?}", other),
        }
    }

    #[test]
    fn write_creates_recordings_subdir() {
        let dir = TempDir::new().unwrap();
        let p = Project::new("WithRecordings");
        write(&p, dir.path()).unwrap();
        assert!(dir.path().join(RECORDINGS_DIR_NAME).is_dir());
    }
}
