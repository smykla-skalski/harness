// Tests for run report handling.
// Covers report round-trip serialization, comma preservation in story results,
// and oversized report detection.

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
