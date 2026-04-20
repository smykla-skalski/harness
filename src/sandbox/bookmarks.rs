//! JSON-backed store of security-scoped bookmarks shared with the Swift app.

use std::fs;
use std::io;
use std::io::Write as _;
use std::path::Path;

use chrono::{DateTime, Utc};
use serde::de::Error as DeError;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    ProjectRoot,
    SessionDirectory,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: String,
    pub kind: Kind,
    pub display_name: String,
    pub last_resolved_path: String,
    #[serde(with = "base64_bytes")]
    pub bookmark_data: Vec<u8>,
    pub created_at: DateTime<Utc>,
    pub last_accessed_at: DateTime<Utc>,
    pub stale_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersistedStore {
    pub schema_version: u32,
    pub bookmarks: Vec<Record>,
}

impl PersistedStore {
    pub const CURRENT_SCHEMA_VERSION: u32 = 1;
}

#[derive(Debug, Error)]
pub enum BookmarkError {
    #[error("I/O: {0}")]
    Io(#[from] io::Error),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("unsupported bookmarks.json schema version: found {found}, expected {expected}")]
    UnsupportedSchemaVersion { found: u32, expected: u32 },
    #[error("bookmark id not found: {0}")]
    NotFound(String),
    #[cfg(target_os = "macos")]
    #[error("resolution failed: {0}")]
    Resolution(String),
}

/// Load the bookmark store from `path`.
///
/// Returns an empty store when the file is absent.
///
/// # Errors
///
/// Returns [`BookmarkError::Io`] on read failure, [`BookmarkError::Json`] on
/// parse failure, or [`BookmarkError::UnsupportedSchemaVersion`] when the
/// stored `schemaVersion` does not match [`PersistedStore::CURRENT_SCHEMA_VERSION`].
pub fn load(path: &Path) -> Result<PersistedStore, BookmarkError> {
    if !path.exists() {
        return Ok(PersistedStore {
            schema_version: PersistedStore::CURRENT_SCHEMA_VERSION,
            bookmarks: Vec::new(),
        });
    }
    let bytes = fs::read(path)?;
    let store: PersistedStore = serde_json::from_slice(&bytes)?;
    if store.schema_version != PersistedStore::CURRENT_SCHEMA_VERSION {
        return Err(BookmarkError::UnsupportedSchemaVersion {
            found: store.schema_version,
            expected: PersistedStore::CURRENT_SCHEMA_VERSION,
        });
    }
    Ok(store)
}

/// Persist `store` to `path`, creating parent directories as needed.
///
/// The write is atomic: the JSON lands in a sibling tempfile first, then
/// `persist` (rename) takes over. A crash mid-write leaves the previous
/// `bookmarks.json` intact instead of a half-written file.
///
/// # Errors
///
/// Returns [`BookmarkError::Io`] on I/O failure or [`BookmarkError::Json`]
/// if serialization fails.
pub fn save(path: &Path, store: &PersistedStore) -> Result<(), BookmarkError> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "bookmarks.json path has no parent directory: {}",
                path.display()
            ),
        )
    })?;
    fs::create_dir_all(parent)?;
    let json = serde_json::to_vec_pretty(store)?;
    let mut tmp = tempfile::NamedTempFile::new_in(parent)?;
    tmp.write_all(&json)?;
    tmp.as_file().sync_all()?;
    tmp.persist(path).map_err(|e| e.error)?;
    Ok(())
}

/// Find a bookmark by `id`, returning `None` if not present.
#[must_use]
pub fn find<'a>(store: &'a PersistedStore, id: &str) -> Option<&'a Record> {
    store.bookmarks.iter().find(|r| r.id == id)
}

mod base64_bytes {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    use serde::{Deserialize, Deserializer, Serializer};

    use super::DeError;

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let raw = String::deserialize(d)?;
        STANDARD.decode(raw).map_err(D::Error::custom)
    }
}

#[cfg(test)]
mod tests;
