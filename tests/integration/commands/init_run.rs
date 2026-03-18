// Tests for the init-run command handler.
// Covers directory creation, duplicate detection, suite directory input,
// default repo root, user stories preservation, and CLI aliases.

use std::fs;
use std::path::Path;

use harness::cli::Command;
use harness::commands::run::InitArgs;
use harness::context::RunMetadata;
use harness::errors::CliError;
use harness::schema::{RunStatus, Verdict};
use harness::workflow::runner::{self as runner_workflow, RunnerPhase};

use super::super::helpers::*;

fn run_init(args: InitArgs, xdg_root: &Path) -> Result<i32, CliError> {
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(xdg_root.to_str().unwrap()))],
        || run_command(Command::Init(args)),
    )
}

#[allow(clippy::cognitive_complexity)]
fn assert_init_layout(run_dir: &Path) {
    assert!(run_dir.exists(), "run dir should exist");
    assert!(run_dir.join("run-metadata.json").exists());
    assert!(run_dir.join("run-status.json").exists());
    assert!(run_dir.join("run-report.md").exists());
    assert!(run_dir.join("suite-run-state.json").exists());
    assert!(run_dir.join("artifacts").is_dir());
    assert!(run_dir.join("commands").is_dir());
    assert!(run_dir.join("manifests").is_dir());
    assert!(run_dir.join("state").is_dir());
}

fn assert_init_metadata(run_dir: &Path) {
    let meta_text = fs::read_to_string(run_dir.join("run-metadata.json")).unwrap();
    let metadata: RunMetadata = serde_json::from_str(&meta_text).unwrap();
    assert_eq!(metadata.run_id, "run-1");
    assert_eq!(metadata.suite_id, "example.suite");
    assert_eq!(metadata.profile, "single-zone");
}

fn assert_init_status(run_dir: &Path) {
    let status_text = fs::read_to_string(run_dir.join("run-status.json")).unwrap();
    let status: RunStatus = serde_json::from_str(&status_text).unwrap();
    assert_eq!(status.overall_verdict, Verdict::Pending);
    assert_eq!(status.run_id, "run-1");

    let runner_state = runner_workflow::read_runner_state(run_dir)
        .unwrap()
        .expect("runner state should exist");
    assert_eq!(runner_state.phase, RunnerPhase::Bootstrap);
}

fn assert_init_logs(run_dir: &Path) {
    let cmd_log = run_dir.join("commands").join("command-log.md");
    assert!(cmd_log.exists(), "command log should exist");
    let cmd_text = fs::read_to_string(&cmd_log).unwrap();
    assert!(cmd_text.contains("harness init"));

    let manifest_index = run_dir.join("manifests").join("manifest-index.md");
    assert!(manifest_index.exists(), "manifest index should exist");
}

#[test]
fn init_creates_tracked_layout() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    let xdg = tmp.path().join("xdg");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));

    let result = run_init(
        InitArgs {
            suite: suite_dir.join("suite.md").to_string_lossy().to_string(),
            run_id: "run-1".to_string(),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(tmp.path().join("runs").to_string_lossy().to_string()),
        },
        &xdg,
    );
    assert!(result.is_ok(), "init should succeed: {result:?}");
    assert_eq!(result.unwrap(), 0);

    let run_dir = tmp.path().join("runs").join("run-1");
    assert_init_layout(&run_dir);
    assert_init_metadata(&run_dir);
    assert_init_status(&run_dir);
    assert_init_logs(&run_dir);
}

#[test]
fn init_fails_when_run_directory_already_exists() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    let xdg = tmp.path().join("xdg");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));
    let run_root = tmp.path().join("runs");

    // First init should succeed
    let r1 = run_init(
        InitArgs {
            suite: suite_dir.join("suite.md").to_string_lossy().to_string(),
            run_id: "run-dup".to_string(),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(run_root.to_string_lossy().to_string()),
        },
        &xdg,
    );
    assert!(r1.is_ok(), "first init should succeed: {r1:?}");

    // Second init with same run_id should fail
    let r2 = run_init(
        InitArgs {
            suite: suite_dir.join("suite.md").to_string_lossy().to_string(),
            run_id: "run-dup".to_string(),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(run_root.to_string_lossy().to_string()),
        },
        &xdg,
    );
    assert!(r2.is_err(), "duplicate init should fail");
}

#[test]
fn init_accepts_suite_directory_input() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    let xdg = tmp.path().join("xdg");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));

    // Pass the suite directory path (not suite.md) - should find suite.md
    let result = run_init(
        InitArgs {
            suite: suite_dir.to_string_lossy().to_string(),
            run_id: "run-dir-input".to_string(),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(tmp.path().join("runs").to_string_lossy().to_string()),
        },
        &xdg,
    );
    assert!(
        result.is_ok(),
        "init should accept suite directory: {result:?}"
    );
}

#[test]
fn init_defaults_repo_root_to_cwd() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    let xdg = tmp.path().join("xdg");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));

    let result = run_init(
        InitArgs {
            suite: suite_dir.join("suite.md").to_string_lossy().to_string(),
            run_id: "run-cwd".to_string(),
            profile: "single-zone".to_string(),
            repo_root: None, // no explicit repo root
            run_root: Some(tmp.path().join("runs").to_string_lossy().to_string()),
        },
        &xdg,
    );
    assert!(result.is_ok());
    let run_dir = tmp.path().join("runs").join("run-cwd");
    let meta_text = fs::read_to_string(run_dir.join("run-metadata.json")).unwrap();
    let metadata: RunMetadata = serde_json::from_str(&meta_text).unwrap();
    // repo_root should be set to something (cwd)
    assert!(!metadata.repo_root.is_empty());
}

#[test]
fn init_preserves_user_stories_from_suite() {
    use harness_testkit::SuiteBuilder;

    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite-stories");
    let xdg = tmp.path().join("xdg");
    let _ = SuiteBuilder::new("stories.suite")
        .feature("stories-test")
        .scope("unit")
        .profile("single-zone")
        .required_dependency("docker")
        .user_story("prepare manifests once")
        .user_story("validate all resources")
        .keep_clusters(false)
        .body("# Stories suite\n")
        .write_to(&suite_dir.join("suite.md"));

    let result = run_init(
        InitArgs {
            suite: suite_dir.join("suite.md").to_string_lossy().to_string(),
            run_id: "run-stories".to_string(),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(tmp.path().join("runs").to_string_lossy().to_string()),
        },
        &xdg,
    );
    assert!(result.is_ok());
    let run_dir = tmp.path().join("runs").join("run-stories");
    let meta_text = fs::read_to_string(run_dir.join("run-metadata.json")).unwrap();
    let metadata: RunMetadata = serde_json::from_str(&meta_text).unwrap();
    assert_eq!(
        metadata.user_stories,
        vec!["prepare manifests once", "validate all resources"]
    );
    assert_eq!(metadata.required_dependencies, vec!["docker"]);
    assert_eq!(metadata.requires, vec!["docker"]);
}

// ============================================================================
// CLI-level init tests (require binary)
// ============================================================================

#[test]
fn init_run_alias_still_works() {
    // harness init-run (with hyphen) should be recognized as a valid subcommand
    // It will fail because no suite is provided, but it should not say "unrecognized subcommand"
    let output = harness_testkit::harness_cmd()
        .arg("init-run")
        .output()
        .expect("run harness init-run");
    let stderr = String::from_utf8_lossy(&output.stderr);
    // Should NOT contain "unrecognized" - the alias should be recognized
    // It may fail with a usage error (missing args), but that's expected
    assert!(
        !stderr.contains("unrecognized"),
        "init-run should be a recognized alias: {stderr}"
    );
}
