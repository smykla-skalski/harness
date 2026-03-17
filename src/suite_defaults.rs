use std::env;
use std::path::{Path, PathBuf};

use tracing::warn;

use crate::errors::{CliError, CliErrorKind};
use crate::io;

pub const DEFAULTS_FILE: &str = ".harness.json";

/// Persisted defaults for a suite directory.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SuiteDefaults {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_root: Option<String>,
}

/// Path to the suite defaults file.
#[must_use]
pub fn suite_defaults_path(suite_dir: &Path) -> PathBuf {
    suite_dir.join(DEFAULTS_FILE)
}

/// Write suite defaults to disk.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn write_suite_defaults(
    suite_dir: &Path,
    repo_root: Option<&Path>,
) -> Result<PathBuf, CliError> {
    io::ensure_dir(suite_dir)
        .map_err(|e| CliError::from(CliErrorKind::missing_file(e.to_string())))?;
    let payload = SuiteDefaults {
        repo_root: repo_root.map(|root| root.display().to_string()),
    };
    let path = suite_defaults_path(suite_dir);
    io::write_json_pretty(&path, &payload)?;
    Ok(path)
}

/// Load suite defaults from disk.
///
/// # Errors
/// Returns `CliError` on parse failure.
pub fn load_suite_defaults(suite_dir: &Path) -> Result<Option<SuiteDefaults>, CliError> {
    let path = suite_defaults_path(suite_dir);
    if !path.is_file() {
        return Ok(None);
    }
    let value = io::read_json_typed(&path)?;
    Ok(Some(value))
}

/// Find the suite directory containing a path.
///
/// Walks up the directory tree looking for `suite.md` or `.harness.json`.
/// If the given path is a file named `suite.md`, returns its parent.
#[must_use]
pub fn find_suite_dir(path: &Path) -> Option<PathBuf> {
    let resolved = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir().ok()?.join(path)
    };

    // If the path is literally suite.md and it exists, return its parent.
    if resolved.file_name().is_some_and(|n| n == "suite.md") && resolved.is_file() {
        return resolved.parent().map(Path::to_path_buf);
    }

    let start = if resolved.is_dir() {
        resolved
    } else {
        resolved.parent()?.to_path_buf()
    };

    let mut current = Some(start.as_path());
    while let Some(dir) = current {
        if dir.join("suite.md").is_file() {
            return Some(dir.to_path_buf());
        }
        if suite_defaults_path(dir).is_file() {
            return Some(dir.to_path_buf());
        }
        current = dir.parent();
    }
    None
}

/// Default repo root for a suite directory.
///
/// Reads the `.harness.json` file and returns the `repo_root` value if present.
#[must_use]
pub fn default_repo_root_for_suite(suite_dir: &Path) -> Option<PathBuf> {
    let payload = match load_suite_defaults(suite_dir) {
        Ok(Some(v)) => v,
        Ok(None) => return None,
        Err(e) => {
            warn!(path = %suite_defaults_path(suite_dir).display(), %e, "failed to load suite defaults");
            return None;
        }
    };
    let raw = payload.repo_root.as_deref()?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    Some(PathBuf::from(trimmed))
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn suite_defaults_path_joins_correctly() {
        let path = suite_defaults_path(Path::new("/suites/my-suite"));
        assert_eq!(path, PathBuf::from("/suites/my-suite/.harness.json"));
    }

    #[test]
    fn defaults_file_constant() {
        assert_eq!(DEFAULTS_FILE, ".harness.json");
    }

    #[test]
    fn write_and_load_suite_defaults_no_repo_root() {
        let tmp = tempfile::tempdir().unwrap();
        let suite_dir = tmp.path().join("suite");
        fs::create_dir_all(&suite_dir).unwrap();

        let path = write_suite_defaults(&suite_dir, None).unwrap();
        assert!(path.exists());
        assert_eq!(path.file_name().unwrap(), ".harness.json");

        let loaded = load_suite_defaults(&suite_dir).unwrap();
        assert!(loaded.is_some());
        let val = loaded.unwrap();
        // No repo_root key
        assert!(val.repo_root.is_none());
    }

    #[test]
    fn write_and_load_suite_defaults_with_repo_root() {
        let tmp = tempfile::tempdir().unwrap();
        let suite_dir = tmp.path().join("suite");
        let repo_root = tmp.path().join("repo");
        fs::create_dir_all(&suite_dir).unwrap();
        fs::create_dir_all(&repo_root).unwrap();

        write_suite_defaults(&suite_dir, Some(&repo_root)).unwrap();

        let loaded = load_suite_defaults(&suite_dir).unwrap().unwrap();
        let stored_root = loaded.repo_root.unwrap();
        assert!(stored_root.contains("repo"));
    }

    #[test]
    fn load_suite_defaults_missing_file_returns_none() {
        let tmp = tempfile::tempdir().unwrap();
        let result = load_suite_defaults(tmp.path()).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn default_repo_root_for_suite_returns_path() {
        let tmp = tempfile::tempdir().unwrap();
        let suite_dir = tmp.path().join("suite");
        let repo_root = tmp.path().join("repo");
        fs::create_dir_all(&suite_dir).unwrap();
        fs::create_dir_all(&repo_root).unwrap();

        write_suite_defaults(&suite_dir, Some(&repo_root)).unwrap();

        let result = default_repo_root_for_suite(&suite_dir);
        assert!(result.is_some());
        let root = result.unwrap();
        assert!(root.display().to_string().contains("repo"));
    }

    #[test]
    fn default_repo_root_for_suite_returns_none_when_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let result = default_repo_root_for_suite(tmp.path());
        assert!(result.is_none());
    }

    #[test]
    fn default_repo_root_for_suite_returns_none_when_no_key() {
        let tmp = tempfile::tempdir().unwrap();
        let suite_dir = tmp.path().join("suite");
        fs::create_dir_all(&suite_dir).unwrap();

        write_suite_defaults(&suite_dir, None).unwrap();

        let result = default_repo_root_for_suite(&suite_dir);
        assert!(result.is_none());
    }

    #[test]
    fn find_suite_dir_by_suite_md() {
        let tmp = tempfile::tempdir().unwrap();
        let suite_dir = tmp.path().join("my-suite");
        fs::create_dir_all(&suite_dir).unwrap();
        fs::write(suite_dir.join("suite.md"), "# Suite").unwrap();

        let result = find_suite_dir(&suite_dir);
        assert_eq!(result, Some(suite_dir));
    }

    #[test]
    fn find_suite_dir_from_suite_md_file_path() {
        let tmp = tempfile::tempdir().unwrap();
        let suite_dir = tmp.path().join("my-suite");
        fs::create_dir_all(&suite_dir).unwrap();
        let suite_md = suite_dir.join("suite.md");
        fs::write(&suite_md, "# Suite").unwrap();

        let result = find_suite_dir(&suite_md);
        assert_eq!(result, Some(suite_dir));
    }

    #[test]
    fn find_suite_dir_from_child_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let suite_dir = tmp.path().join("my-suite");
        let child = suite_dir.join("groups").join("g01");
        fs::create_dir_all(&child).unwrap();
        fs::write(suite_dir.join("suite.md"), "# Suite").unwrap();

        let result = find_suite_dir(&child);
        assert_eq!(result, Some(suite_dir));
    }

    #[test]
    fn find_suite_dir_by_defaults_file() {
        let tmp = tempfile::tempdir().unwrap();
        let suite_dir = tmp.path().join("my-suite");
        fs::create_dir_all(&suite_dir).unwrap();

        write_suite_defaults(&suite_dir, None).unwrap();

        let result = find_suite_dir(&suite_dir);
        assert_eq!(result, Some(suite_dir));
    }

    #[test]
    fn find_suite_dir_returns_none_for_empty_tree() {
        let tmp = tempfile::tempdir().unwrap();
        let result = find_suite_dir(tmp.path());
        assert!(result.is_none());
    }

    #[test]
    fn write_suite_defaults_creates_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let suite_dir = tmp.path().join("new-suite");
        // Directory doesn't exist yet
        assert!(!suite_dir.exists());

        let path = write_suite_defaults(&suite_dir, None).unwrap();
        assert!(path.exists());
        assert!(suite_dir.exists());
    }
}
