use std::borrow::Cow;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::{fs, io};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::io::append_markdown_row;

/// Filesystem layout for a single run.
///
/// The `run_dir()` result is cached via `OnceLock` to avoid repeated
/// `PathBuf` allocation on every call. Because `OnceLock` does not
/// implement `PartialEq` or `Clone` automatically, those traits are
/// implemented manually below.
#[derive(Debug, Serialize, Deserialize)]
pub struct RunLayout {
    pub run_root: String,
    pub run_id: String,
    #[serde(skip)]
    cached_run_dir: OnceLock<PathBuf>,
}

impl Clone for RunLayout {
    fn clone(&self) -> Self {
        Self {
            run_root: self.run_root.clone(),
            run_id: self.run_id.clone(),
            cached_run_dir: OnceLock::new(),
        }
    }
}

impl PartialEq for RunLayout {
    fn eq(&self, other: &Self) -> bool {
        self.run_root == other.run_root && self.run_id == other.run_id
    }
}

impl Eq for RunLayout {}

impl RunLayout {
    #[must_use]
    pub fn new(run_root: impl Into<String>, run_id: impl Into<String>) -> Self {
        Self {
            run_root: run_root.into(),
            run_id: run_id.into(),
            cached_run_dir: OnceLock::new(),
        }
    }

    #[must_use]
    pub fn run_dir(&self) -> PathBuf {
        self.cached_run_dir
            .get_or_init(|| PathBuf::from(&self.run_root).join(&self.run_id))
            .clone()
    }

    #[must_use]
    pub fn artifacts_dir(&self) -> PathBuf {
        self.run_dir().join("artifacts")
    }

    #[must_use]
    pub fn commands_dir(&self) -> PathBuf {
        self.run_dir().join("commands")
    }

    #[must_use]
    pub fn audit_log_path(&self) -> PathBuf {
        self.run_dir().join("audit-log.jsonl")
    }

    #[must_use]
    pub fn audit_artifacts_dir(&self) -> PathBuf {
        self.artifacts_dir().join("audit")
    }

    #[must_use]
    pub fn command_log_path(&self) -> PathBuf {
        self.commands_dir().join("command-log.md")
    }

    #[must_use]
    pub fn state_dir(&self) -> PathBuf {
        self.run_dir().join("state")
    }

    #[must_use]
    pub fn manifests_dir(&self) -> PathBuf {
        self.run_dir().join("manifests")
    }

    #[must_use]
    pub fn metadata_path(&self) -> PathBuf {
        self.run_dir().join("run-metadata.json")
    }

    #[must_use]
    pub fn status_path(&self) -> PathBuf {
        self.run_dir().join("run-status.json")
    }

    #[must_use]
    pub fn report_path(&self) -> PathBuf {
        self.run_dir().join("run-report.md")
    }

    #[must_use]
    pub fn prepared_suite_path(&self) -> PathBuf {
        self.run_dir().join("prepared-suite.json")
    }

    #[must_use]
    pub fn preflight_artifact_path(&self) -> PathBuf {
        self.artifacts_dir().join("preflight.json")
    }

    #[must_use]
    pub fn cleanup_manifest_path(&self) -> PathBuf {
        self.state_dir().join("cleanup-manifest.json")
    }

    #[must_use]
    pub fn prepared_baseline_dir(&self) -> PathBuf {
        self.manifests_dir().join("prepared").join("baseline")
    }

    #[must_use]
    pub fn prepared_groups_dir(&self) -> PathBuf {
        self.manifests_dir().join("prepared").join("groups")
    }

    /// Create required subdirectories.
    ///
    /// # Errors
    /// Returns IO error on failure.
    pub fn ensure_dirs(&self) -> io::Result<()> {
        for dir in [
            self.run_dir(),
            self.artifacts_dir(),
            self.commands_dir(),
            self.manifests_dir(),
            self.state_dir(),
        ] {
            fs::create_dir_all(dir)?;
        }
        Ok(())
    }

    /// Build from a run directory path.
    #[must_use]
    pub fn from_run_dir(run_dir: &Path) -> Self {
        let run_id = run_dir
            .file_name()
            .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
        let run_root = run_dir.parent().map_or_else(
            || ".".to_string(),
            |parent| parent.to_string_lossy().into_owned(),
        );
        Self {
            run_root,
            run_id,
            cached_run_dir: OnceLock::new(),
        }
    }

    /// Strip the run directory prefix from `path`, returning a relative string.
    ///
    /// Falls back to the full display path when stripping fails.
    #[must_use]
    pub fn relative_path<'a>(&self, path: &'a Path) -> Cow<'a, str> {
        let run_dir = self.run_dir();
        let relative = path.strip_prefix(&run_dir).unwrap_or(path);
        relative
            .to_str()
            .map_or_else(|| Cow::Owned(relative.display().to_string()), Cow::Borrowed)
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
        append_markdown_row(
            &self.command_log_path(),
            &[
                "ran_at",
                "phase",
                "group_id",
                "command",
                "exit_code",
                "artifact",
            ],
            &[ran_at, phase, group_id, command, exit_code, artifact],
        )
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
        let manifest_index = self.manifests_dir().join("manifest-index.md");
        append_markdown_row(
            &manifest_index,
            &["copied_at", "manifest", "validated", "applied", "notes"],
            &[copied_at, manifest, validated, applied, notes],
        )
    }
}
