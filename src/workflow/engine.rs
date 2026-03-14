use std::fs;
use std::path::{Path, PathBuf};
use std::process;

use serde_json::Value;

use crate::errors::CliError;

/// Error for invalid state transitions.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct TransitionError(pub String);

/// Versioned JSON repository with atomic save.
pub struct VersionedJsonRepository {
    path: PathBuf,
    current_version: u32,
}

impl VersionedJsonRepository {
    #[must_use]
    pub fn new(path: PathBuf, current_version: u32) -> Self {
        Self {
            path,
            current_version,
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
    pub fn load(&self) -> Result<Option<Value>, CliError> {
        if !self.path.exists() {
            return Ok(None);
        }
        let contents = fs::read_to_string(&self.path).map_err(|e| CliError {
            code: "WORKFLOW_IO".into(),
            message: format!("failed to read {}: {e}", self.path.display()),
            exit_code: 5,
            hint: None,
            details: None,
        })?;
        let value: Value = serde_json::from_str(&contents).map_err(|e| CliError {
            code: "WORKFLOW_PARSE".into(),
            message: format!("failed to parse {}: {e}", self.path.display()),
            exit_code: 5,
            hint: None,
            details: None,
        })?;
        let version = value.get("schema_version").and_then(Value::as_u64);
        if version != Some(u64::from(self.current_version)) {
            return Err(CliError {
                code: "WORKFLOW_VERSION".into(),
                message: format!("unsupported workflow schema version: {version:?}"),
                exit_code: 5,
                hint: None,
                details: None,
            });
        }
        Ok(Some(value))
    }

    /// Save state to the JSON file atomically.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn save(&self, state: &Value) -> Result<(), CliError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|e| CliError {
                code: "WORKFLOW_IO".into(),
                message: format!("failed to create directory {}: {e}", parent.display()),
                exit_code: 5,
                hint: None,
                details: None,
            })?;
        }
        let tmp_name = format!("json.{}.tmp", process::id());
        let tmp_path = self.path.with_extension(tmp_name);
        let json = serde_json::to_string_pretty(state).map_err(|e| CliError {
            code: "WORKFLOW_SERIALIZE".into(),
            message: format!("failed to serialize state: {e}"),
            exit_code: 5,
            hint: None,
            details: None,
        })?;
        fs::write(&tmp_path, &json).map_err(|e| CliError {
            code: "WORKFLOW_IO".into(),
            message: format!("failed to write {}: {e}", tmp_path.display()),
            exit_code: 5,
            hint: None,
            details: None,
        })?;
        fs::rename(&tmp_path, &self.path).map_err(|e| CliError {
            code: "WORKFLOW_IO".into(),
            message: format!("failed to rename to {}: {e}", self.path.display()),
            exit_code: 5,
            hint: None,
            details: None,
        })?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tempfile::TempDir;

    #[test]
    fn load_returns_none_when_file_missing() {
        let dir = TempDir::new().unwrap();
        let repo = VersionedJsonRepository::new(dir.path().join("state.json"), 1);
        assert!(repo.load().unwrap().is_none());
    }

    #[test]
    fn save_and_load_round_trip() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::new(path.clone(), 1);
        let state = json!({"schema_version": 1, "phase": "bootstrap"});
        repo.save(&state).unwrap();
        let loaded = repo.load().unwrap().unwrap();
        assert_eq!(loaded["phase"], "bootstrap");
    }

    #[test]
    fn load_rejects_wrong_version() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::new(path.clone(), 2);
        let state = json!({"schema_version": 1, "phase": "bootstrap"});
        fs::write(&path, serde_json::to_string(&state).unwrap()).unwrap();
        let err = repo.load().unwrap_err();
        assert!(err.message.contains("unsupported"));
    }

    #[test]
    fn save_creates_parent_directories() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nested").join("dir").join("state.json");
        let repo = VersionedJsonRepository::new(path.clone(), 1);
        let state = json!({"schema_version": 1});
        repo.save(&state).unwrap();
        assert!(path.exists());
    }

    #[test]
    fn save_is_atomic_via_rename() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("state.json");
        let repo = VersionedJsonRepository::new(path.clone(), 1);
        let state = json!({"schema_version": 1, "data": "first"});
        repo.save(&state).unwrap();
        let state2 = json!({"schema_version": 1, "data": "second"});
        repo.save(&state2).unwrap();
        let loaded = repo.load().unwrap().unwrap();
        assert_eq!(loaded["data"], "second");
        // tmp file should not remain
        let tmp_name = format!("state.json.{}.tmp", process::id());
        assert!(!dir.path().join(tmp_name).exists());
    }

    #[test]
    fn transition_error_displays_message() {
        let err = TransitionError("bad transition".to_string());
        assert_eq!(err.to_string(), "bad transition");
    }

    #[test]
    fn path_accessor_returns_configured_path() {
        let repo = VersionedJsonRepository::new(PathBuf::from("/tmp/test.json"), 3);
        assert_eq!(repo.path(), Path::new("/tmp/test.json"));
        assert_eq!(repo.current_version(), 3);
    }
}
