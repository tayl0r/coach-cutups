//! Shared test helpers used by multiple modules' `#[cfg(test)] mod tests`.
//!
//! Compiled out of release builds via `#[cfg(test)]` on the `mod` declaration.

use crate::project::Clip;
use chrono::Utc;
use uuid::Uuid;

/// Deterministic UUID derived from a short ASCII tag. Same tag always returns
/// the same UUID; different tags return different UUIDs.
pub(crate) fn deterministic_uuid(tag: &str) -> Uuid {
    // The algorithm pads each ASCII byte's hex into a 32-char window. Tags
    // longer than 16 bytes silently collide because everything past the
    // first 16 bytes is truncated.
    debug_assert!(tag.len() <= 16, "deterministic_uuid tag must be <=16 bytes");
    let mut hex = String::with_capacity(32);
    for b in tag.bytes() {
        hex.push_str(&format!("{:02x}", b));
    }
    while hex.len() < 32 {
        hex.push('0');
    }
    hex.truncate(32);
    let mut bytes = [0u8; 16];
    for (i, byte) in bytes.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap();
    }
    Uuid::from_bytes(bytes)
}

/// A `Clip` with sensible defaults for the fields tests rarely care about.
/// Override via struct-update syntax:
///
/// ```ignore
/// let c = Clip { events: vec![...], recording_duration: 6.0, ..test_clip() };
/// ```
pub(crate) fn test_clip() -> Clip {
    Clip {
        id: Uuid::new_v4(),
        name: "t".into(),
        notes: String::new(),
        tags: vec![],
        source_index: 0,
        start_source_seconds: 0.0,
        recording_duration: 10.0,
        recording_filename: "t.mov".into(),
        events: vec![],
        sort_index: 0,
        created_at: Utc::now(),
    }
}
