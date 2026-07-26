use std::path::{Path, PathBuf};
use std::{fs, io};

/// Filesystem layout for a single run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunLayout {
    pub run_root: String,
    pub run_id: String,
}

impl RunLayout {
    #[must_use]
    pub fn new(run_root: impl Into<String>, run_id: impl Into<String>) -> Self {
        Self {
            run_root: run_root.into(),
            run_id: run_id.into(),
        }
    }

    #[must_use]
    pub fn run_dir(&self) -> PathBuf {
        PathBuf::from(&self.run_root).join(&self.run_id)
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
        Self { run_root, run_id }
    }
}
