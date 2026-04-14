use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use crate::kernel::topology::{ClusterSpec, Platform};
use crate::run::{RunCounts, RunStatus, Verdict};

use super::{
    ArtifactSnapshot, CommandEnv, CurrentRunRecord, PreflightArtifact, RunContext, RunLayout,
    RunMetadata,
};

mod loading;

/// Mutex for tests that modify environment variables (`XDG_DATA_HOME`, `CLAUDE_SESSION_ID`).
static ENV_MUTEX: Mutex<()> = Mutex::new(());

fn sample_layout() -> RunLayout {
    RunLayout::new("/tmp/runs", "run-1")
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
        requires: vec![],
    }
}

fn sample_command_env() -> CommandEnv {
    CommandEnv {
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
    }
}

fn assert_env_entries(dict: &HashMap<String, String>, expected: &[(&str, &str)]) {
    for (key, value) in expected {
        assert_eq!(dict.get(*key).unwrap(), value);
    }
}

fn write_run_status_file(layout: &RunLayout, run_id: &str) {
    let status_data = serde_json::json!({
        "run_id": run_id,
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
}

fn assert_run_context_identity(ctx: &RunContext, run_id: &str) {
    assert_eq!(ctx.layout.run_id, run_id);
    assert_eq!(ctx.metadata.suite_id, "suite-a");
    assert_eq!(ctx.metadata.profile, "single-zone");
}

fn assert_run_context_status(ctx: &RunContext, run_id: &str) {
    let status = ctx.status.as_ref().unwrap();
    assert_eq!(status.overall_verdict, Verdict::Pending);
    assert_eq!(status.run_id, run_id);
}

fn assert_run_context_optional_artifacts_absent(ctx: &RunContext) {
    assert!(ctx.cluster.is_none());
    assert!(ctx.prepared_suite.is_none());
    assert!(ctx.preflight.is_none());
}

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
    let layout = RunLayout::new(tmp.path().to_string_lossy().into_owned(), "test-run");
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
    let layout = RunLayout::new(tmp.path().to_string_lossy().into_owned(), "test-run");
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

#[test]
fn command_env_to_env_dict_without_kubeconfig() {
    let env = sample_command_env();
    let dict = env.to_env_dict();
    assert_env_entries(
        &dict,
        &[
            ("PROFILE", "single-zone"),
            ("REPO_ROOT", "/repo"),
            ("RUN_DIR", "/runs/r1"),
            ("RUN_ID", "r1"),
            ("RUN_ROOT", "/runs"),
            ("SUITE_DIR", "/suites/s"),
            ("SUITE_ID", "s"),
            ("SUITE_PATH", "/suites/s/suite.md"),
        ],
    );
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
    assert!(meta.requires.is_empty());
}

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
            skipped: 0,
        }
    );
    assert_eq!(status.executed_group_ids(), vec!["g02"]);
    assert_eq!(status.last_completed_group.as_deref(), Some("g02"));
    assert_eq!(status.next_planned_group.as_deref(), Some("g03"));
}

#[test]
fn executed_group_ids_empty_when_no_groups() {
    let status = RunStatus {
        executed_groups: vec![],
        ..sample_status()
    };
    assert!(status.executed_group_ids().is_empty());
}
