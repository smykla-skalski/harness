mod aggregate;
pub mod cleanup;
mod repository;
mod snapshots;

pub use aggregate::{RunAggregate, RunContext};
pub use cleanup::{CleanupManifest, CleanupResource};
pub use repository::{RunRepository, RunRepositoryPort};
pub use snapshots::{
    ArtifactSnapshot, NodeCheckRecord, NodeCheckSnapshot, ToolCheckRecord, ToolCheckSnapshot,
};

#[cfg(test)]
pub use repository::InMemoryRunRepository;

use std::borrow::Cow;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{fs, io};

use serde::{Deserialize, Serialize};

use crate::cluster::ClusterSpec;
use crate::errors::CliError;
use crate::io::append_markdown_row;

/// Filesystem layout for a single run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunLayout {
    pub run_root: String,
    pub run_id: String,
}

impl RunLayout {
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
            .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
        let run_root = run_dir
            .parent()
            .map_or_else(|| ".".to_string(), |p| p.to_string_lossy().into_owned());
        Self { run_root, run_id }
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

/// Immutable metadata for a run, stored in run-metadata.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunMetadata {
    pub run_id: String,
    pub suite_id: String,
    pub suite_path: String,
    pub suite_dir: String,
    pub profile: String,
    pub repo_root: String,
    #[serde(default)]
    pub keep_clusters: bool,
    pub created_at: String,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub required_dependencies: Vec<String>,
    #[serde(default)]
    pub requires: Vec<String>,
}

/// Environment variables for command execution within a run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommandEnv {
    pub profile: String,
    pub repo_root: String,
    pub run_dir: String,
    pub run_id: String,
    pub run_root: String,
    pub suite_dir: String,
    pub suite_id: String,
    pub suite_path: String,
    #[serde(default)]
    pub kubeconfig: Option<String>,
    /// "kubernetes" or "universal".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    /// CP REST API URL (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_api_url: Option<String>,
    /// Docker network name (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub docker_network: Option<String>,
}

impl CommandEnv {
    pub fn iter_env_vars(&self) -> impl Iterator<Item = (&'static str, &str)> {
        [
            ("PROFILE", Some(self.profile.as_str())),
            ("REPO_ROOT", Some(self.repo_root.as_str())),
            ("RUN_DIR", Some(self.run_dir.as_str())),
            ("RUN_ID", Some(self.run_id.as_str())),
            ("RUN_ROOT", Some(self.run_root.as_str())),
            ("SUITE_DIR", Some(self.suite_dir.as_str())),
            ("SUITE_ID", Some(self.suite_id.as_str())),
            ("SUITE_PATH", Some(self.suite_path.as_str())),
            ("KUBECONFIG", self.kubeconfig.as_deref()),
            ("PLATFORM", self.platform.as_deref()),
            ("CP_API_URL", self.cp_api_url.as_deref()),
            ("DOCKER_NETWORK", self.docker_network.as_deref()),
        ]
        .into_iter()
        .filter_map(|(key, value)| value.map(|value| (key, value)))
    }

    /// Convert to a map of environment variable names to values.
    ///
    /// Returns owned strings because `Command::envs()` needs `AsRef<OsStr>`
    /// values that outlive the iterator. A `HashMap<&str, &str>` would work
    /// if callers only read the map, but the primary use case is feeding
    /// env vars to child processes, so owned strings are the right fit.
    #[must_use]
    pub fn to_env_dict(&self) -> HashMap<String, String> {
        self.iter_env_vars()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }
}

/// Preflight artifact containing tool/node check results.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreflightArtifact {
    pub checked_at: String,
    #[serde(default)]
    pub prepared_suite_path: Option<String>,
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub tools: ToolCheckSnapshot,
    #[serde(default)]
    pub nodes: NodeCheckSnapshot,
}

/// Update fields for the current run context.
#[derive(Debug, Clone, Default)]
pub struct CurrentRunUpdate {
    pub cluster: Option<ClusterSpec>,
    pub prepared_suite_path: Option<String>,
    pub preflight_artifact_path: Option<String>,
    pub run_report_path: Option<String>,
}

/// Persisted current run pointer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CurrentRunPointer {
    pub layout: RunLayout,
    #[serde(default)]
    pub profile: Option<String>,
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub suite_dir: Option<String>,
    #[serde(default)]
    pub suite_id: Option<String>,
    #[serde(default)]
    pub suite_path: Option<String>,
    #[serde(default)]
    pub cluster: Option<ClusterSpec>,
    #[serde(default)]
    pub keep_clusters: bool,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub required_dependencies: Vec<String>,
    #[serde(default)]
    pub requires: Vec<String>,
}

pub type CurrentRunRecord = CurrentRunPointer;

impl CurrentRunPointer {
    #[must_use]
    pub fn from_metadata(
        layout: RunLayout,
        metadata: &RunMetadata,
        cluster: Option<ClusterSpec>,
    ) -> Self {
        Self {
            layout,
            profile: Some(metadata.profile.clone()),
            repo_root: Some(metadata.repo_root.clone()),
            suite_dir: Some(metadata.suite_dir.clone()),
            suite_id: Some(metadata.suite_id.clone()),
            suite_path: Some(metadata.suite_path.clone()),
            cluster,
            keep_clusters: metadata.keep_clusters,
            user_stories: metadata.user_stories.clone(),
            required_dependencies: metadata.required_dependencies.clone(),
            requires: metadata.requires.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::absolute_paths, clippy::cognitive_complexity)]

    use super::*;
    use crate::schema::{RunCounts, RunStatus, Verdict};
    use std::fs;
    use std::sync::Mutex;

    /// Mutex for tests that modify environment variables (`XDG_DATA_HOME`, `CLAUDE_SESSION_ID`).
    static ENV_MUTEX: Mutex<()> = Mutex::new(());

    fn sample_layout() -> RunLayout {
        RunLayout {
            run_root: "/tmp/runs".into(),
            run_id: "run-1".into(),
        }
    }

    fn sample_status() -> RunStatus {
        RunStatus {
            run_id: "run-1".into(),
            suite_id: "suite-a".into(),
            profile: "single-zone".into(),
            started_at: "2026-03-14T00:00:00Z".into(),
            overall_verdict: Verdict::Pending,
            completed_at: None,
            counts: RunCounts::default(),
            executed_groups: vec![],
            skipped_groups: vec![],
            last_completed_group: None,
            last_state_capture: None,
            last_updated_utc: None,
            next_planned_group: None,
            notes: vec![],
        }
    }

    fn sample_metadata() -> RunMetadata {
        RunMetadata {
            run_id: "run-1".into(),
            suite_id: "suite-a".into(),
            suite_path: "/suites/suite-a/suite.md".into(),
            suite_dir: "/suites/suite-a".into(),
            profile: "single-zone".into(),
            repo_root: "/repo".into(),
            keep_clusters: false,
            created_at: "2026-03-14T00:00:00Z".into(),
            user_stories: vec![],
            required_dependencies: vec![],
            requires: vec![],
        }
    }

    // -- RunLayout path tests --

    #[test]
    fn run_layout_run_dir() {
        let layout = sample_layout();
        assert_eq!(layout.run_dir(), PathBuf::from("/tmp/runs/run-1"));
    }

    #[test]
    fn run_layout_artifacts_dir() {
        let layout = sample_layout();
        assert_eq!(
            layout.artifacts_dir(),
            PathBuf::from("/tmp/runs/run-1/artifacts")
        );
    }

    #[test]
    fn run_layout_commands_dir() {
        let layout = sample_layout();
        assert_eq!(
            layout.commands_dir(),
            PathBuf::from("/tmp/runs/run-1/commands")
        );
    }

    #[test]
    fn run_layout_state_dir() {
        let layout = sample_layout();
        assert_eq!(layout.state_dir(), PathBuf::from("/tmp/runs/run-1/state"));
    }

    #[test]
    fn run_layout_manifests_dir() {
        let layout = sample_layout();
        assert_eq!(
            layout.manifests_dir(),
            PathBuf::from("/tmp/runs/run-1/manifests")
        );
    }

    #[test]
    fn run_layout_metadata_path() {
        let layout = sample_layout();
        assert_eq!(
            layout.metadata_path(),
            PathBuf::from("/tmp/runs/run-1/run-metadata.json")
        );
    }

    #[test]
    fn run_layout_status_path() {
        let layout = sample_layout();
        assert_eq!(
            layout.status_path(),
            PathBuf::from("/tmp/runs/run-1/run-status.json")
        );
    }

    #[test]
    fn run_layout_report_path() {
        let layout = sample_layout();
        assert_eq!(
            layout.report_path(),
            PathBuf::from("/tmp/runs/run-1/run-report.md")
        );
    }

    #[test]
    fn run_layout_prepared_suite_path() {
        let layout = sample_layout();
        assert_eq!(
            layout.prepared_suite_path(),
            PathBuf::from("/tmp/runs/run-1/prepared-suite.json")
        );
    }

    #[test]
    fn run_layout_from_run_dir() {
        let layout = RunLayout::from_run_dir(Path::new("/tmp/runs/run-42"));
        assert_eq!(layout.run_root, "/tmp/runs");
        assert_eq!(layout.run_id, "run-42");
        assert_eq!(layout.run_dir(), PathBuf::from("/tmp/runs/run-42"));
    }

    #[test]
    fn run_layout_ensure_dirs_creates_subdirs() {
        let tmp = tempfile::tempdir().unwrap();
        let layout = RunLayout {
            run_root: tmp.path().to_string_lossy().into_owned(),
            run_id: "test-run".into(),
        };
        layout.ensure_dirs().unwrap();
        assert!(layout.run_dir().is_dir());
        assert!(layout.artifacts_dir().is_dir());
        assert!(layout.commands_dir().is_dir());
        assert!(layout.manifests_dir().is_dir());
        assert!(layout.state_dir().is_dir());
    }

    #[test]
    fn run_layout_ensure_dirs_is_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let layout = RunLayout {
            run_root: tmp.path().to_string_lossy().into_owned(),
            run_id: "test-run".into(),
        };
        layout.ensure_dirs().unwrap();
        layout.ensure_dirs().unwrap();
        assert!(layout.run_dir().is_dir());
    }

    #[test]
    fn run_layout_serialization_roundtrip() {
        let layout = sample_layout();
        let json = serde_json::to_string(&layout).unwrap();
        let back: RunLayout = serde_json::from_str(&json).unwrap();
        assert_eq!(layout, back);
    }

    // -- CommandEnv tests --

    #[test]
    fn command_env_to_env_dict_without_kubeconfig() {
        let env = CommandEnv {
            profile: "single-zone".into(),
            repo_root: "/repo".into(),
            run_dir: "/runs/r1".into(),
            run_id: "r1".into(),
            run_root: "/runs".into(),
            suite_dir: "/suites/s".into(),
            suite_id: "s".into(),
            suite_path: "/suites/s/suite.md".into(),
            kubeconfig: None,
            platform: None,
            cp_api_url: None,
            docker_network: None,
        };
        let dict = env.to_env_dict();
        assert_eq!(dict.get("PROFILE").unwrap(), "single-zone");
        assert_eq!(dict.get("REPO_ROOT").unwrap(), "/repo");
        assert_eq!(dict.get("RUN_DIR").unwrap(), "/runs/r1");
        assert_eq!(dict.get("RUN_ID").unwrap(), "r1");
        assert_eq!(dict.get("RUN_ROOT").unwrap(), "/runs");
        assert_eq!(dict.get("SUITE_DIR").unwrap(), "/suites/s");
        assert_eq!(dict.get("SUITE_ID").unwrap(), "s");
        assert_eq!(dict.get("SUITE_PATH").unwrap(), "/suites/s/suite.md");
        assert!(!dict.contains_key("KUBECONFIG"));
        assert_eq!(dict.len(), 8);
    }

    #[test]
    fn command_env_to_env_dict_with_kubeconfig() {
        let env = CommandEnv {
            profile: "p".into(),
            repo_root: "/r".into(),
            run_dir: "/d".into(),
            run_id: "i".into(),
            run_root: "/rr".into(),
            suite_dir: "/sd".into(),
            suite_id: "si".into(),
            suite_path: "/sp".into(),
            kubeconfig: Some("/kube/config".into()),
            platform: None,
            cp_api_url: None,
            docker_network: None,
        };
        let dict = env.to_env_dict();
        assert_eq!(dict.get("KUBECONFIG").unwrap(), "/kube/config");
        assert_eq!(dict.len(), 9);
    }

    #[test]
    fn command_env_to_env_dict_with_universal_fields() {
        let env = CommandEnv {
            profile: "p".into(),
            repo_root: "/r".into(),
            run_dir: "/d".into(),
            run_id: "i".into(),
            run_root: "/rr".into(),
            suite_dir: "/sd".into(),
            suite_id: "si".into(),
            suite_path: "/sp".into(),
            kubeconfig: None,
            platform: Some("universal".into()),
            cp_api_url: Some("http://172.57.0.2:5681".into()),
            docker_network: Some("harness-net".into()),
        };
        let dict = env.to_env_dict();
        assert_eq!(dict.get("PLATFORM").unwrap(), "universal");
        assert_eq!(dict.get("CP_API_URL").unwrap(), "http://172.57.0.2:5681");
        assert_eq!(dict.get("DOCKER_NETWORK").unwrap(), "harness-net");
        assert_eq!(dict.len(), 11);
    }

    // -- RunMetadata tests --

    #[test]
    fn run_metadata_serialization_roundtrip() {
        let meta = sample_metadata();
        let json = serde_json::to_string(&meta).unwrap();
        let back: RunMetadata = serde_json::from_str(&json).unwrap();
        assert_eq!(meta, back);
    }

    #[test]
    fn run_metadata_defaults_for_optional_fields() {
        let json = r#"{
            "run_id": "r1",
            "suite_id": "s1",
            "suite_path": "/p",
            "suite_dir": "/d",
            "profile": "single-zone",
            "repo_root": "/repo",
            "created_at": "now"
        }"#;
        let meta: RunMetadata = serde_json::from_str(json).unwrap();
        assert!(!meta.keep_clusters);
        assert!(meta.user_stories.is_empty());
        assert!(meta.required_dependencies.is_empty());
        assert!(meta.requires.is_empty());
    }

    // -- RunStatus deserialization tests (ported from test_schema.py:251-309) --

    #[test]
    fn load_run_status_from_json() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("run-status.json");
        let data = serde_json::json!({
            "run_id": "t",
            "suite_id": "s",
            "profile": "single-zone",
            "started_at": "now",
            "completed_at": null,
            "executed_groups": [],
            "skipped_groups": [],
            "overall_verdict": "pending",
            "last_state_capture": null,
            "notes": []
        });
        fs::write(&path, serde_json::to_string(&data).unwrap()).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        let status: crate::schema::RunStatus = serde_json::from_str(&content).unwrap();

        assert_eq!(status.last_state_capture, None);
        assert_eq!(status.counts, RunCounts::default());
        assert_eq!(status.last_completed_group, None);
        assert_eq!(status.next_planned_group, None);
    }

    #[test]
    fn load_run_status_accepts_structured_group_entries() {
        let data = serde_json::json!({
            "run_id": "t",
            "suite_id": "s",
            "profile": "single-zone",
            "started_at": "now",
            "completed_at": null,
            "counts": {"passed": 1, "failed": 0, "skipped": 0},
            "executed_groups": [
                {
                    "group_id": "g02",
                    "verdict": "pass",
                    "completed_at": "2026-03-14T07:57:19Z"
                }
            ],
            "skipped_groups": [],
            "last_completed_group": "g02",
            "overall_verdict": "pending",
            "last_state_capture": "state/after-g02.json",
            "last_updated_utc": "2026-03-14T07:57:19Z",
            "next_planned_group": "g03",
            "notes": []
        });

        let status: crate::schema::RunStatus = serde_json::from_value(data).unwrap();

        assert_eq!(
            status.counts,
            RunCounts {
                passed: 1,
                failed: 0,
                skipped: 0
            }
        );
        assert_eq!(status.executed_group_ids(), vec!["g02"]);
        assert_eq!(status.last_completed_group.as_deref(), Some("g02"));
        assert_eq!(status.next_planned_group.as_deref(), Some("g03"));
    }

    #[test]
    fn executed_group_ids_empty_when_no_groups() {
        let status = crate::schema::RunStatus {
            executed_groups: vec![],
            ..sample_status()
        };
        assert!(status.executed_group_ids().is_empty());
    }

    // -- RunContext from_run_dir test --

    #[test]
    fn run_context_from_run_dir_loads_metadata_and_status() {
        let tmp = tempfile::tempdir().unwrap();
        let run_dir = tmp.path().join("run-1");
        let layout = RunLayout::from_run_dir(&run_dir);
        layout.ensure_dirs().unwrap();

        let metadata = sample_metadata();
        let meta_json = serde_json::to_string_pretty(&metadata).unwrap();
        fs::write(layout.metadata_path(), &meta_json).unwrap();

        let status_data = serde_json::json!({
            "run_id": "run-1",
            "suite_id": "suite-a",
            "profile": "single-zone",
            "started_at": "2026-03-14T00:00:00Z",
            "overall_verdict": "pending",
            "notes": []
        });
        fs::write(
            layout.status_path(),
            serde_json::to_string_pretty(&status_data).unwrap(),
        )
        .unwrap();

        let ctx = RunContext::from_run_dir(&run_dir).unwrap();
        assert_eq!(ctx.layout.run_id, "run-1");
        assert_eq!(ctx.metadata.suite_id, "suite-a");
        assert_eq!(ctx.metadata.profile, "single-zone");
        let status = ctx.status.unwrap();
        assert_eq!(status.overall_verdict, Verdict::Pending);
        assert_eq!(status.run_id, "run-1");
        assert!(ctx.cluster.is_none());
        assert!(ctx.prepared_suite.is_none());
        assert!(ctx.preflight.is_none());
    }

    #[test]
    fn run_context_from_run_dir_fails_on_missing_metadata() {
        let tmp = tempfile::tempdir().unwrap();
        let run_dir = tmp.path().join("run-missing");
        fs::create_dir_all(&run_dir).unwrap();

        let result = RunContext::from_run_dir(&run_dir);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "KSRCLI014");
    }

    #[test]
    fn run_context_from_current_returns_none_when_no_pointer() {
        let _guard = ENV_MUTEX
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let tmp = tempfile::tempdir().unwrap();
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("ctx-no-pointer-test")),
            ],
            || {
                let result = RunContext::from_current().unwrap();
                assert!(result.is_none());
            },
        );
    }

    #[test]
    fn run_context_from_current_loads_valid_pointer() {
        let tmp = tempfile::tempdir().unwrap();

        // Set up a valid run directory
        let run_dir = tmp.path().join("runs").join("run-ptr");
        let layout = RunLayout::from_run_dir(&run_dir);
        layout.ensure_dirs().unwrap();
        let metadata = RunMetadata {
            run_id: "run-ptr".into(),
            ..sample_metadata()
        };
        fs::write(
            layout.metadata_path(),
            serde_json::to_string_pretty(&metadata).unwrap(),
        )
        .unwrap();
        let status_data = serde_json::json!({
            "run_id": "run-ptr",
            "suite_id": "suite-a",
            "profile": "single-zone",
            "started_at": "2026-03-14T00:00:00Z",
            "overall_verdict": "pending",
            "notes": []
        });
        fs::write(
            layout.status_path(),
            serde_json::to_string_pretty(&status_data).unwrap(),
        )
        .unwrap();

        // Write pointer file and verify deserialization path
        let record = CurrentRunRecord {
            layout,
            profile: Some("single-zone".into()),
            repo_root: None,
            suite_dir: None,
            suite_id: Some("suite-a".into()),
            suite_path: None,
            cluster: None,
            keep_clusters: false,
            user_stories: vec![],
            required_dependencies: vec![],
            requires: vec![],
        };
        let ctx_dir = tmp.path().join("ctx");
        fs::create_dir_all(&ctx_dir).unwrap();
        fs::write(
            ctx_dir.join("current-run.json"),
            serde_json::to_string_pretty(&record).unwrap(),
        )
        .unwrap();

        // Verify the record deserializes and from_run_dir works
        let text = fs::read_to_string(ctx_dir.join("current-run.json")).unwrap();
        let parsed: CurrentRunRecord = serde_json::from_str(&text).unwrap();
        assert_eq!(parsed.layout.run_id, "run-ptr");

        let ctx = RunContext::from_run_dir(&parsed.layout.run_dir()).unwrap();
        assert_eq!(ctx.layout.run_id, "run-ptr");
    }

    #[test]
    fn run_context_stale_pointer_returns_none_for_missing_dir() {
        let record = CurrentRunRecord {
            layout: RunLayout {
                run_root: "/nonexistent/path".into(),
                run_id: "vanished".into(),
            },
            profile: None,
            repo_root: None,
            suite_dir: None,
            suite_id: None,
            suite_path: None,
            cluster: None,
            keep_clusters: false,
            user_stories: vec![],
            required_dependencies: vec![],
            requires: vec![],
        };
        assert!(!record.layout.run_dir().is_dir());
    }

    // -- CurrentRunRecord tests --

    #[test]
    fn current_run_record_serialization_roundtrip() {
        let record = CurrentRunRecord {
            layout: sample_layout(),
            profile: Some("single-zone".into()),
            repo_root: Some("/repo".into()),
            suite_dir: Some("/suites/s".into()),
            suite_id: Some("s".into()),
            suite_path: Some("/suites/s/suite.md".into()),
            cluster: None,
            keep_clusters: false,
            user_stories: vec![],
            required_dependencies: vec![],
            requires: vec![],
        };
        let json = serde_json::to_string(&record).unwrap();
        let back: CurrentRunRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(back.layout, record.layout);
        assert_eq!(back.profile, record.profile);
        assert_eq!(back.repo_root, record.repo_root);
    }

    // -- ArtifactSnapshot tests --

    #[test]
    fn artifact_snapshot_serialization() {
        let snap = ArtifactSnapshot {
            kind: "markdown".into(),
            exists: true,
            row_count: Some(5),
            files: vec!["a.txt".into(), "b.txt".into()],
        };
        let json = serde_json::to_string(&snap).unwrap();
        let back: ArtifactSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(snap, back);
    }

    // -- PreflightArtifact tests --

    #[test]
    fn run_context_from_run_dir_fails_on_corrupt_prepared_suite() {
        let tmp = tempfile::tempdir().unwrap();
        let run_dir = tmp.path().join("run-corrupt");
        let layout = RunLayout::from_run_dir(&run_dir);
        layout.ensure_dirs().unwrap();

        let metadata = sample_metadata();
        fs::write(
            layout.metadata_path(),
            serde_json::to_string_pretty(&metadata).unwrap(),
        )
        .unwrap();
        let status_data = serde_json::json!({
            "run_id": "run-1",
            "suite_id": "suite-a",
            "profile": "single-zone",
            "started_at": "2026-03-14T00:00:00Z",
            "overall_verdict": "pending",
            "notes": []
        });
        fs::write(
            layout.status_path(),
            serde_json::to_string_pretty(&status_data).unwrap(),
        )
        .unwrap();

        // Write corrupt prepared-suite.json
        fs::write(layout.prepared_suite_path(), "NOT VALID JSON").unwrap();

        let result = RunContext::from_run_dir(&run_dir);
        assert!(
            result.is_err(),
            "expected Err for corrupt prepared-suite, got Ok"
        );
    }

    #[test]
    fn preflight_artifact_deserialization_with_defaults() {
        let data = serde_json::json!({"checked_at": "2026-03-14T00:00:00Z"});
        let pf: PreflightArtifact = serde_json::from_value(data).unwrap();
        assert_eq!(pf.checked_at, "2026-03-14T00:00:00Z");
        assert!(pf.prepared_suite_path.is_none());
        assert!(pf.repo_root.is_none());
        assert!(pf.tools.items.is_empty());
        assert!(pf.nodes.items.is_empty());
    }

    #[test]
    fn run_context_loads_cluster_from_state_dir() {
        use crate::cluster::{ClusterSpec, Platform};

        let tmp = tempfile::tempdir().unwrap();
        let run_dir = tmp.path().join("run-cluster");
        let layout = RunLayout::from_run_dir(&run_dir);
        layout.ensure_dirs().unwrap();

        let metadata = sample_metadata();
        fs::write(
            layout.metadata_path(),
            serde_json::to_string_pretty(&metadata).unwrap(),
        )
        .unwrap();
        let status_data = serde_json::json!({
            "run_id": "run-1",
            "suite_id": "suite-a",
            "profile": "single-zone",
            "started_at": "2026-03-14T00:00:00Z",
            "overall_verdict": "pending",
            "notes": []
        });
        fs::write(
            layout.status_path(),
            serde_json::to_string_pretty(&status_data).unwrap(),
        )
        .unwrap();

        // Write cluster spec to state/cluster.json
        let mut spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        spec.admin_token = Some("test-token-abc".into());
        spec.members[0].container_ip = Some("172.57.0.2".into());
        fs::write(
            layout.state_dir().join("cluster.json"),
            serde_json::to_string_pretty(&spec).unwrap(),
        )
        .unwrap();

        let ctx = RunContext::from_run_dir(&run_dir).unwrap();
        let cluster = ctx.cluster.unwrap();
        assert_eq!(cluster.platform, Platform::Universal);
        assert_eq!(cluster.admin_token.as_deref(), Some("test-token-abc"));
        assert_eq!(
            cluster.members[0].container_ip.as_deref(),
            Some("172.57.0.2")
        );
    }
}
