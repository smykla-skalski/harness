mod parsers;

mod frontmatter;
mod run;
mod suite;

pub use frontmatter::{HelmValueEntry, SuiteFrontmatter};
pub use run::{
    ExecutedGroupChange, ExecutedGroupRecord, GroupVerdict, RunCounts, RunReport,
    RunReportFrontmatter, RunStatus, Verdict,
};
pub use suite::{GroupFrontmatter, GroupSpec, SuiteSpec};

#[cfg(test)]
mod tests {
    #![allow(clippy::cognitive_complexity)]

    use super::*;
    use std::fs;
    use std::io::Write as _;
    use std::path::{Path, PathBuf};

    use harness_testkit::{GroupBuilder, SuiteBuilder, default_suite};

    fn write_temp_file(dir: &Path, name: &str, content: &str) -> PathBuf {
        let path = dir.join(name);
        let mut f = fs::File::create(&path).unwrap();
        f.write_all(content.as_bytes()).unwrap();
        path
    }

    #[test]
    fn test_load_suite() {
        let dir = tempfile::tempdir().unwrap();
        let path = default_suite().write_to(&dir.path().join("suite.md"));
        let suite = SuiteSpec::from_markdown(&path).unwrap();
        assert_eq!(suite.frontmatter.suite_id, "example.suite");
        assert_eq!(suite.frontmatter.groups, vec!["groups/g01.md"]);
        assert!(!suite.frontmatter.keep_clusters);
        assert_eq!(suite.frontmatter.feature, "example");
        assert_eq!(suite.frontmatter.scope.as_deref(), Some("unit"));
        assert_eq!(suite.frontmatter.profiles, vec!["single-zone"]);
        assert!(suite.frontmatter.required_dependencies.is_empty());
        assert!(suite.frontmatter.user_stories.is_empty());
        assert!(suite.frontmatter.variant_decisions.is_empty());
        assert_eq!(
            suite.frontmatter.coverage_expectations,
            vec!["configure", "consume", "debug"]
        );
        assert!(suite.frontmatter.baseline_files.is_empty());
        assert!(suite.frontmatter.skipped_groups.is_empty());
    }

    #[test]
    fn test_load_suite_missing_fields() {
        let dir = tempfile::tempdir().unwrap();
        // Minimal suite with only suite_id - missing feature, scope, keep_clusters
        let path = write_temp_file(dir.path(), "suite.md", "---\nsuite_id: x\n---\n\nBody.\n");
        let err = SuiteSpec::from_markdown(&path).unwrap_err();
        assert!(
            err.message().contains("missing required fields"),
            "expected 'missing required fields' in: {}",
            err.message()
        );
    }

    #[test]
    fn test_load_group_requires_sections() {
        let dir = tempfile::tempdir().unwrap();
        // Group with only Configure section - missing Consume and Debug
        let path = GroupBuilder::new("g01")
            .story("test")
            .capability("test")
            .profile("single-zone")
            .success_criteria("done")
            .debug_check("logs")
            .variant_source("code")
            .configure_section("Do config.")
            .consume_section("")
            .debug_section("")
            .write_to(&dir.path().join("g01.md"));
        // We need the raw format without ## Consume and ## Debug sections,
        // so use write_temp_file for this negative test case.
        let raw = "\
---
group_id: g01
story: test
capability: test
profiles: [single-zone]
preconditions: []
success_criteria: [done]
debug_checks: [logs]
artifacts: []
variant_source: code
helm_values: {}
restart_namespaces: []
---

## Configure

Do config.
";
        fs::write(&path, raw).unwrap();
        let err = GroupSpec::from_markdown(&path).unwrap_err();
        assert!(
            err.message().contains("missing sections"),
            "expected 'missing sections' in: {}",
            err.message()
        );
    }

    #[test]
    fn test_load_group_valid() {
        let dir = tempfile::tempdir().unwrap();
        let path = GroupBuilder::new("g01")
            .story("test")
            .capability("test")
            .profile("single-zone")
            .success_criteria("done")
            .debug_check("logs")
            .variant_source("code")
            .helm_value("dataPlane.features.unifiedResourceNaming", "true")
            .restart_namespace("kuma-demo")
            .configure_section("Do config.")
            .consume_section("Do consume.")
            .debug_section("Do debug.")
            .write_to(&dir.path().join("g01.md"));
        let group = GroupSpec::from_markdown(&path).unwrap();
        assert_eq!(group.frontmatter.group_id, "g01");
        assert_eq!(
            group
                .frontmatter
                .helm_values
                .get("dataPlane.features.unifiedResourceNaming"),
            Some(&serde_json::Value::Bool(true))
        );
        assert_eq!(group.frontmatter.restart_namespaces, vec!["kuma-demo"]);
        assert!(group.body.contains("## Configure"));
    }

    #[test]
    fn test_load_group_with_expected_rejection_orders() {
        let dir = tempfile::tempdir().unwrap();
        let path = GroupBuilder::new("g02")
            .story("validation rejects")
            .capability("validation")
            .profile("single-zone")
            .success_criteria("rejected")
            .variant_source("code")
            .expected_rejection_orders(&[2, 4])
            .configure_section("Do config.")
            .consume_section("Do consume.")
            .debug_section("Do debug.")
            .write_to(&dir.path().join("g02.md"));
        let group = GroupSpec::from_markdown(&path).unwrap();
        assert_eq!(group.frontmatter.expected_rejection_orders, vec![2, 4]);
    }

    #[test]
    fn test_load_documented_example_suite() {
        let path = Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../kumahq/kuma/.claude/worktrees/kuma-claude-plugins/.claude/skills/suite/new/examples/example-motb-core-suite.md"
        ));
        // Skip if the example file doesn't exist (CI environments)
        if !path.exists() {
            // Try the absolute path from the Python test
            let alt = Path::new(
                "/Users/bart.smykla@konghq.com/Projects/github.com/kumahq/kuma/.claude/worktrees/kuma-claude-plugins/.claude/skills/suite/new/examples/example-motb-core-suite.md",
            );
            if !alt.exists() {
                eprintln!("Skipping: example suite file not found");
                return;
            }
            let suite = SuiteSpec::from_markdown(alt).unwrap();
            assert_eq!(suite.frontmatter.suite_id, "motb-core");
            assert_eq!(
                suite.frontmatter.groups,
                vec!["groups/g01-crud.md", "groups/g02-validation.md"]
            );
            return;
        }
        let suite = SuiteSpec::from_markdown(path).unwrap();
        assert_eq!(suite.frontmatter.suite_id, "motb-core");
        assert_eq!(
            suite.frontmatter.groups,
            vec!["groups/g01-crud.md", "groups/g02-validation.md"]
        );
    }

    #[test]
    fn test_load_documented_example_group() {
        let alt = Path::new(
            "/Users/bart.smykla@konghq.com/Projects/github.com/kumahq/kuma/.claude/worktrees/kuma-claude-plugins/.claude/skills/suite/new/examples/example-motb-core-group.md",
        );
        if !alt.exists() {
            eprintln!("Skipping: example group file not found");
            return;
        }
        let group = GroupSpec::from_markdown(alt).unwrap();
        assert_eq!(group.frontmatter.group_id, "g01");
        assert_eq!(
            group
                .frontmatter
                .helm_values
                .get("dataPlane.features.unifiedResourceNaming"),
            Some(&serde_json::Value::Bool(true))
        );
        assert_eq!(group.frontmatter.restart_namespaces, vec!["kuma-demo"]);
        assert!(group.body.contains("## Debug"));
    }

    #[test]
    fn test_load_suite_rejects_legacy_prose_contract() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_temp_file(
            dir.path(),
            "suite.md",
            "# Legacy suite\n\n\
             - suite id: example.suite\n\
             - session_id: old-contract\n\
             - target environments: single-zone\n",
        );
        let err = SuiteSpec::from_markdown(&path).unwrap_err();
        assert!(
            err.message().contains("missing YAML frontmatter"),
            "expected 'missing YAML frontmatter' in: {}",
            err.message()
        );
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
                    "g02 PASS - story with commas, updates, and deletes | evidence: `commands/g02.txt`".to_string(),
                ],
                debug_summary: vec![
                    "checked config, output, and cleanup".to_string(),
                ],
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
            rendered.contains(
                "story_results:\n  - 'g02 PASS - story with commas, updates, and deletes"
            ),
            "rendered: {rendered}"
        );
        assert!(
            rendered.contains("debug_summary:\n  - checked config, output, and cleanup"),
            "rendered: {rendered}"
        );
    }

    #[test]
    fn test_load_run_status() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run-status.json");
        let json = serde_json::json!({
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
        fs::write(&path, serde_json::to_string_pretty(&json).unwrap()).unwrap();

        let status = RunStatus::load(&path).unwrap();
        assert_eq!(status.last_state_capture, None);
        assert_eq!(status.counts, RunCounts::default());
        assert_eq!(status.last_completed_group, None);
        assert_eq!(status.next_planned_group, None);
    }

    #[test]
    fn test_load_run_status_accepts_structured_group_entries() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("run-status.json");
        let json = serde_json::json!({
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
        fs::write(&path, serde_json::to_string_pretty(&json).unwrap()).unwrap();

        let status = RunStatus::load(&path).unwrap();
        assert_eq!(
            status.counts,
            RunCounts {
                passed: 1,
                failed: 0,
                skipped: 0
            }
        );
        assert_eq!(status.executed_group_ids(), vec!["g02"]);
        assert_eq!(status.last_completed_group.as_deref(), Some("g02"));
        assert_eq!(status.next_planned_group.as_deref(), Some("g03"));
    }

    #[test]
    fn test_load_suite_rejects_broken_yaml() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_temp_file(dir.path(), "suite.md", "---\n: [\n---\n\nBody.\n");
        let err = SuiteSpec::from_markdown(&path).unwrap_err();
        assert!(
            err.message().contains("frontmatter YAML"),
            "expected YAML parse error, got: {}",
            err.message()
        );
    }

    #[test]
    fn test_suite_dir() {
        let dir = tempfile::tempdir().unwrap();
        let path = SuiteBuilder::new("example.suite")
            .feature("example")
            .scope("unit")
            .keep_clusters(false)
            .body("# Test\n")
            .write_to(&dir.path().join("suite.md"));
        let suite = SuiteSpec::from_markdown(&path).unwrap();
        assert_eq!(suite.suite_dir(), dir.path());
    }
}
