use std::fs;
use std::path::{Path, PathBuf};

use harness_testkit::{default_group, default_suite};

use super::workflow;
use super::{RunCounts, RunLayout, RunMetadata, RunStatus, Verdict};

pub(crate) fn build_test_run_dir(tmp_path: &Path, run_id: &str) -> (PathBuf, PathBuf) {
    let suite_dir = tmp_path.join("suite");
    let _ = default_suite().write_to(&suite_dir.join("suite.md"));
    let _ = default_group().write_to(&suite_dir.join("groups").join("g01.md"));

    let layout = RunLayout::new(tmp_path.join("runs").to_string_lossy().into_owned(), run_id);
    layout.ensure_dirs().expect("create run dirs");

    let suite_path = suite_dir.join("suite.md");
    let metadata = RunMetadata {
        run_id: run_id.to_string(),
        suite_id: "example.suite".to_string(),
        suite_path: suite_path.to_string_lossy().into_owned(),
        suite_dir: suite_dir.to_string_lossy().into_owned(),
        profile: "single-zone".to_string(),
        repo_root: tmp_path.to_string_lossy().into_owned(),
        keep_clusters: false,
        created_at: "2026-03-14T00:00:00Z".to_string(),
        user_stories: Vec::new(),
        requires: Vec::new(),
    };
    write_json(&layout.metadata_path(), &metadata);

    let status = RunStatus {
        run_id: run_id.to_string(),
        suite_id: "example.suite".to_string(),
        profile: "single-zone".to_string(),
        started_at: "2026-03-14T00:00:00Z".to_string(),
        overall_verdict: Verdict::Pending,
        completed_at: None,
        counts: RunCounts::default(),
        executed_groups: Vec::new(),
        skipped_groups: Vec::new(),
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: Vec::new(),
    };
    write_json(&layout.status_path(), &status);

    workflow::initialize_runner_state(&layout.run_dir()).expect("initialize runner state");
    (layout.run_dir(), suite_dir)
}

fn write_json(path: &Path, value: &impl serde::Serialize) {
    let json = serde_json::to_string_pretty(value).expect("serialize test run fixture");
    fs::write(path, format!("{json}\n")).expect("write test run fixture");
}
