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
mod tests;
