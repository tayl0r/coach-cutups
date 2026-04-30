//! Tiny per-user persistence for "what project was open last".
//!
//! Stored as a single absolute path at `$HOME/.video-coach/last_project.txt`.
//! Best-effort: any IO failure is logged and ignored, so a missing,
//! unreadable, or corrupt file just means "no auto-reopen this run". A
//! successful auto-reopen is silent; a failure surfaces in the UI's
//! error label via the existing OpenProject error path.

use std::path::PathBuf;

fn config_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".video-coach"))
}

fn config_file() -> Option<PathBuf> {
    config_dir().map(|d| d.join("last_project.txt"))
}

pub fn load() -> Option<String> {
    let f = config_file()?;
    let s = std::fs::read_to_string(&f).ok()?;
    let trimmed = s.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

pub fn save(path: &str) {
    let Some(dir) = config_dir() else {
        return;
    };
    let Some(file) = config_file() else {
        return;
    };
    if let Err(e) = std::fs::create_dir_all(&dir) {
        tracing::warn!(
            target: "app.lifecycle",
            error = %e,
            dir = %dir.display(),
            "couldn't create video-coach config dir; last-project won't persist",
        );
        return;
    }
    if let Err(e) = std::fs::write(&file, path) {
        tracing::warn!(
            target: "app.lifecycle",
            error = %e,
            file = %file.display(),
            "couldn't write last_project.txt",
        );
    }
}
