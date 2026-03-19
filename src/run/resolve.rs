use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::run::context::RunRepository;
use crate::workspace;

/// Resolved run directory.
#[derive(Debug, Clone)]
pub struct ResolvedRun {
    pub run_dir: PathBuf,
}

/// Resolve a run directory from individual fields.
///
/// Tries `run_dir` directly, then `run_root/run_id`. Returns the first
/// existing candidate or an error.
///
/// # Errors
/// Returns `CliError` if the run directory cannot be determined.
pub fn resolve_run_directory(
    run_dir: Option<&Path>,
    run_id: Option<&str>,
    run_root: Option<&Path>,
) -> Result<ResolvedRun, CliError> {
    if let Some(run_dir) = run_dir {
        if run_dir.exists() {
            return Ok(ResolvedRun {
                run_dir: run_dir.to_path_buf(),
            });
        }
        return Err(CliErrorKind::missing_file(run_dir.display().to_string()).into());
    }

    if let (Some(run_root), Some(run_id)) = (run_root, run_id) {
        let path = run_root.join(run_id);
        if path.exists() {
            return Ok(ResolvedRun { run_dir: path });
        }
        return Err(CliErrorKind::missing_run_location(run_id.to_string()).into());
    }

    if let Some(run_id) = run_id {
        return Err(CliErrorKind::missing_run_location(run_id.to_string()).into());
    }

    // Fall back to the current-run pointer in the session context directory.
    let repo = RunRepository;
    if let Some(run_dir) = repo.current_run_dir()? {
        return Ok(ResolvedRun { run_dir });
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
    let suite_root = workspace::suite_root();
    let candidates = suite_path_candidates(raw, &suite_root)?;

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
    let candidates = manifest_path_candidates(raw, run_dir)?;

    for candidate in &candidates {
        if candidate.exists() {
            return Ok(candidate.clone());
        }
    }

    Err(CliErrorKind::missing_file(raw.to_string()).into())
}

fn suite_path_candidates(raw: &str, suite_root: &Path) -> Result<Vec<PathBuf>, CliError> {
    let raw_path = PathBuf::from(raw);
    let direct = if raw_path.is_absolute() {
        raw_path
    } else {
        env::current_dir()?.join(&raw_path)
    };

    let mut items = vec![direct];
    if !raw.contains('/') && !raw.contains('\\') {
        items.push(suite_root.join(raw).join("suite.md"));
    }
    Ok(items)
}

fn normalize_suite_candidate(candidate: &Path) -> PathBuf {
    if candidate.is_dir() {
        candidate.join("suite.md")
    } else {
        candidate.to_path_buf()
    }
}

fn manifest_path_candidates(raw: &str, run_dir: Option<&Path>) -> Result<Vec<PathBuf>, CliError> {
    let raw_path = PathBuf::from(raw);
    if raw_path.is_absolute() {
        if raw_path.exists() {
            return Ok(vec![raw_path]);
        }
        // The absolute path doesn't exist. If stripping the leading slash
        // yields a plausible relative path, fall through and try it as
        // relative instead of failing immediately.
        let stripped = raw.trim_start_matches('/');
        if stripped.is_empty() {
            return Ok(vec![raw_path]);
        }
        return manifest_path_candidates(stripped, run_dir);
    }

    let mut items = vec![env::current_dir()?.join(&raw_path)];

    if let Some(active) = run_dir {
        // Run directory prepared manifests
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

        // Suite directory (read from run metadata if available)
        if let Ok(content) = fs::read_to_string(active.join("run-metadata.json"))
            && let Ok(meta) = serde_json::from_str::<serde_json::Value>(&content)
            && let Some(suite_dir) = meta["suite_dir"].as_str()
        {
            let sd = PathBuf::from(suite_dir);
            items.push(sd.join("groups").join(&raw_path));
            items.push(sd.join("baseline").join(&raw_path));
            items.push(sd.join(&raw_path));
        }
    }

    Ok(items)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn resolve_run_directory_with_existing_dir() {
        let dir = tempfile::tempdir().unwrap();
        let resolved = resolve_run_directory(Some(dir.path()), None, None).unwrap();
        assert_eq!(resolved.run_dir, dir.path());
    }

    #[test]
    fn resolve_run_directory_with_root_and_id() {
        let dir = tempfile::tempdir().unwrap();
        let run_dir = dir.path().join("my-run");
        fs::create_dir(&run_dir).unwrap();
        let resolved = resolve_run_directory(None, Some("my-run"), Some(dir.path())).unwrap();
        assert_eq!(resolved.run_dir, run_dir);
    }

    #[test]
    fn resolve_run_directory_missing_returns_error() {
        let err = resolve_run_directory(None, Some("ghost"), Some(Path::new("/nonexistent")))
            .unwrap_err();
        assert_eq!(err.code(), "KSRCLI018");
    }

    #[test]
    fn resolve_run_directory_no_fields_returns_pointer_error() {
        let tmp = tempfile::tempdir().unwrap();
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("resolve-no-pointer-test")),
            ],
            || {
                let err = resolve_run_directory(None, None, None).unwrap_err();
                assert_eq!(err.code(), "KSRCLI005");
            },
        );
    }

    #[test]
    fn resolve_run_directory_falls_back_to_current_run_pointer() {
        use crate::run::context::{CurrentRunRecord, RunLayout};

        let tmp = tempfile::tempdir().unwrap();

        // Create a run directory the pointer will reference.
        let run_dir = tmp.path().join("runs").join("fallback-run");
        fs::create_dir_all(&run_dir).unwrap();

        // Write the pointer file in the session context directory.
        let record = CurrentRunRecord {
            layout: RunLayout::new(
                tmp.path().join("runs").to_string_lossy().into_owned(),
                "fallback-run",
            ),
            profile: None,
            repo_root: None,
            suite_dir: None,
            suite_id: None,
            suite_path: None,
            cluster: None,
            keep_clusters: false,
            user_stories: vec![],
            requires: vec![],
        };

        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().join("xdg").to_str().unwrap()),
                ),
                ("CLAUDE_SESSION_ID", Some("resolve-fallback-test")),
            ],
            || {
                let ctx_path = workspace::current_run_context_path().unwrap();
                fs::create_dir_all(ctx_path.parent().unwrap()).unwrap();
                fs::write(&ctx_path, serde_json::to_string_pretty(&record).unwrap()).unwrap();

                let resolved = resolve_run_directory(None, None, None).unwrap();
                assert_eq!(resolved.run_dir, run_dir);
            },
        );
    }

    #[test]
    fn resolve_run_directory_only_run_id_returns_location_error() {
        let err = resolve_run_directory(None, Some("orphan"), None).unwrap_err();
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
    fn resolve_manifest_path_leading_slash_treated_as_relative() {
        let dir = tempfile::tempdir().unwrap();
        let groups_dir = dir.path().join("manifests").join("prepared").join("groups");
        let nested = groups_dir.join("g09");
        fs::create_dir_all(&nested).unwrap();
        let manifest = nested.join("01.yaml");
        fs::write(&manifest, "content").unwrap();

        let result = resolve_manifest_path("/g09/01.yaml", Some(dir.path())).unwrap();
        assert_eq!(result, manifest);
    }

    #[test]
    fn suite_path_candidates_bare_name_includes_suite_root() {
        let suite_root = PathBuf::from("/suites");
        let candidates = suite_path_candidates("my-suite", &suite_root).unwrap();
        assert!(candidates.len() >= 2);
        assert_eq!(candidates[1], PathBuf::from("/suites/my-suite/suite.md"));
    }

    #[test]
    fn suite_path_candidates_with_slash_skips_suite_root() {
        let suite_root = PathBuf::from("/suites");
        let candidates = suite_path_candidates("path/to/suite.md", &suite_root).unwrap();
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
