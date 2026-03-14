use std::fs;
use std::path::{Path, PathBuf};

pub const DEFAULTS_FILE: &str = ".harness.json";

/// Path to the suite defaults file.
#[must_use]
pub fn suite_defaults_path(suite_dir: &Path) -> PathBuf {
    suite_dir.join(DEFAULTS_FILE)
}

/// Write suite defaults to disk.
///
/// # Errors
/// Returns an IO error if the directory cannot be created or the file cannot be written.
pub fn write_suite_defaults(
    suite_dir: &Path,
    repo_root: Option<&Path>,
) -> std::io::Result<PathBuf> {
    fs::create_dir_all(suite_dir)?;
    let mut payload = serde_json::Map::new();
    if let Some(root) = repo_root {
        payload.insert(
            "repo_root".to_string(),
            serde_json::Value::String(root.to_string_lossy().into_owned()),
        );
    }
    let path = suite_defaults_path(suite_dir);
    let json = serde_json::to_string_pretty(&payload).map_err(std::io::Error::other)?;
    fs::write(&path, json)?;
    Ok(path)
}

/// Load suite defaults from disk. Returns `None` if the file does not exist.
///
/// # Errors
/// Returns an IO error if the file exists but cannot be read or parsed.
pub fn load_suite_defaults(suite_dir: &Path) -> std::io::Result<Option<serde_json::Value>> {
    let path = suite_defaults_path(suite_dir);
    if !path.is_file() {
        return Ok(None);
    }
    let content = fs::read_to_string(&path)?;
    let value: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    Ok(Some(value))
}

/// Find the suite directory containing a path by walking up from it.
#[must_use]
pub fn find_suite_dir(path: &Path) -> Option<PathBuf> {
    let resolved = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };

    // If pointing directly at suite.md, return parent.
    if resolved.file_name().is_some_and(|n| n == "suite.md") && resolved.is_file() {
        return resolved.parent().map(Path::to_path_buf);
    }

    let start = if resolved.is_dir() {
        resolved.clone()
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
#[must_use]
pub fn default_repo_root_for_suite(suite_dir: &Path) -> Option<PathBuf> {
    let payload = load_suite_defaults(suite_dir).ok()??;
    let raw = payload.get("repo_root")?.as_str()?;
    if raw.trim().is_empty() {
        return None;
    }
    Some(PathBuf::from(raw))
}

/// Default repo root by finding the suite dir first.
#[must_use]
pub fn default_repo_root_for_path(path: &Path) -> Option<PathBuf> {
    let suite_dir = find_suite_dir(path)?;
    default_repo_root_for_suite(&suite_dir)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn suite_defaults_path_joins_correctly() {
        let p = suite_defaults_path(Path::new("/my/suite"));
        assert_eq!(p, PathBuf::from("/my/suite/.harness.json"));
    }

    #[test]
    fn write_and_load_round_trip() {
        let tmp = TempDir::new().unwrap();
        let suite_dir = tmp.path().join("suite");
        let repo = tmp.path().join("repo");

        let written = write_suite_defaults(&suite_dir, Some(&repo)).unwrap();
        assert_eq!(written, suite_defaults_path(&suite_dir));
        assert!(written.is_file());

        let loaded = load_suite_defaults(&suite_dir).unwrap().unwrap();
        assert_eq!(
            loaded["repo_root"].as_str().unwrap(),
            repo.to_string_lossy()
        );
    }

    #[test]
    fn write_without_repo_root() {
        let tmp = TempDir::new().unwrap();
        let suite_dir = tmp.path().join("suite");

        write_suite_defaults(&suite_dir, None).unwrap();

        let loaded = load_suite_defaults(&suite_dir).unwrap().unwrap();
        assert!(loaded.get("repo_root").is_none());
    }

    #[test]
    fn load_missing_returns_none() {
        let tmp = TempDir::new().unwrap();
        let result = load_suite_defaults(tmp.path()).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn find_suite_dir_with_suite_md() {
        let tmp = TempDir::new().unwrap();
        fs::write(tmp.path().join("suite.md"), "# Suite").unwrap();

        let found = find_suite_dir(tmp.path()).unwrap();
        assert_eq!(found, tmp.path());
    }

    #[test]
    fn find_suite_dir_from_child() {
        let tmp = TempDir::new().unwrap();
        fs::write(tmp.path().join("suite.md"), "# Suite").unwrap();
        let child = tmp.path().join("groups");
        fs::create_dir_all(&child).unwrap();

        let found = find_suite_dir(&child).unwrap();
        assert_eq!(found, tmp.path());
    }

    #[test]
    fn find_suite_dir_from_suite_md_path() {
        let tmp = TempDir::new().unwrap();
        let suite_md = tmp.path().join("suite.md");
        fs::write(&suite_md, "# Suite").unwrap();

        let found = find_suite_dir(&suite_md).unwrap();
        assert_eq!(found, tmp.path());
    }

    #[test]
    fn find_suite_dir_with_defaults_file() {
        let tmp = TempDir::new().unwrap();
        write_suite_defaults(tmp.path(), None).unwrap();

        let found = find_suite_dir(tmp.path()).unwrap();
        assert_eq!(found, tmp.path());
    }

    #[test]
    fn find_suite_dir_returns_none_when_missing() {
        let tmp = TempDir::new().unwrap();
        let result = find_suite_dir(tmp.path());
        assert!(result.is_none());
    }

    #[test]
    fn default_repo_root_for_suite_round_trip() {
        let tmp = TempDir::new().unwrap();
        let repo = tmp.path().join("repo");
        write_suite_defaults(tmp.path(), Some(&repo)).unwrap();

        let root = default_repo_root_for_suite(tmp.path()).unwrap();
        assert_eq!(root, repo);
    }

    #[test]
    fn default_repo_root_for_suite_missing_returns_none() {
        let tmp = TempDir::new().unwrap();
        assert!(default_repo_root_for_suite(tmp.path()).is_none());
    }

    #[test]
    fn default_repo_root_for_path_integration() {
        let tmp = TempDir::new().unwrap();
        let repo = tmp.path().join("repo");
        fs::write(tmp.path().join("suite.md"), "# Suite").unwrap();
        write_suite_defaults(tmp.path(), Some(&repo)).unwrap();

        let child = tmp.path().join("groups");
        fs::create_dir_all(&child).unwrap();

        let root = default_repo_root_for_path(&child).unwrap();
        assert_eq!(root, repo);
    }
}
