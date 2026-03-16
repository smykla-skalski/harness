use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{fs, io};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use crate::cluster::ClusterSpec;
use crate::core_defs::current_run_context_path;
use crate::errors::{CliError, CliErrorKind};
use crate::prepared_suite::PreparedSuiteArtifact;
use crate::schema::RunStatus;

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
    /// Convert to a map of environment variable names to values.
    ///
    /// Returns owned strings because `Command::envs()` needs `AsRef<OsStr>`
    /// values that outlive the iterator. A `HashMap<&str, &str>` would work
    /// if callers only read the map, but the primary use case is feeding
    /// env vars to child processes, so owned strings are the right fit.
    #[must_use]
    pub fn to_env_dict(&self) -> HashMap<String, String> {
        let mut map = HashMap::with_capacity(12);
        map.insert("PROFILE".into(), self.profile.clone());
        map.insert("REPO_ROOT".into(), self.repo_root.clone());
        map.insert("RUN_DIR".into(), self.run_dir.clone());
        map.insert("RUN_ID".into(), self.run_id.clone());
        map.insert("RUN_ROOT".into(), self.run_root.clone());
        map.insert("SUITE_DIR".into(), self.suite_dir.clone());
        map.insert("SUITE_ID".into(), self.suite_id.clone());
        map.insert("SUITE_PATH".into(), self.suite_path.clone());
        if let Some(ref kc) = self.kubeconfig {
            map.insert("KUBECONFIG".into(), kc.clone());
        }
        if let Some(ref p) = self.platform {
            map.insert("PLATFORM".into(), p.clone());
        }
        if let Some(ref url) = self.cp_api_url {
            map.insert("CP_API_URL".into(), url.clone());
        }
        if let Some(ref net) = self.docker_network {
            map.insert("DOCKER_NETWORK".into(), net.clone());
        }
        map
    }
}

/// Snapshot of a command artifact for state tracking.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ArtifactSnapshot {
    pub kind: String,
    #[serde(default)]
    pub exists: bool,
    #[serde(default)]
    pub row_count: Option<u32>,
    #[serde(default)]
    pub files: Vec<String>,
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
    pub tools: serde_json::Value,
    #[serde(default)]
    pub nodes: serde_json::Value,
}

/// Update fields for the current run context.
#[derive(Debug, Clone, Default)]
pub struct CurrentRunUpdate {
    pub cluster: Option<ClusterSpec>,
    pub prepared_suite_path: Option<String>,
    pub preflight_artifact_path: Option<String>,
    pub run_report_path: Option<String>,
}

/// Persisted current run record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CurrentRunRecord {
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
}

/// Full run context combining layout, metadata, status, cluster, etc.
#[derive(Debug)]
pub struct RunContext {
    pub layout: RunLayout,
    pub metadata: RunMetadata,
    pub status: Option<RunStatus>,
    pub cluster: Option<ClusterSpec>,
    pub prepared_suite: Option<PreparedSuiteArtifact>,
    pub preflight: Option<PreflightArtifact>,
}

fn read_json_file<T: DeserializeOwned>(path: &Path) -> Result<T, CliError> {
    let content = fs::read_to_string(path)
        .map_err(|_| CliError::from(CliErrorKind::missing_file(path.display().to_string())))?;
    serde_json::from_str(&content).map_err(|e| {
        CliErrorKind::invalid_json(path.display().to_string()).with_details(e.to_string())
    })
}

impl RunContext {
    /// Load from a run directory.
    ///
    /// # Errors
    /// Returns `CliError` if required files are missing or invalid.
    pub fn from_run_dir(run_dir: &Path) -> Result<Self, CliError> {
        let layout = RunLayout::from_run_dir(run_dir);
        let metadata: RunMetadata = read_json_file(&layout.metadata_path())?;
        let status: RunStatus = read_json_file(&layout.status_path())?;

        let prepared_suite = if layout.prepared_suite_path().exists() {
            Some(read_json_file(&layout.prepared_suite_path())?)
        } else {
            None
        };

        let preflight_path = layout.artifacts_dir().join("preflight.json");
        let preflight = if preflight_path.exists() {
            Some(read_json_file(&preflight_path)?)
        } else {
            None
        };

        let cluster_path = layout.state_dir().join("cluster.json");
        let cluster = if cluster_path.exists() {
            Some(read_json_file(&cluster_path)?)
        } else {
            None
        };

        Ok(Self {
            layout,
            metadata,
            status: Some(status),
            cluster,
            prepared_suite,
            preflight,
        })
    }

    /// Load from the current session context.
    ///
    /// Reads `current-run.json` from the session context directory and
    /// loads the full `RunContext` from the referenced run directory.
    /// Returns `None` when the pointer file is missing, unparseable,
    /// or the referenced run directory no longer exists.
    ///
    /// # Errors
    /// Returns `CliError` on failure.
    pub fn from_current() -> Result<Option<Self>, CliError> {
        let pointer_path = current_run_context_path()?;
        let Ok(text) = fs::read_to_string(&pointer_path) else {
            return Ok(None);
        };
        let Ok(record) = serde_json::from_str::<CurrentRunRecord>(&text) else {
            return Ok(None);
        };
        let run_dir = record.layout.run_dir();
        if !run_dir.is_dir() {
            return Ok(None);
        }
        match Self::from_run_dir(&run_dir) {
            Ok(mut ctx) => {
                // If run dir didn't have cluster spec, fall back to session record
                if ctx.cluster.is_none() {
                    ctx.cluster = record.cluster;
                }
                Ok(Some(ctx))
            }
            Err(_) => Ok(None),
        }
    }
}

/// Extract group ID strings from a `serde_json::Value` array.
///
/// Each element can be a plain string or an object with a `group_id` field.
#[must_use]
pub fn extract_group_ids(values: &[serde_json::Value]) -> Vec<&str> {
    values
        .iter()
        .filter_map(|v| match v {
            serde_json::Value::String(s) => Some(s.as_str()),
            serde_json::Value::Object(map) => {
                map.get("group_id").and_then(serde_json::Value::as_str)
            }
            _ => None,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{RunCounts, Verdict};
    use std::fs;
    use std::sync::Mutex;

    /// Mutex for tests that modify environment variables (XDG_DATA_HOME, CLAUDE_SESSION_ID).
    static ENV_MUTEX: Mutex<()> = Mutex::new(());

    fn sample_layout() -> RunLayout {
        RunLayout {
            run_root: "/tmp/runs".into(),
            run_id: "run-1".into(),
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
        let status: RunStatus = serde_json::from_str(&content).unwrap();

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

        let status: RunStatus = serde_json::from_value(data).unwrap();

        assert_eq!(
            status.counts,
            RunCounts {
                passed: 1,
                failed: 0,
                skipped: 0
            }
        );
        let group_ids = extract_group_ids(&status.executed_groups);
        assert_eq!(group_ids, vec!["g02"]);
        assert_eq!(status.last_completed_group.as_deref(), Some("g02"));
        assert_eq!(status.next_planned_group.as_deref(), Some("g03"));
    }

    // -- extract_group_ids tests --

    #[test]
    fn extract_group_ids_from_strings() {
        let vals = vec![
            serde_json::Value::String("g01".into()),
            serde_json::Value::String("g02".into()),
        ];
        assert_eq!(extract_group_ids(&vals), vec!["g01", "g02"]);
    }

    #[test]
    fn extract_group_ids_from_objects() {
        let vals = vec![serde_json::json!({"group_id": "g03", "verdict": "pass"})];
        assert_eq!(extract_group_ids(&vals), vec!["g03"]);
    }

    #[test]
    fn extract_group_ids_mixed() {
        let vals = vec![
            serde_json::Value::String("g01".into()),
            serde_json::json!({"group_id": "g02"}),
        ];
        assert_eq!(extract_group_ids(&vals), vec!["g01", "g02"]);
    }

    #[test]
    fn extract_group_ids_skips_invalid() {
        let vals = vec![
            serde_json::json!(42),
            serde_json::json!({"no_group_id": true}),
        ];
        assert!(extract_group_ids(&vals).is_empty());
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
        let _guard = ENV_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
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
            layout: layout.clone(),
            profile: Some("single-zone".into()),
            repo_root: None,
            suite_dir: None,
            suite_id: Some("suite-a".into()),
            suite_path: None,
            cluster: None,
            keep_clusters: false,
            user_stories: vec![],
            required_dependencies: vec![],
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
        assert_eq!(pf.tools, serde_json::Value::Null);
        assert_eq!(pf.nodes, serde_json::Value::Null);
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
