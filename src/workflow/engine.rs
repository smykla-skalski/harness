use std::marker::PhantomData;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind, cow};
use crate::io;

/// Error for invalid state transitions.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct TransitionError(pub String);

/// Versioned JSON repository with atomic save.
pub struct VersionedJsonRepository<T> {
    path: PathBuf,
    current_version: u32,
    marker: PhantomData<fn() -> T>,
}

impl<T> VersionedJsonRepository<T>
where
    T: Serialize + DeserializeOwned,
{
    #[must_use]
    pub fn new(path: PathBuf, current_version: u32) -> Self {
        Self {
            path,
            current_version,
            marker: PhantomData,
        }
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    #[must_use]
    pub fn current_version(&self) -> u32 {
        self.current_version
    }

    /// Load state from the JSON file.
    ///
    /// # Errors
    /// Returns `CliError` on IO or parse failure.
    pub fn load(&self) -> Result<Option<T>, CliError> {
        if !self.path.exists() {
            return Ok(None);
        }
        let contents: Value = io::read_json_typed(&self.path).map_err(|e| -> CliError {
            CliErrorKind::workflow_parse(cow!("failed to parse {}: {e}", self.path.display()))
                .with_details(e.to_string())
        })?;
        let version = contents.get("schema_version").and_then(Value::as_u64);
        if version != Some(u64::from(self.current_version)) {
            return Err(CliErrorKind::workflow_version(cow!("{version:?}")).into());
        }
        let value = serde_json::from_value(contents).map_err(|e| -> CliError {
            CliErrorKind::workflow_parse(cow!("failed to parse {}: {e}", self.path.display()))
                .into()
        })?;
        Ok(Some(value))
    }

    /// Save state to the JSON file atomically.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn save(&self, state: &T) -> Result<(), CliError> {
        io::write_json_pretty(&self.path, state).map_err(|e| -> CliError {
            CliErrorKind::workflow_io(cow!("failed to write {}: {e}", self.path.display())).into()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn load_returns_none_when_file_missing() {
        let dir = TempDir::new().unwrap();
        let repo = VersionedJsonRepository::<Value>::new(dir.path().join("state.json"), 1);
        assert!(repo.load().unwrap().is_none());
    }

    #[test]
    fn save_and_load_round_trip() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::<Value>::new(path.clone(), 1);
        let state = json!({"schema_version": 1, "phase": "bootstrap"});
        repo.save(&state).unwrap();
        let loaded = repo.load().unwrap().unwrap();
        assert_eq!(loaded["phase"], "bootstrap");
    }

    #[test]
    fn load_rejects_wrong_version() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::<Value>::new(path.clone(), 2);
        let state = json!({"schema_version": 1, "phase": "bootstrap"});
        fs::write(&path, serde_json::to_string(&state).unwrap()).unwrap();
        let err = repo.load().unwrap_err();
        assert!(err.message().contains("unsupported"));
    }

    #[test]
    fn save_creates_parent_directories() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nested").join("dir").join("state.json");
        let repo = VersionedJsonRepository::<Value>::new(path.clone(), 1);
        let state = json!({"schema_version": 1});
        repo.save(&state).unwrap();
        assert!(path.exists());
    }

    #[test]
    fn save_is_atomic_via_rename() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::<Value>::new(path.clone(), 1);
        let state = json!({"schema_version": 1, "data": "first"});
        repo.save(&state).unwrap();
        let state2 = json!({"schema_version": 1, "data": "second"});
        repo.save(&state2).unwrap();
        let loaded = repo.load().unwrap().unwrap();
        assert_eq!(loaded["data"], "second");
    }

    #[test]
    fn transition_error_displays_message() {
        let err = TransitionError("bad transition".to_string());
        assert_eq!(err.to_string(), "bad transition");
    }

    #[test]
    fn path_accessor_returns_configured_path() {
        let repo = VersionedJsonRepository::<Value>::new(PathBuf::from("/tmp/test.json"), 3);
        assert_eq!(repo.path(), Path::new("/tmp/test.json"));
        assert_eq!(repo.current_version(), 3);
    }
}
