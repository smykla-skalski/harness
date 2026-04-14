use std::fs;
use std::path::{Path, PathBuf};

use harness::run::workflow as runner_workflow;
use harness::run::{RunCounts, RunLayout, RunMetadata, RunStatus, Verdict};

use super::group::{GroupBuilder, default_group};
use super::suite::{SuiteBuilder, default_suite, default_universal_suite};

/// Sets up a complete run directory with metadata, status, and runner state.
pub struct RunDirBuilder {
    tmp_path: PathBuf,
    run_id: String,
    suite_id: String,
    profile: String,
    keep_clusters: bool,
    suite_builder: Option<SuiteBuilder>,
    group_builder: Option<GroupBuilder>,
}

impl RunDirBuilder {
    #[must_use]
    pub fn new(tmp_path: &Path, run_id: &str) -> Self {
        Self {
            tmp_path: tmp_path.to_path_buf(),
            run_id: run_id.to_string(),
            suite_id: "example.suite".to_string(),
            profile: "single-zone".to_string(),
            keep_clusters: false,
            suite_builder: None,
            group_builder: None,
        }
    }

    #[must_use]
    pub fn suite_id(mut self, id: &str) -> Self {
        self.suite_id = id.to_string();
        self
    }

    #[must_use]
    pub fn profile(mut self, profile: &str) -> Self {
        self.profile = profile.to_string();
        self
    }

    #[must_use]
    pub fn suite(mut self, suite: SuiteBuilder) -> Self {
        self.suite_builder = Some(suite);
        self
    }

    #[must_use]
    pub fn group(mut self, group: GroupBuilder) -> Self {
        self.group_builder = Some(group);
        self
    }

    /// Build the run directory, writing all files. Returns `(run_dir, suite_dir)`.
    ///
    /// # Panics
    /// Panics if directory creation or file write fails.
    #[must_use]
    pub fn build(&self) -> (PathBuf, PathBuf) {
        let suite_dir = self.tmp_path.join("suite");
        if let Some(suite_builder) = &self.suite_builder {
            let _ = suite_builder.write_to(&suite_dir.join("suite.md"));
        } else {
            let _ = default_suite().write_to(&suite_dir.join("suite.md"));
        }

        if let Some(group_builder) = &self.group_builder {
            let _ = group_builder.write_to(&suite_dir.join("groups").join("g01.md"));
        } else {
            let _ = default_group().write_to(&suite_dir.join("groups").join("g01.md"));
        }

        let run_root = self.tmp_path.join("runs");
        let layout = RunLayout::new(run_root.to_string_lossy().to_string(), self.run_id.clone());
        layout.ensure_dirs().expect("create run dirs");

        let suite_path = suite_dir.join("suite.md");
        let metadata = RunMetadata {
            run_id: self.run_id.clone(),
            suite_id: self.suite_id.clone(),
            suite_path: suite_path.to_string_lossy().to_string(),
            suite_dir: suite_dir.to_string_lossy().to_string(),
            profile: self.profile.clone(),
            repo_root: self.tmp_path.to_string_lossy().to_string(),
            keep_clusters: self.keep_clusters,
            created_at: "2026-03-14T00:00:00Z".to_string(),
            user_stories: vec![],
            requires: vec![],
        };
        let metadata_json = serde_json::to_string_pretty(&metadata).expect("serialize metadata");
        fs::write(layout.metadata_path(), format!("{metadata_json}\n")).expect("write metadata");

        let status = RunStatus {
            run_id: self.run_id.clone(),
            suite_id: self.suite_id.clone(),
            profile: self.profile.clone(),
            started_at: "2026-03-14T00:00:00Z".to_string(),
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
        };
        let status_json = serde_json::to_string_pretty(&status).expect("serialize status");
        fs::write(layout.status_path(), format!("{status_json}\n")).expect("write status");

        runner_workflow::initialize_runner_state(&layout.run_dir())
            .expect("initialize runner state");

        (layout.run_dir(), suite_dir)
    }

    /// Build and return only the run directory path.
    #[must_use]
    pub fn build_run_dir(&self) -> PathBuf {
        self.build().0
    }
}

/// Default kubernetes run: single-zone profile with standard suite and group.
#[must_use]
pub fn default_kubernetes_run(tmp: &Path, run_id: &str) -> RunDirBuilder {
    RunDirBuilder::new(tmp, run_id)
        .profile("single-zone")
        .suite(default_suite())
        .group(default_group())
}

/// Default universal run: single-zone-universal profile with universal suite and group.
#[must_use]
pub fn default_universal_run(tmp: &Path, run_id: &str) -> RunDirBuilder {
    RunDirBuilder::new(tmp, run_id)
        .profile("single-zone-universal")
        .suite(default_universal_suite())
        .group(default_group())
}

/// Initialize a run directory. Drop-in replacement for `helpers::init_run`.
/// Returns the run directory path.
#[must_use]
pub fn init_run(tmp_path: &Path, run_id: &str, profile: &str) -> PathBuf {
    RunDirBuilder::new(tmp_path, run_id)
        .profile(profile)
        .build_run_dir()
}

/// Initialize a run and return `(run_dir, suite_dir)`.
/// Drop-in replacement for `helpers::init_run_with_suite`.
#[must_use]
pub fn init_run_with_suite(tmp_path: &Path, run_id: &str, profile: &str) -> (PathBuf, PathBuf) {
    RunDirBuilder::new(tmp_path, run_id)
        .profile(profile)
        .build()
}

/// Initialize a universal mode run directory.
#[must_use]
pub fn init_universal_run(tmp_path: &Path, run_id: &str) -> PathBuf {
    RunDirBuilder::new(tmp_path, run_id)
        .profile("single-zone-universal")
        .build_run_dir()
}

/// Initialize a universal mode run with suite.
#[must_use]
pub fn init_universal_run_with_suite(tmp_path: &Path, run_id: &str) -> (PathBuf, PathBuf) {
    RunDirBuilder::new(tmp_path, run_id)
        .profile("single-zone-universal")
        .build()
}

/// Read a `RunStatus` from a run directory.
///
/// # Panics
/// Panics if reading or parsing `run-status.json` fails.
#[must_use]
pub fn read_run_status(run_dir: &Path) -> RunStatus {
    let path = run_dir.join("run-status.json");
    let text = fs::read_to_string(&path).expect("read run-status.json");
    serde_json::from_str(&text).expect("parse run-status.json")
}

/// Write a `RunStatus` to a run directory.
///
/// # Panics
/// Panics if serialization or file write fails.
pub fn write_run_status(run_dir: &Path, status: &RunStatus) {
    let path = run_dir.join("run-status.json");
    let json = serde_json::to_string_pretty(status).expect("serialize status");
    fs::write(&path, format!("{json}\n")).expect("write run-status.json");
}

/// Read runner workflow state from a run directory.
///
/// # Panics
/// Panics if reading the state file fails.
#[must_use]
pub fn read_runner_state(run_dir: &Path) -> Option<harness::run::workflow::RunnerWorkflowState> {
    runner_workflow::read_runner_state(run_dir).expect("read runner state")
}

/// Seed a minimal cluster.json in a run directory's state folder.
///
/// Creates the file that `RunServices::cluster_runtime()` loads, giving
/// the run a synthetic cluster context so that capture/apply commands work
/// without running `harness cluster`.
///
/// # Panics
/// Panics if directory creation or file write fails.
pub fn seed_cluster_state(run_dir: &Path, kubeconfig: &str) {
    let state_dir = run_dir.join("state");
    fs::create_dir_all(&state_dir).expect("create state dir");
    let payload = serde_json::json!({
        "mode": "single-up",
        "platform": "kubernetes",
        "members": [{
            "name": "kuma-test",
            "role": "primary",
            "kubeconfig": kubeconfig,
        }],
        "mode_args": ["kuma-test"],
        "helm_settings": [],
        "restart_namespaces": [],
        "repo_root": "/tmp",
    });
    fs::write(
        state_dir.join("cluster.json"),
        serde_json::to_string_pretty(&payload).unwrap(),
    )
    .expect("write cluster.json");
}

/// Seed kubectl-validate state for tests.
///
/// # Panics
/// Panics if directory creation or file write fails.
pub fn seed_kubectl_validate_state(
    xdg_data_home: &Path,
    decision: &str,
    binary_path: Option<&Path>,
) {
    let path = xdg_data_home
        .join("harness")
        .join("tooling")
        .join("kubectl-validate.json");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create tooling dir");
    }
    let mut payload = serde_json::json!({
        "schema_version": 1,
        "decision": decision,
        "decided_at": "2026-03-13T00:00:00Z",
    });
    if let Some(binary_path) = binary_path {
        payload["binary_path"] =
            serde_json::Value::String(binary_path.to_string_lossy().to_string());
    }
    fs::write(&path, serde_json::to_string(&payload).unwrap())
        .expect("write kubectl-validate state");
}
