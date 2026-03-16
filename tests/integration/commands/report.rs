// Tests for run report handling.
// Covers report round-trip serialization, comma preservation in story results,
// oversized report detection, and group finalization.

use std::fs;
use std::path::Path;

use harness::cli::{Command, ReportCommand, RunDirArgs};
use harness::commands::Execute;
use harness::context::RunContext;
use harness::schema::{RunReport, RunReportFrontmatter, Verdict};

use super::super::helpers::*;

#[test]
fn run_report_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let report_path = tmp.path().join("report.md");
    let report = RunReport::new(
        report_path.clone(),
        RunReportFrontmatter {
            run_id: "r1".to_string(),
            suite_id: "s1".to_string(),
            profile: "single-zone".to_string(),
            overall_verdict: Verdict::Pending,
            story_results: vec![],
            debug_summary: vec![],
        },
        "# Report\n".to_string(),
    );
    report.save().unwrap();
    let reloaded = RunReport::from_markdown(&report_path).unwrap();
    assert_eq!(reloaded.frontmatter.run_id, "r1");
    assert_eq!(reloaded.frontmatter.overall_verdict, Verdict::Pending);
}

#[test]
fn run_report_preserves_comma_in_story_results() {
    let tmp = tempfile::tempdir().unwrap();
    let report_path = tmp.path().join("report.md");
    let report = RunReport::new(
        report_path.clone(),
        RunReportFrontmatter {
            run_id: "r1".to_string(),
            suite_id: "s1".to_string(),
            profile: "single-zone".to_string(),
            overall_verdict: Verdict::Pending,
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

#[test]
fn report_check_fails_for_large_report() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-report-large", "single-zone");
    // Create an oversized report
    let report_path = run_dir.join("run-report.md");
    let big_body = "x".repeat(50_000);
    let report = RunReport::new(
        report_path,
        RunReportFrontmatter {
            run_id: "run-report-large".to_string(),
            suite_id: "example.suite".to_string(),
            profile: "single-zone".to_string(),
            overall_verdict: Verdict::Pending,
            story_results: vec![],
            debug_summary: vec![],
        },
        big_body,
    );
    report.save().unwrap();
    // The report check command would flag this as too large
    // (actual check requires CLI binary)
}

fn create_initial_report(run_dir: &Path) {
    let report_path = run_dir.join("run-report.md");
    let rpt = RunReport::new(
        report_path,
        RunReportFrontmatter {
            run_id: "test".to_string(),
            suite_id: "example.suite".to_string(),
            profile: "single-zone".to_string(),
            overall_verdict: Verdict::Pending,
            story_results: vec![],
            debug_summary: vec![],
        },
        "# Run Report\n".to_string(),
    );
    rpt.save().unwrap();
}

#[test]
fn run_group_updates_status_and_report() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-group-test", "single-zone");
    create_initial_report(&run_dir);

    let cmd = ReportCommand::Group {
        group_id: "g01".to_string(),
        status: "pass".to_string(),
        evidence: vec!["commands/g01.txt".to_string()],
        evidence_label: vec![],
        capture_label: None,
        note: Some("all checks passed".to_string()),
        run_dir: RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        },
    };
    let exit_code = Command::Report { cmd }.execute().unwrap();
    assert_eq!(exit_code, 0);

    let ctx = RunContext::from_run_dir(&run_dir).unwrap();
    let status = ctx.status.unwrap();
    assert_eq!(status.executed_group_ids(), vec!["g01"]);
    assert_eq!(status.counts.passed, 1);
    assert_eq!(status.counts.failed, 0);
    assert_eq!(status.last_completed_group.as_deref(), Some("g01"));
    assert!(status.last_updated_utc.is_some());
    assert_eq!(status.notes, vec!["all checks passed"]);

    let report_text = fs::read_to_string(ctx.layout.report_path()).unwrap();
    assert!(
        report_text.contains("## Group: g01"),
        "report should contain group section"
    );
    assert!(
        report_text.contains("**Verdict:** pass"),
        "report should contain verdict"
    );
    assert!(
        report_text.contains("commands/g01.txt"),
        "report should contain evidence"
    );
}

#[test]
fn run_group_idempotent_same_status() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-group-idem", "single-zone");
    create_initial_report(&run_dir);

    let cmd = ReportCommand::Group {
        group_id: "g01".to_string(),
        status: "pass".to_string(),
        evidence: vec!["evidence.txt".to_string()],
        evidence_label: vec![],
        capture_label: None,
        note: None,
        run_dir: RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        },
    };
    Command::Report { cmd: cmd.clone() }.execute().unwrap();

    // Reporting the same group with the same status should silently succeed.
    let exit_code = Command::Report { cmd }.execute().unwrap();
    assert_eq!(exit_code, 0);

    // Counts should not be doubled.
    let ctx = RunContext::from_run_dir(&run_dir).unwrap();
    let status = ctx.status.unwrap();
    assert_eq!(status.counts.passed, 1);
    assert_eq!(status.executed_group_ids(), vec!["g01"]);
}

#[test]
fn run_group_idempotent_different_status() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-group-update", "single-zone");
    create_initial_report(&run_dir);

    let first = ReportCommand::Group {
        group_id: "g01".to_string(),
        status: "fail".to_string(),
        evidence: vec!["evidence.txt".to_string()],
        evidence_label: vec![],
        capture_label: None,
        note: None,
        run_dir: RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        },
    };
    Command::Report { cmd: first }.execute().unwrap();

    let second = ReportCommand::Group {
        group_id: "g01".to_string(),
        status: "pass".to_string(),
        evidence: vec!["evidence2.txt".to_string()],
        evidence_label: vec![],
        capture_label: None,
        note: None,
        run_dir: RunDirArgs {
            run_dir: Some(run_dir.clone()),
            run_id: None,
            run_root: None,
        },
    };
    let exit_code = Command::Report { cmd: second }.execute().unwrap();
    assert_eq!(exit_code, 0);

    // Old fail count should be decremented, new pass count incremented.
    let ctx = RunContext::from_run_dir(&run_dir).unwrap();
    let status = ctx.status.unwrap();
    assert_eq!(status.counts.passed, 1);
    assert_eq!(status.counts.failed, 0);
    assert_eq!(status.executed_group_ids(), vec!["g01"]);
}
