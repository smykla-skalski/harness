use std::borrow::Cow;
use std::io;
use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};

use super::RunLayout;

/// A `RunLayout` whose `run_dir()` has been verified to exist on disk.
///
/// Use `ValidatedRunLayout::new()` to construct. All path accessors delegate
/// to the inner `RunLayout`, but construction fails if the run directory does
/// not exist, catching stale pointers and typos at the point of use rather
/// than deep inside command logic.
#[derive(Debug, Clone)]
pub struct ValidatedRunLayout {
    layout: RunLayout,
}

impl ValidatedRunLayout {
    /// Validate that the run directory exists, returning the wrapper on success.
    ///
    /// # Errors
    ///
    /// Returns `CliError` with `missing_file` when `run_dir()` is not a directory.
    pub fn new(layout: RunLayout) -> Result<Self, CliError> {
        let run_dir = layout.run_dir();
        if !run_dir.is_dir() {
            return Err(CliErrorKind::missing_file(run_dir.to_string_lossy().into_owned()).into());
        }
        Ok(Self { layout })
    }

    /// Access the inner `RunLayout`.
    #[must_use]
    pub fn inner(&self) -> &RunLayout {
        &self.layout
    }

    /// Consume the wrapper and return the inner `RunLayout`.
    #[must_use]
    pub fn into_inner(self) -> RunLayout {
        self.layout
    }

    // -- Delegated path accessors --

    #[must_use]
    pub fn run_dir(&self) -> PathBuf {
        self.layout.run_dir()
    }

    #[must_use]
    pub fn artifacts_dir(&self) -> PathBuf {
        self.layout.artifacts_dir()
    }

    #[must_use]
    pub fn commands_dir(&self) -> PathBuf {
        self.layout.commands_dir()
    }

    #[must_use]
    pub fn audit_log_path(&self) -> PathBuf {
        self.layout.audit_log_path()
    }

    #[must_use]
    pub fn audit_artifacts_dir(&self) -> PathBuf {
        self.layout.audit_artifacts_dir()
    }

    #[must_use]
    pub fn command_log_path(&self) -> PathBuf {
        self.layout.command_log_path()
    }

    #[must_use]
    pub fn state_dir(&self) -> PathBuf {
        self.layout.state_dir()
    }

    #[must_use]
    pub fn manifests_dir(&self) -> PathBuf {
        self.layout.manifests_dir()
    }

    #[must_use]
    pub fn metadata_path(&self) -> PathBuf {
        self.layout.metadata_path()
    }

    #[must_use]
    pub fn status_path(&self) -> PathBuf {
        self.layout.status_path()
    }

    #[must_use]
    pub fn report_path(&self) -> PathBuf {
        self.layout.report_path()
    }

    #[must_use]
    pub fn prepared_suite_path(&self) -> PathBuf {
        self.layout.prepared_suite_path()
    }

    #[must_use]
    pub fn preflight_artifact_path(&self) -> PathBuf {
        self.layout.preflight_artifact_path()
    }

    #[must_use]
    pub fn cleanup_manifest_path(&self) -> PathBuf {
        self.layout.cleanup_manifest_path()
    }

    #[must_use]
    pub fn prepared_baseline_dir(&self) -> PathBuf {
        self.layout.prepared_baseline_dir()
    }

    #[must_use]
    pub fn prepared_groups_dir(&self) -> PathBuf {
        self.layout.prepared_groups_dir()
    }

    /// Create required subdirectories.
    ///
    /// # Errors
    /// Returns IO error on failure.
    pub fn ensure_dirs(&self) -> io::Result<()> {
        self.layout.ensure_dirs()
    }

    /// Strip the run directory prefix from `path`, returning a relative string.
    #[must_use]
    pub fn relative_path<'a>(&self, path: &'a Path) -> Cow<'a, str> {
        self.layout.relative_path(path)
    }

    /// Append a row to `commands/command-log.md`.
    ///
    /// # Errors
    /// Returns `CliError` on IO or shape mismatch.
    pub fn append_command_log(
        &self,
        ran_at: &str,
        phase: &str,
        group_id: &str,
        command: &str,
        exit_code: &str,
        artifact: &str,
    ) -> Result<(), CliError> {
        self.layout
            .append_command_log(ran_at, phase, group_id, command, exit_code, artifact)
    }

    /// Append a row to `manifests/manifest-index.md`.
    ///
    /// # Errors
    /// Returns `CliError` on IO or shape mismatch.
    pub fn append_manifest_index(
        &self,
        copied_at: &str,
        manifest: &str,
        validated: &str,
        applied: &str,
        notes: &str,
    ) -> Result<(), CliError> {
        self.layout
            .append_manifest_index(copied_at, manifest, validated, applied, notes)
    }
}

#[cfg(test)]
mod tests;
