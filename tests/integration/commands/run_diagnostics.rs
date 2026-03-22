use std::fs;
use std::path::Path;

use harness::run::context::{CurrentRunRecord, RunLayout};
use harness::run::workflow::{
    self as runner_workflow, FailureKind, FailureState, ManifestFixDecision, RunnerPhase,
    SuiteFixState,
};
use harness::run::{
    DoctorArgs, ExecutedGroupRecord, GroupVerdict, RepairArgs, RunDirArgs, RunStatus, Verdict,
};
use harness::workspace::current_run_context_path;

use super::super::helpers::*;

fn with_run_env<T>(xdg_root: &Path, session_id: &str, body: impl FnOnce() -> T) -> T {
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_root.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some(session_id)),
        ],
        body,
    )
}

fn write_pointer(run_dir: &Path) {
    let pointer_path = current_run_context_path().unwrap();
    if let Some(parent) = pointer_path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    let pointer = CurrentRunRecord {
        layout: RunLayout::from_run_dir(run_dir),
        profile: Some("single-zone".into()),
        repo_root: None,
        suite_dir: None,
        suite_id: None,
        suite_path: None,
        cluster: None,
        keep_clusters: false,
        user_stories: vec![],
        requires: vec![],
    };
    fs::write(
        pointer_path,
        serde_json::to_string_pretty(&pointer).unwrap(),
    )
    .unwrap();
}

fn seed_execution_artifacts(run_dir: &Path) {
    let layout = RunLayout::from_run_dir(run_dir);
    fs::write(layout.prepared_suite_path(), "{}\n").unwrap();
    if let Some(parent) = layout.preflight_artifact_path().parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(layout.preflight_artifact_path(), "{}\n").unwrap();
}

fn corrupt_status_for_repair(run_dir: &Path, capture_path: &Path) {
    fs::create_dir_all(capture_path.parent().unwrap()).unwrap();
    fs::write(capture_path, "{}\n").unwrap();

    let mut status = read_run_status(run_dir);
    status.run_id = "wrong-run".into();
    status.suite_id = "wrong-suite".into();
    status.profile = "wrong-profile".into();
    status.counts.passed = 99;
    status.last_completed_group = Some("wrong".into());
    status.last_state_capture = Some("artifacts/state/wrong.json".into());
    status.last_updated_utc = Some("1999-01-01T00:00:00Z".into());
    status.executed_groups = vec![ExecutedGroupRecord {
        group_id: "g01".into(),
        verdict: GroupVerdict::Pass,
        completed_at: "2026-03-22T10:00:00Z".into(),
        state_capture_at_report: Some("artifacts/state/g01.json".into()),
    }];
    write_run_status(run_dir, &status);
}

fn assert_repaired_status_identity(repaired: &RunStatus) {
    assert_eq!(repaired.run_id, "run-repair-status");
    assert_eq!(repaired.profile, "single-zone");
}

fn assert_repaired_status_tracking(repaired: &RunStatus) {
    assert_eq!(repaired.counts.passed, 1);
    assert_eq!(repaired.counts.failed, 0);
    assert_eq!(repaired.last_completed_group.as_deref(), Some("g01"));
    assert_eq!(
        repaired.last_state_capture.as_deref(),
        Some("artifacts/state/g01.json")
    );
    assert_eq!(
        repaired.last_updated_utc.as_deref(),
        Some("2026-03-22T10:00:00Z")
    );
}

fn assert_repaired_status(run_dir: &Path) {
    let repaired = read_run_status(run_dir);
    assert_repaired_status_identity(&repaired);
    assert_repaired_status_tracking(&repaired);
}

fn assert_rebuilt_pointer(run_dir: &Path) {
    let pointer_text = fs::read_to_string(current_run_context_path().unwrap()).unwrap();
    let pointer: CurrentRunRecord = serde_json::from_str(&pointer_text).unwrap();
    assert_eq!(pointer.layout.run_dir(), run_dir);
}

#[test]
fn run_doctor_and_repair_clear_stale_pointer_without_explicit_target() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let missing_run = tmp.path().join("runs").join("missing-run");

    with_run_env(&xdg, "run-doctor-stale", || {
        write_pointer(&missing_run);

        let doctor_result = run_command(doctor_cmd(DoctorArgs {
            json: false,
            run_dir: RunDirArgs {
                run_dir: None,
                run_id: None,
                run_root: None,
            },
        }))
        .unwrap();
        assert_eq!(doctor_result, 2);

        let repair_result = run_command(repair_cmd(RepairArgs {
            json: false,
            run_dir: RunDirArgs {
                run_dir: None,
                run_id: None,
                run_root: None,
            },
        }))
        .unwrap();
        assert_eq!(repair_result, 0);
        assert!(!current_run_context_path().unwrap().exists());
    });
}

#[test]
fn run_repair_rewrites_deterministic_status_fields_and_rebuilds_pointer() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_dir = init_run(tmp.path(), "run-repair-status", "single-zone");
    let capture_path = run_dir.join("artifacts").join("state").join("g01.json");
    corrupt_status_for_repair(&run_dir, &capture_path);

    with_run_env(&xdg, "run-repair-status", || {
        let exit = run_command(repair_cmd(RepairArgs {
            json: false,
            run_dir: RunDirArgs {
                run_dir: Some(run_dir.clone()),
                run_id: None,
                run_root: None,
            },
        }))
        .unwrap();
        assert_eq!(exit, 0);
        assert_rebuilt_pointer(&run_dir);
    });

    assert_repaired_status(&run_dir);
}

#[test]
fn run_repair_completes_workflow_when_final_verdict_and_report_exist() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_dir = init_run(tmp.path(), "run-repair-complete", "single-zone");
    let layout = RunLayout::from_run_dir(&run_dir);
    seed_execution_artifacts(&run_dir);
    fs::create_dir_all(layout.commands_dir()).unwrap();
    fs::write(layout.command_log_path(), "# commands\n").unwrap();
    fs::write(layout.report_path(), "# report\n").unwrap();

    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    status.completed_at = Some("2026-03-22T12:00:00Z".into());
    write_run_status(&run_dir, &status);

    let mut workflow = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    workflow.phase = RunnerPhase::Execution;
    workflow.failure = Some(FailureState {
        kind: FailureKind::Manifest,
        suite_target: Some("groups/g01.md".into()),
        message: Some("stale".into()),
    });
    workflow.suite_fix = Some(SuiteFixState {
        approved_paths: vec!["groups/g01.md".into()],
        suite_written: true,
        amendments_written: true,
        decision: ManifestFixDecision::SuiteAndRun,
    });
    runner_workflow::write_runner_state(&run_dir, &workflow).unwrap();

    with_run_env(&xdg, "run-repair-complete", || {
        let exit = run_command(repair_cmd(RepairArgs {
            json: false,
            run_dir: RunDirArgs {
                run_dir: Some(run_dir.clone()),
                run_id: None,
                run_root: None,
            },
        }))
        .unwrap();
        assert_eq!(exit, 0);
    });

    let workflow = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(workflow.phase, RunnerPhase::Completed);
    assert!(workflow.failure.is_none());
    assert!(workflow.suite_fix.is_none());
    assert_eq!(workflow.last_event.as_deref(), Some("RunRepairCompleted"));
}

#[test]
fn run_repair_does_not_force_completed_without_report() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_dir = init_run(tmp.path(), "run-repair-no-report", "single-zone");
    seed_execution_artifacts(&run_dir);

    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    status.completed_at = Some("2026-03-22T12:00:00Z".into());
    write_run_status(&run_dir, &status);

    let mut workflow = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    workflow.phase = RunnerPhase::Execution;
    runner_workflow::write_runner_state(&run_dir, &workflow).unwrap();

    with_run_env(&xdg, "run-repair-no-report", || {
        let exit = run_command(repair_cmd(RepairArgs {
            json: false,
            run_dir: RunDirArgs {
                run_dir: Some(run_dir.clone()),
                run_id: None,
                run_root: None,
            },
        }))
        .unwrap();
        assert_eq!(exit, 2);
    });

    let workflow = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(workflow.phase, RunnerPhase::Execution);
}
