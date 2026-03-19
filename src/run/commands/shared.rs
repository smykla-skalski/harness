use std::env;
use std::path::{Path, PathBuf};

use crate::workspace::harness_data_root;
use crate::errors::{CliError, CliErrorKind};
use crate::suite_defaults::default_repo_root_for_suite;

/// Resolve the repo root for `init` when not explicitly provided.
///
/// # Errors
/// Returns `CliError` if an explicit path is given but cannot be canonicalized.
pub(crate) fn resolve_init_repo_root(
    raw: Option<&str>,
    suite_dir: &Path,
) -> Result<PathBuf, CliError> {
    if let Some(r) = raw {
        return PathBuf::from(r)
            .canonicalize()
            .map_err(|e| CliErrorKind::io(format!("canonicalize repo root {r}: {e}")).into());
    }
    if let Some(default) = default_repo_root_for_suite(suite_dir) {
        return Ok(default);
    }
    Ok(env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

/// Resolve the run root for `init` when not explicitly provided.
///
/// Priority: explicit `--run-root` flag > `suite_dir/runs` > XDG runs directory.
pub(crate) fn resolve_run_root(raw: Option<&str>, suite_dir: Option<&Path>) -> PathBuf {
    if let Some(explicit) = raw {
        return PathBuf::from(explicit);
    }
    if let Some(directory) = suite_dir {
        return directory.join("runs");
    }
    harness_data_root().join("runs")
}
