use std::fs;
use std::path::{Path, PathBuf};

use super::*;

fn write_temp_file(dir: &Path, name: &str, content: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, content).unwrap();
    path
}

#[test]
fn test_load_report() {
    let dir = tempfile::tempdir().unwrap();
    let report_md = "\
---
run_id: r1
suite_id: s1
profile: single-zone
overall_verdict: pass
story_results: []
debug_summary: []
---

# Report
";
    let path = write_temp_file(dir.path(), "report.md", report_md);
    let report = RunReport::from_markdown(&path).unwrap();
    assert_eq!(report.frontmatter.overall_verdict, Verdict::Pass);
    assert_eq!(report.frontmatter.run_id, "r1");
    assert_eq!(report.frontmatter.suite_id, "s1");
    assert_eq!(report.frontmatter.profile, "single-zone");
    assert!(report.frontmatter.story_results.is_empty());
    assert!(report.frontmatter.debug_summary.is_empty());
}

#[test]
fn test_run_report_round_trips_story_results_with_commas() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("report.md");

    let report = RunReport::new(
        path.clone(),
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

    let reloaded = RunReport::from_markdown(&path).unwrap();
    assert_eq!(
        reloaded.frontmatter.story_results,
        report.frontmatter.story_results
    );
    assert_eq!(
        reloaded.frontmatter.debug_summary,
        report.frontmatter.debug_summary
    );

    let rendered = fs::read_to_string(&path).unwrap();
    assert!(
        rendered
            .contains("story_results:\n  - 'g02 PASS - story with commas, updates, and deletes"),
        "rendered: {rendered}"
    );
    assert!(
        rendered.contains("debug_summary:\n  - checked config, output, and cleanup"),
        "rendered: {rendered}"
    );
}
