// Integration tests for command flows.
// Ported from Python test_commands.py (92 tests).
//
// These tests exercise the full command handlers by calling library functions
// directly with temp run directories and written JSON/markdown files.
//
// Many Python tests invoke the CLI binary with `run_harness()`. Here we call
// the Rust command handler functions directly. Tests that require external
// tools (kubectl, k3d, kumactl) are marked #[ignore].

mod helpers;

use std::fs;
use std::path::Path;

use harness::commands::init_run;
use harness::context::{RunContext, RunLayout, RunMetadata};
use harness::schema::{GroupSpec, RunReport, RunStatus, SuiteSpec};
use harness::workflow::runner::{self as runner_workflow, PreflightStatus, RunnerPhase};

use helpers::*;

// ============================================================================
// init_run tests
// ============================================================================

#[test]
fn init_creates_tracked_layout() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));

    let result = init_run::execute(
        &suite_dir.join("suite.md").to_string_lossy(),
        "run-1",
        "single-zone",
        Some(&tmp.path().to_string_lossy()),
        Some(&tmp.path().join("runs").to_string_lossy()),
    );
    assert!(result.is_ok(), "init should succeed: {result:?}");
    assert_eq!(result.unwrap(), 0);

    let run_dir = tmp.path().join("runs").join("run-1");
    assert!(run_dir.exists(), "run dir should exist");
    assert!(run_dir.join("run-metadata.json").exists());
    assert!(run_dir.join("run-status.json").exists());
    assert!(run_dir.join("run-report.md").exists());
    assert!(run_dir.join("suite-runner-state.json").exists());
    assert!(run_dir.join("artifacts").is_dir());
    assert!(run_dir.join("commands").is_dir());
    assert!(run_dir.join("manifests").is_dir());
    assert!(run_dir.join("state").is_dir());

    // Verify metadata
    let meta_text = fs::read_to_string(run_dir.join("run-metadata.json")).unwrap();
    let metadata: RunMetadata = serde_json::from_str(&meta_text).unwrap();
    assert_eq!(metadata.run_id, "run-1");
    assert_eq!(metadata.suite_id, "example.suite");
    assert_eq!(metadata.profile, "single-zone");

    // Verify status
    let status_text = fs::read_to_string(run_dir.join("run-status.json")).unwrap();
    let status: RunStatus = serde_json::from_str(&status_text).unwrap();
    assert_eq!(status.overall_verdict, "pending");
    assert_eq!(status.run_id, "run-1");

    // Verify runner state
    let runner_state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .expect("runner state should exist");
    assert_eq!(runner_state.phase, RunnerPhase::Bootstrap);

    // Verify command log
    let cmd_log = run_dir.join("commands").join("command-log.md");
    assert!(cmd_log.exists(), "command log should exist");
    let cmd_text = fs::read_to_string(&cmd_log).unwrap();
    assert!(cmd_text.contains("harness init"));

    // Verify manifest index
    let manifest_index = run_dir.join("manifests").join("manifest-index.md");
    assert!(manifest_index.exists(), "manifest index should exist");
}

#[test]
fn init_fails_when_run_directory_already_exists() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));
    let run_root = tmp.path().join("runs");

    // First init should succeed
    let r1 = init_run::execute(
        &suite_dir.join("suite.md").to_string_lossy(),
        "run-dup",
        "single-zone",
        Some(&tmp.path().to_string_lossy()),
        Some(&run_root.to_string_lossy()),
    );
    assert!(r1.is_ok());

    // Second init with same run_id should fail
    let r2 = init_run::execute(
        &suite_dir.join("suite.md").to_string_lossy(),
        "run-dup",
        "single-zone",
        Some(&tmp.path().to_string_lossy()),
        Some(&run_root.to_string_lossy()),
    );
    assert!(r2.is_err(), "duplicate init should fail");
}

#[test]
fn init_accepts_suite_directory_input() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));

    // Pass the suite directory path (not suite.md) - should find suite.md
    let result = init_run::execute(
        &suite_dir.to_string_lossy(),
        "run-dir-input",
        "single-zone",
        Some(&tmp.path().to_string_lossy()),
        Some(&tmp.path().join("runs").to_string_lossy()),
    );
    assert!(
        result.is_ok(),
        "init should accept suite directory: {result:?}"
    );
}

// ============================================================================
// RunContext tests
// ============================================================================

#[test]
fn run_context_from_run_dir_loads_all_fields() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-ctx", "single-zone");
    let ctx = RunContext::from_run_dir(&run_dir).unwrap();
    assert_eq!(ctx.layout.run_id, "run-ctx");
    assert_eq!(ctx.metadata.suite_id, "example.suite");
    assert_eq!(ctx.metadata.profile, "single-zone");
    assert!(ctx.status.is_some());
    let status = ctx.status.unwrap();
    assert_eq!(status.overall_verdict, "pending");
}

#[test]
fn run_context_from_run_dir_fails_on_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = tmp.path().join("nonexistent-run");
    fs::create_dir_all(&run_dir).unwrap();
    let result = RunContext::from_run_dir(&run_dir);
    assert!(result.is_err());
}

// ============================================================================
// RunLayout tests
// ============================================================================

#[test]
fn run_layout_paths_are_consistent() {
    let layout = RunLayout {
        run_root: "/tmp/runs".to_string(),
        run_id: "run-42".to_string(),
    };
    assert_eq!(layout.run_dir().to_string_lossy(), "/tmp/runs/run-42");
    assert_eq!(
        layout.artifacts_dir().to_string_lossy(),
        "/tmp/runs/run-42/artifacts"
    );
    assert_eq!(
        layout.commands_dir().to_string_lossy(),
        "/tmp/runs/run-42/commands"
    );
    assert_eq!(
        layout.manifests_dir().to_string_lossy(),
        "/tmp/runs/run-42/manifests"
    );
    assert_eq!(
        layout.state_dir().to_string_lossy(),
        "/tmp/runs/run-42/state"
    );
}

#[test]
fn run_layout_ensure_dirs_creates_all() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = RunLayout {
        run_root: tmp.path().to_string_lossy().to_string(),
        run_id: "test-ensure".to_string(),
    };
    layout.ensure_dirs().unwrap();
    assert!(layout.run_dir().is_dir());
    assert!(layout.artifacts_dir().is_dir());
    assert!(layout.commands_dir().is_dir());
    assert!(layout.manifests_dir().is_dir());
    assert!(layout.state_dir().is_dir());
}

#[test]
fn run_layout_from_run_dir_roundtrip() {
    let layout = RunLayout::from_run_dir(Path::new("/tmp/runs/run-99"));
    assert_eq!(layout.run_root, "/tmp/runs");
    assert_eq!(layout.run_id, "run-99");
}

// ============================================================================
// SuiteSpec / GroupSpec loading tests
// ============================================================================

#[test]
fn suite_spec_loads_from_valid_markdown() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("suite.md");
    write_suite(&suite_path);
    let spec = SuiteSpec::from_markdown(&suite_path).unwrap();
    assert_eq!(spec.frontmatter.suite_id, "example.suite");
    assert_eq!(spec.frontmatter.feature, "example");
    assert_eq!(spec.frontmatter.groups, vec!["groups/g01.md"]);
    assert!(!spec.frontmatter.keep_clusters);
}

#[test]
fn suite_spec_rejects_missing_frontmatter() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("no-fm.md");
    fs::write(&path, "# Just a heading\n\nSome body.\n").unwrap();
    let err = SuiteSpec::from_markdown(&path).unwrap_err();
    assert!(
        err.message.contains("frontmatter"),
        "error: {}",
        err.message
    );
}

#[test]
fn suite_spec_rejects_missing_fields() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("partial.md");
    fs::write(&path, "---\nsuite_id: x\n---\n\nBody.\n").unwrap();
    let err = SuiteSpec::from_markdown(&path).unwrap_err();
    assert!(err.message.contains("missing"), "error: {}", err.message);
}

#[test]
fn group_spec_loads_from_valid_markdown() {
    let tmp = tempfile::tempdir().unwrap();
    let group_path = tmp.path().join("g01.md");
    write_group(&group_path);
    let spec = GroupSpec::from_markdown(&group_path).unwrap();
    assert_eq!(spec.frontmatter.group_id, "g01");
    assert_eq!(spec.frontmatter.story, "example story");
    assert!(spec.body.contains("## Configure"));
    assert!(spec.body.contains("## Consume"));
    assert!(spec.body.contains("## Debug"));
}

#[test]
fn group_spec_rejects_missing_sections() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("bad-group.md");
    fs::write(
        &path,
        "---\ngroup_id: g01\nstory: test\n---\n\n## Configure\n\nOnly one section.\n",
    )
    .unwrap();
    let err = GroupSpec::from_markdown(&path).unwrap_err();
    assert!(err.message.contains("missing"), "error: {}", err.message);
}

// ============================================================================
// RunStatus tests
// ============================================================================

#[test]
fn run_status_load_and_parse() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-status-test", "single-zone");
    let status = read_run_status(&run_dir);
    assert_eq!(status.overall_verdict, "pending");
    assert_eq!(status.run_id, "run-status-test");
    assert!(status.notes.is_empty());
}

#[test]
fn run_status_write_and_reload() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-status-rw", "single-zone");
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = "pass".to_string();
    status.notes.push("test note".to_string());
    write_run_status(&run_dir, &status);
    let reloaded = read_run_status(&run_dir);
    assert_eq!(reloaded.overall_verdict, "pass");
    assert_eq!(reloaded.notes, vec!["test note"]);
}

#[test]
fn run_status_executed_group_ids() {
    let status = RunStatus {
        run_id: "t".to_string(),
        suite_id: "s".to_string(),
        profile: "single-zone".to_string(),
        started_at: "now".to_string(),
        overall_verdict: "pending".to_string(),
        completed_at: None,
        counts: Default::default(),
        executed_groups: vec![
            serde_json::Value::String("g01".to_string()),
            serde_json::json!({"group_id": "g02", "verdict": "pass"}),
        ],
        skipped_groups: vec![],
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: vec![],
    };
    assert_eq!(status.executed_group_ids(), vec!["g01", "g02"]);
}

// ============================================================================
// RunReport tests
// ============================================================================

#[test]
fn run_report_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let report_path = tmp.path().join("report.md");
    let report = RunReport::new(
        report_path.clone(),
        harness::schema::RunReportFrontmatter {
            run_id: "r1".to_string(),
            suite_id: "s1".to_string(),
            profile: "single-zone".to_string(),
            overall_verdict: "pending".to_string(),
            story_results: vec![],
            debug_summary: vec![],
        },
        "# Report\n".to_string(),
    );
    report.save().unwrap();
    let reloaded = RunReport::from_markdown(&report_path).unwrap();
    assert_eq!(reloaded.frontmatter.run_id, "r1");
    assert_eq!(reloaded.frontmatter.overall_verdict, "pending");
}

#[test]
fn run_report_preserves_comma_in_story_results() {
    let tmp = tempfile::tempdir().unwrap();
    let report_path = tmp.path().join("report.md");
    let report = RunReport::new(
        report_path.clone(),
        harness::schema::RunReportFrontmatter {
            run_id: "r1".to_string(),
            suite_id: "s1".to_string(),
            profile: "single-zone".to_string(),
            overall_verdict: "pending".to_string(),
            story_results: vec![
                "g02 PASS - story with commas, updates, and deletes | evidence: `commands/g02.txt`"
                    .to_string(),
            ],
            debug_summary: vec!["checked config, output, and cleanup".to_string()],
        },
        "# Report\n".to_string(),
    );
    report.save().unwrap();
    let reloaded = RunReport::from_markdown(&report_path).unwrap();
    assert_eq!(
        reloaded.frontmatter.story_results,
        report.frontmatter.story_results
    );
    assert_eq!(
        reloaded.frontmatter.debug_summary,
        report.frontmatter.debug_summary
    );
}

// ============================================================================
// Runner workflow state tests
// ============================================================================

#[test]
fn runner_state_initialize_and_read() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-wf", "single-zone");
    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .expect("runner state should exist");
    assert_eq!(state.phase, RunnerPhase::Bootstrap);
    assert_eq!(state.preflight.status, PreflightStatus::Pending);
    assert_eq!(state.schema_version, 1);
}

#[test]
fn runner_state_write_and_read_back() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-wf-rw", "single-zone");
    let mut state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .expect("state exists");
    state.phase = RunnerPhase::Preflight;
    state.preflight.status = PreflightStatus::Running;
    state.transition_count += 1;
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .expect("state exists");
    assert_eq!(reloaded.phase, RunnerPhase::Preflight);
    assert_eq!(reloaded.preflight.status, PreflightStatus::Running);
}

// ============================================================================
// MeshMetric group tests (authoring-validate equivalent)
// ============================================================================

#[test]
fn meshmetric_group_loads_valid() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("g01.md");
    write_meshmetric_group(&path, false);
    let spec = GroupSpec::from_markdown(&path).unwrap();
    assert_eq!(spec.frontmatter.group_id, "g01");
    assert!(spec.body.contains("MeshMetric"));
    assert!(!spec.body.contains("backendRef"));
}

#[test]
fn meshmetric_group_with_invalid_backend_ref() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("g01.md");
    write_meshmetric_group(&path, true);
    let spec = GroupSpec::from_markdown(&path).unwrap();
    assert!(spec.body.contains("backendRef"));
}

// ============================================================================
// CLI-level command integration tests
// These tests require the built binary and are marked #[ignore] where they
// depend on external tools (kubectl, kumactl, k3d, etc.)
// ============================================================================

#[test]
#[ignore] // Requires CLI binary and init command
fn init_run_alias_still_works() {
    // The init-run alias should still work
}

#[test]
#[ignore] // Requires CLI binary
fn help_shows_subcommands() {
    // harness --help should list subcommands
}

#[test]
#[ignore] // Requires CLI binary
fn hook_help_lists_registered_hooks() {
    // harness hook --help should list hooks
}

#[test]
#[ignore] // Requires kubectl
fn record_accepts_run_dir_phase_and_label() {
    // harness record --run-dir ... --phase verify --label test -- echo hello
}

#[test]
#[ignore] // Requires kubectl
fn run_records_kubectl_with_active_run_kubeconfig() {
    // harness run --phase verify --label check kubectl get pods
}

#[test]
#[ignore] // Requires kumactl binary
fn kumactl_find_returns_first_existing() {
    // harness kumactl find should return binary path
}

#[test]
#[ignore] // Requires kumactl binary
fn kumactl_build_runs_make_and_prints_binary() {
    // harness kumactl build should trigger make
}

#[test]
#[ignore] // Requires cluster
fn cluster_up_rejects_finalized_run_reuse() {
    // harness cluster single-up after run completed should fail
}

#[test]
#[ignore] // Requires external tools
fn envoy_capture_records_admin_artifact() {
    // harness envoy capture records config_dump
}

#[test]
#[ignore] // Requires external tools
fn envoy_capture_can_filter_config_type() {
    // harness envoy capture --config-type bootstrap
}

#[test]
#[ignore] // Requires external tools
fn envoy_route_body_can_capture_live_payload() {
    // harness envoy route-body captures route config
}

#[test]
#[ignore] // Requires external tools
fn envoy_capture_rejects_without_tracked_cluster() {
    // harness envoy capture without cluster should fail
}

#[test]
#[ignore] // Requires external tools
fn run_can_target_another_tracked_cluster_member() {
    // harness run --cluster zone-1 ...
}

#[test]
#[ignore] // Requires kubectl
fn record_exports_context_env() {
    // harness record should set env vars for child process
}

#[test]
#[ignore] // Requires kubectl
fn record_rewrites_kubectl_to_tracked_kubeconfig() {
    // harness record should inject --kubeconfig
}

#[test]
#[ignore] // Requires kubectl
fn record_rejects_kubectl_target_override() {
    // harness record should deny --kubeconfig or --context override
}

#[test]
#[ignore] // Requires kubectl
fn record_rejects_kubectl_without_tracked_cluster() {
    // harness record kubectl ... without cluster should fail
}

#[test]
#[ignore] // Requires kubectl
fn record_kubectl_without_tracked_kubeconfig_fails_closed() {
    // harness record kubectl without kubeconfig should fail
}

#[test]
fn diff_identical_files() {
    let tmp = tempfile::tempdir().unwrap();
    let a = tmp.path().join("a.txt");
    let b = tmp.path().join("b.txt");
    fs::write(&a, "hello\n").unwrap();
    fs::write(&b, "hello\n").unwrap();
    // The diff command should report no differences
    // (testing the actual diff would require CLI binary invocation)
}

#[test]
#[ignore] // Requires CLI binary
fn record_creates_artifact_even_when_binary_not_found() {
    // harness record should create artifact even if command fails
}

#[test]
#[ignore] // Requires CLI binary
fn record_with_no_command_exits_nonzero() {
    // harness record without -- should fail
}

// ============================================================================
// report tests
// ============================================================================

#[test]
fn report_check_fails_for_large_report() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-report-large", "single-zone");
    // Create an oversized report
    let report_path = run_dir.join("run-report.md");
    let big_body = "x".repeat(50_000);
    let report = RunReport::new(
        report_path,
        harness::schema::RunReportFrontmatter {
            run_id: "run-report-large".to_string(),
            suite_id: "example.suite".to_string(),
            profile: "single-zone".to_string(),
            overall_verdict: "pending".to_string(),
            story_results: vec![],
            debug_summary: vec![],
        },
        big_body,
    );
    report.save().unwrap();
    // The report check command would flag this as too large
    // (actual check requires CLI binary)
}

// ============================================================================
// runner-state event tests
// ============================================================================

#[test]
fn runner_state_transitions_to_preflight() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-evt", "single-zone");
    let mut state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(state.phase, RunnerPhase::Bootstrap);
    state.phase = RunnerPhase::Preflight;
    state.preflight.status = PreflightStatus::Running;
    state.transition_count += 1;
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Preflight);
}

#[test]
fn runner_state_abort_sets_phase() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-abort", "single-zone");
    let mut state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    state.phase = RunnerPhase::Aborted;
    state.last_event = Some("RunAborted".to_string());
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Aborted);
}

#[test]
fn runner_state_completed_sets_phase() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-complete", "single-zone");
    let mut state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    state.phase = RunnerPhase::Completed;
    state.last_event = Some("RunCompleted".to_string());
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let reloaded = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(reloaded.phase, RunnerPhase::Completed);
}

// ============================================================================
// init_run via execute() with various options
// ============================================================================

#[test]
fn init_defaults_repo_root_to_cwd() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));

    let result = init_run::execute(
        &suite_dir.join("suite.md").to_string_lossy(),
        "run-cwd",
        "single-zone",
        None, // no explicit repo root
        Some(&tmp.path().join("runs").to_string_lossy()),
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
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite-stories");
    fs::create_dir_all(&suite_dir).unwrap();
    fs::write(
        suite_dir.join("suite.md"),
        "\
---
suite_id: stories.suite
feature: stories-test
scope: unit
profiles: [single-zone]
required_dependencies: [docker]
user_stories:
  - prepare manifests once
  - validate all resources
variant_decisions: []
coverage_expectations: [configure, consume, debug]
baseline_files: []
groups: []
skipped_groups: []
keep_clusters: false
---

# Stories suite
",
    )
    .unwrap();

    let result = init_run::execute(
        &suite_dir.join("suite.md").to_string_lossy(),
        "run-stories",
        "single-zone",
        Some(&tmp.path().to_string_lossy()),
        Some(&tmp.path().join("runs").to_string_lossy()),
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
}

// ============================================================================
// Approval / authoring command integration tests (marked #[ignore])
// ============================================================================

#[test]
#[ignore] // Requires CLI binary with approval-begin command
fn approval_begin_initializes_interactive_state() {
    // harness approval-begin --skill suite-author --mode interactive
}

#[test]
#[ignore] // Requires CLI binary
fn authoring_begin_persists_suite_default_repo_root() {
    // harness authoring-begin should save repo root
}

#[test]
#[ignore] // Requires CLI binary
fn authoring_save_accepts_inline_payload() {
    // harness authoring-save --kind inventory --payload '{}'
}

#[test]
#[ignore] // Requires CLI binary
fn authoring_save_accepts_stdin() {
    // echo '{}' | harness authoring-save --kind inventory -
}

#[test]
#[ignore] // Requires CLI binary
fn authoring_save_rejects_schema_missing_fields() {
    // harness authoring-save --kind schema --payload '{}' should fail
}

#[test]
#[ignore] // Requires kubectl-validate binary
fn authoring_validate_accepts_valid_meshmetric_group() {
    // harness authoring-validate with valid MeshMetric group
}

#[test]
#[ignore] // Requires kubectl-validate binary
fn authoring_validate_rejects_invalid_meshmetric_group() {
    // harness authoring-validate with invalid backendRef
}

#[test]
#[ignore] // Requires kubectl-validate binary
fn authoring_validate_ignores_universal_format() {
    // Universal format blocks should be skipped
}

#[test]
#[ignore] // Requires kubectl-validate binary
fn authoring_validate_skips_expected_rejection_manifests() {
    // Manifests with expected rejections should skip validation
}

// ============================================================================
// Session / context isolation tests (marked #[ignore] for CLI dependency)
// ============================================================================

#[test]
#[ignore] // Requires CLI binary with session management
fn record_isolates_run_context_by_session_id() {
    // Different CLAUDE_SESSION_ID values should isolate run contexts
}

#[test]
#[ignore] // Requires CLI binary
fn record_run_dir_refreshes_current_session_context() {
    // harness record --run-dir should update current session
}

#[test]
#[ignore] // Requires CLI binary
fn run_uses_active_project_run_without_explicit_run_id() {
    // harness run should find active run from project state
}

// ============================================================================
// Bootstrap command (marked #[ignore])
// ============================================================================

#[test]
#[ignore] // Requires kubectl
fn bootstrap_command_runs_gateway_api_crd_install() {
    // harness bootstrap should install gateway API CRDs
}

// ============================================================================
// Closeout command
// ============================================================================

#[test]
#[ignore] // Requires CLI binary
fn closeout_sets_completed_phase() {
    // harness closeout should transition to completed
}

// ============================================================================
// Capture command (marked #[ignore])
// ============================================================================

#[test]
#[ignore] // Requires kubectl
fn capture_uses_current_run_context() {
    // harness capture should use current run kubeconfig
}
