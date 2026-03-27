use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

use harness::errors::CliError;
use harness::run::context::{CurrentRunRecord, RunLayout};
use harness::run::workflow::{self as runner_workflow, RunnerEvent, RunnerPhase};
use harness::run::{FinishArgs, ResumeArgs, RunDirArgs, RunReport, StartArgs, Verdict};
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

fn read_current_pointer() -> CurrentRunRecord {
    let text = fs::read_to_string(current_run_context_path().unwrap()).unwrap();
    serde_json::from_str(&text).unwrap()
}

fn write_started_suite(tmp: &Path) -> PathBuf {
    let suite_dir = tmp.join("suite");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));
    suite_dir.join("suite.md")
}

fn run_start(args: StartArgs, xdg_root: &Path, session_id: &str) -> Result<i32, CliError> {
    with_run_env(xdg_root, session_id, || run_command(start_cmd(args)))
}

#[test]
fn run_start_initializes_preflights_and_sets_current_pointer() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_root = tmp.path().join("runs");
    let suite_path = write_started_suite(tmp.path());

    let result = run_start(
        StartArgs {
            suite: suite_path.to_string_lossy().to_string(),
            run_id: Some("run-start-ok".to_string()),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(run_root.to_string_lossy().to_string()),
        },
        &xdg,
        "run-start-ok",
    );
    assert_eq!(result.unwrap(), 0);

    let run_dir = run_root.join("run-start-ok");
    let layout = RunLayout::from_run_dir(&run_dir);
    assert!(layout.prepared_suite_path().exists());
    assert!(layout.preflight_artifact_path().exists());

    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(state.phase, RunnerPhase::Execution);

    with_run_env(&xdg, "run-start-ok", || {
        let pointer = read_current_pointer();
        assert_eq!(pointer.layout.run_dir(), run_dir);
        assert_eq!(pointer.profile.as_deref(), Some("single-zone"));
    });
}

#[test]
fn run_start_keeps_initialized_run_when_preflight_fails() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_root = tmp.path().join("runs");
    let suite_dir = tmp.path().join("suite");
    let _ = SuiteBuilder::new("broken.suite")
        .feature("broken")
        .scope("manual")
        .profile("single-zone")
        .require("unknown-requirement")
        .body("# Broken suite\n")
        .write_to(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));

    let result = run_start(
        StartArgs {
            suite: suite_dir.join("suite.md").to_string_lossy().to_string(),
            run_id: Some("run-start-fail".to_string()),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(run_root.to_string_lossy().to_string()),
        },
        &xdg,
        "run-start-fail",
    );
    assert!(
        result.is_err(),
        "start should fail when preflight validation fails"
    );

    let run_dir = run_root.join("run-start-fail");
    assert!(
        run_dir.is_dir(),
        "initialized run directory should be preserved"
    );
    assert!(run_dir.join("run-metadata.json").exists());
    assert!(
        !RunLayout::from_run_dir(&run_dir)
            .prepared_suite_path()
            .exists(),
        "preflight artifacts should not exist on validation failure"
    );

    with_run_env(&xdg, "run-start-fail", || {
        let pointer = read_current_pointer();
        assert_eq!(pointer.layout.run_dir(), run_dir);
    });
}

#[test]
fn run_finish_closes_out_and_checks_report() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_root = tmp.path().join("runs");
    let suite_path = write_started_suite(tmp.path());

    run_start(
        StartArgs {
            suite: suite_path.to_string_lossy().to_string(),
            run_id: Some("run-finish-ok".to_string()),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(run_root.to_string_lossy().to_string()),
        },
        &xdg,
        "run-finish-ok",
    )
    .unwrap();

    let run_dir = run_root.join("run-finish-ok");
    let mut status = read_run_status(&run_dir);
    status.counts.passed = 1;
    status.last_state_capture = Some("artifacts/state/preflight.json".to_string());
    write_run_status(&run_dir, &status);

    let result = with_run_env(&xdg, "run-finish-ok", || {
        run_command(finish_cmd(FinishArgs {
            run_dir: RunDirArgs {
                run_dir: Some(run_dir.clone()),
                run_id: None,
                run_root: None,
            },
        }))
    });
    assert_eq!(result.unwrap(), 0);

    let status = read_run_status(&run_dir);
    assert_eq!(status.overall_verdict, Verdict::Pass);
    assert!(status.completed_at.is_some());

    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(state.phase, RunnerPhase::Completed);
}

#[test]
fn run_finish_clears_current_run_pointer() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_root = tmp.path().join("runs");
    let suite_path = write_started_suite(tmp.path());

    run_start(
        StartArgs {
            suite: suite_path.to_string_lossy().to_string(),
            run_id: Some("run-finish-pointer".to_string()),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(run_root.to_string_lossy().to_string()),
        },
        &xdg,
        "run-finish-pointer",
    )
    .unwrap();

    let run_dir = run_root.join("run-finish-pointer");
    let mut status = read_run_status(&run_dir);
    status.counts.passed = 1;
    status.last_state_capture = Some("artifacts/state/preflight.json".to_string());
    write_run_status(&run_dir, &status);

    with_run_env(&xdg, "run-finish-pointer", || {
        let pointer_path = current_run_context_path().unwrap();
        assert!(
            pointer_path.exists(),
            "pointer should exist before finish"
        );

        let result = run_command(finish_cmd(FinishArgs {
            run_dir: RunDirArgs {
                run_dir: Some(run_dir.clone()),
                run_id: None,
                run_root: None,
            },
        }));
        assert_eq!(result.unwrap(), 0);

        assert!(
            !pointer_path.exists(),
            "current-run pointer should be deleted after finish"
        );
    });
}

#[test]
fn run_finish_keeps_closeout_state_when_report_check_fails() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_root = tmp.path().join("runs");
    let suite_path = write_started_suite(tmp.path());

    run_start(
        StartArgs {
            suite: suite_path.to_string_lossy().to_string(),
            run_id: Some("run-finish-report-fail".to_string()),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(run_root.to_string_lossy().to_string()),
        },
        &xdg,
        "run-finish-report-fail",
    )
    .unwrap();

    let run_dir = run_root.join("run-finish-report-fail");
    let mut status = read_run_status(&run_dir);
    status.counts.passed = 1;
    status.last_state_capture = Some("artifacts/state/preflight.json".to_string());
    write_run_status(&run_dir, &status);

    let long_report = (0..221)
        .map(|idx| format!("line {idx}"))
        .collect::<Vec<_>>()
        .join("\n");
    let report_path = run_dir.join("run-report.md");
    let mut report = RunReport::from_markdown(&report_path).unwrap();
    let _ = write!(report.body, "\n{long_report}\n");
    report.save().unwrap();

    let result = with_run_env(&xdg, "run-finish-report-fail", || {
        run_command(finish_cmd(FinishArgs {
            run_dir: RunDirArgs {
                run_dir: Some(run_dir.clone()),
                run_id: None,
                run_root: None,
            },
        }))
    });
    let error = result.expect_err("finish should fail when report compactness fails");
    assert_eq!(error.code(), "KSRCLI035");

    let status = read_run_status(&run_dir);
    assert_eq!(status.overall_verdict, Verdict::Pass);
    assert!(status.completed_at.is_some());

    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(state.phase, RunnerPhase::Completed);
}

#[test]
fn run_resume_takes_over_and_resumes_suspended_run() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_root = tmp.path().join("runs");
    let suite_path = write_started_suite(tmp.path());

    run_start(
        StartArgs {
            suite: suite_path.to_string_lossy().to_string(),
            run_id: Some("run-resume".to_string()),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(run_root.to_string_lossy().to_string()),
        },
        &xdg,
        "run-resume",
    )
    .unwrap();

    let run_dir = run_root.join("run-resume");
    let state = runner_workflow::apply_event(&run_dir, RunnerEvent::Suspend, None, None).unwrap();
    assert_eq!(state.phase, RunnerPhase::Suspended);

    with_run_env(&xdg, "run-resume", || {
        let pointer_path = current_run_context_path().unwrap();
        if let Some(parent) = pointer_path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        let other = CurrentRunRecord {
            layout: RunLayout::from_run_dir(&run_root.join("other-run")),
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
        fs::write(pointer_path, serde_json::to_string_pretty(&other).unwrap()).unwrap();

        let result = run_command(resume_cmd(ResumeArgs {
            message: Some("Recovered from stop".to_string()),
            run_dir: RunDirArgs {
                run_dir: Some(run_dir.clone()),
                run_id: None,
                run_root: None,
            },
        }));
        assert_eq!(result.unwrap(), 0);

        let pointer = read_current_pointer();
        assert_eq!(pointer.layout.run_dir(), run_dir);
    });

    let state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    assert_eq!(state.phase, RunnerPhase::Execution);
    assert_eq!(state.last_event.as_deref(), Some("ResumeRun"));
}

#[test]
fn run_resume_rejects_completed_runs_after_taking_over_pointer() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_root = tmp.path().join("runs");
    let suite_path = write_started_suite(tmp.path());

    run_start(
        StartArgs {
            suite: suite_path.to_string_lossy().to_string(),
            run_id: Some("run-resume-done".to_string()),
            profile: "single-zone".to_string(),
            repo_root: Some(tmp.path().to_string_lossy().to_string()),
            run_root: Some(run_root.to_string_lossy().to_string()),
        },
        &xdg,
        "run-resume-done",
    )
    .unwrap();

    let run_dir = run_root.join("run-resume-done");
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    write_run_status(&run_dir, &status);
    let mut state = runner_workflow::read_runner_state(&run_dir)
        .unwrap()
        .unwrap();
    state.phase = RunnerPhase::Completed;
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();

    with_run_env(&xdg, "run-resume-done", || {
        let result = run_command(resume_cmd(ResumeArgs {
            message: None,
            run_dir: RunDirArgs {
                run_dir: Some(run_dir.clone()),
                run_id: None,
                run_root: None,
            },
        }));
        let error = result.expect_err("completed runs should not resume");
        assert_eq!(error.code(), "USAGE");
        assert!(
            error
                .message()
                .contains("already has a final verdict; start a new run id instead")
        );

        let pointer = read_current_pointer();
        assert_eq!(pointer.layout.run_dir(), run_dir);
    });
}
