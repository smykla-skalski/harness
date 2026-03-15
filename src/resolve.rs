use std::env;
use std::path::{Path, PathBuf};

use crate::context::RunLookup;
use crate::core_defs;
use crate::errors::{CliError, CliErrorKind};

/// Resolved run directory.
#[derive(Debug, Clone)]
pub struct ResolvedRun {
    pub run_dir: PathBuf,
}

/// Resolve a run directory from a lookup.
///
/// Tries `run_dir` directly, then `run_root/run_id`. Returns the first
/// existing candidate or an error.
///
/// # Errors
/// Returns `CliError` if the run directory cannot be determined.
pub fn resolve_run_directory(lookup: &RunLookup) -> Result<ResolvedRun, CliError> {
    if let Some(run_dir) = &lookup.run_dir {
        if run_dir.exists() {
            return Ok(ResolvedRun {
                run_dir: run_dir.clone(),
            });
        }
        return Err(CliErrorKind::missing_file(run_dir.display().to_string()).into());
    }

    if let (Some(run_root), Some(run_id)) = (&lookup.run_root, &lookup.run_id) {
        let path = run_root.join(run_id);
        if path.exists() {
            return Ok(ResolvedRun { run_dir: path });
        }
        return Err(CliErrorKind::missing_run_location(run_id.clone()).into());
    }

    if let Some(run_id) = &lookup.run_id {
        return Err(CliErrorKind::missing_run_location(run_id.clone()).into());
    }

    Err(CliErrorKind::MissingRunPointer.into())
}

/// Resolve a suite path from raw input.
///
/// Candidates: the raw path itself, or `suite_root/raw/suite.md` for bare
/// names. Returns the first existing candidate, or the first candidate
/// normalized (appending `suite.md` if it points to a directory).
///
/// # Errors
/// Returns `CliError` if not found.
pub fn resolve_suite_path(raw: &str) -> Result<PathBuf, CliError> {
    let suite_root = core_defs::suite_root();
    let candidates = suite_path_candidates(raw, &suite_root);

    for candidate in &candidates {
        let normalized = normalize_suite_candidate(candidate);
        if normalized.exists() {
            return Ok(normalized);
        }
    }

    // Fall back to the first candidate, normalized
    if let Some(first) = candidates.first() {
        return Ok(normalize_suite_candidate(first));
    }

    Err(CliErrorKind::missing_file(raw.to_string()).into())
}

/// Resolve a manifest path, searching the run directory's manifest tree.
///
/// # Errors
/// Returns `CliError` if not found.
pub fn resolve_manifest_path(raw: &str, run_dir: Option<&Path>) -> Result<PathBuf, CliError> {
    let candidates = manifest_path_candidates(raw, run_dir);

    for candidate in &candidates {
        let normalized = candidate.clone();
        if normalized.exists() {
            return Ok(normalized);
        }
    }

    Err(CliErrorKind::missing_file(raw.to_string()).into())
}

fn suite_path_candidates(raw: &str, suite_root: &Path) -> Vec<PathBuf> {
    let raw_path = PathBuf::from(raw);
    let direct = if raw_path.is_absolute() {
        raw_path.clone()
    } else {
        env::current_dir().unwrap_or_default().join(&raw_path)
    };

    let mut items = vec![direct];
    if !raw.contains('/') && !raw.contains('\\') {
        items.push(suite_root.join(raw).join("suite.md"));
    }
    items
}

fn normalize_suite_candidate(candidate: &Path) -> PathBuf {
    if candidate.is_dir() {
        candidate.join("suite.md")
    } else {
        candidate.to_path_buf()
    }
}

fn manifest_path_candidates(raw: &str, run_dir: Option<&Path>) -> Vec<PathBuf> {
    let raw_path = PathBuf::from(raw);
    if raw_path.is_absolute() {
        return vec![raw_path];
    }

    let mut items = vec![env::current_dir().unwrap_or_default().join(&raw_path)];

    if let Some(active) = run_dir {
        items.push(
            active
                .join("manifests")
                .join("prepared")
                .join("groups")
                .join(&raw_path),
        );
        items.push(
            active
                .join("manifests")
                .join("prepared")
                .join("baseline")
                .join(&raw_path),
        );
        items.push(active.join("manifests").join(&raw_path));
    }

    items
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn resolve_run_directory_with_existing_dir() {
        let dir = tempfile::tempdir().unwrap();
        let lookup = RunLookup {
            run_dir: Some(dir.path().to_path_buf()),
            run_id: None,
            run_root: None,
        };
        let resolved = resolve_run_directory(&lookup).unwrap();
        assert_eq!(resolved.run_dir, dir.path());
    }

    #[test]
    fn resolve_run_directory_with_root_and_id() {
        let dir = tempfile::tempdir().unwrap();
        let run_dir = dir.path().join("my-run");
        fs::create_dir(&run_dir).unwrap();
        let lookup = RunLookup {
            run_dir: None,
            run_id: Some("my-run".to_string()),
            run_root: Some(dir.path().to_path_buf()),
        };
        let resolved = resolve_run_directory(&lookup).unwrap();
        assert_eq!(resolved.run_dir, run_dir);
    }

    #[test]
    fn resolve_run_directory_missing_returns_error() {
        let lookup = RunLookup {
            run_dir: None,
            run_id: Some("ghost".to_string()),
            run_root: Some(PathBuf::from("/nonexistent")),
        };
        let err = resolve_run_directory(&lookup).unwrap_err();
        assert_eq!(err.code(), "KSRCLI018");
    }

    #[test]
    fn resolve_run_directory_no_fields_returns_pointer_error() {
        let lookup = RunLookup::default();
        let err = resolve_run_directory(&lookup).unwrap_err();
        assert_eq!(err.code(), "KSRCLI005");
    }

    #[test]
    fn resolve_run_directory_only_run_id_returns_location_error() {
        let lookup = RunLookup {
            run_dir: None,
            run_id: Some("orphan".to_string()),
            run_root: None,
        };
        let err = resolve_run_directory(&lookup).unwrap_err();
        assert_eq!(err.code(), "KSRCLI018");
    }

    #[test]
    fn resolve_manifest_path_absolute_existing() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = dir.path().join("test.yaml");
        fs::write(&manifest, "content").unwrap();
        let result = resolve_manifest_path(&manifest.to_string_lossy(), None).unwrap();
        assert_eq!(result, manifest);
    }

    #[test]
    fn resolve_manifest_path_in_run_dir() {
        let dir = tempfile::tempdir().unwrap();
        let groups_dir = dir.path().join("manifests").join("prepared").join("groups");
        fs::create_dir_all(&groups_dir).unwrap();
        let manifest = groups_dir.join("g01.yaml");
        fs::write(&manifest, "content").unwrap();

        let result = resolve_manifest_path("g01.yaml", Some(dir.path())).unwrap();
        assert_eq!(result, manifest);
    }

    #[test]
    fn resolve_manifest_path_not_found_returns_error() {
        let err = resolve_manifest_path("ghost.yaml", None).unwrap_err();
        assert_eq!(err.code(), "KSRCLI014");
    }

    #[test]
    fn suite_path_candidates_bare_name_includes_suite_root() {
        let suite_root = PathBuf::from("/suites");
        let candidates = suite_path_candidates("my-suite", &suite_root);
        assert!(candidates.len() >= 2);
        assert_eq!(candidates[1], PathBuf::from("/suites/my-suite/suite.md"));
    }

    #[test]
    fn suite_path_candidates_with_slash_skips_suite_root() {
        let suite_root = PathBuf::from("/suites");
        let candidates = suite_path_candidates("path/to/suite.md", &suite_root);
        assert_eq!(candidates.len(), 1);
    }

    #[test]
    fn normalize_suite_candidate_appends_suite_md_for_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let result = normalize_suite_candidate(dir.path());
        assert_eq!(result, dir.path().join("suite.md"));
    }

    #[test]
    fn normalize_suite_candidate_preserves_file_path() {
        let path = PathBuf::from("/some/suite.md");
        let result = normalize_suite_candidate(&path);
        assert_eq!(result, path);
    }
}
