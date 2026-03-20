mod frontmatter;
mod suite;

pub use frontmatter::{HelmValueEntry, SuiteFrontmatter};
pub use suite::{GroupFrontmatter, GroupSection, GroupSpec, SuiteSpec};

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};

    use harness_testkit::{GroupBuilder, SuiteBuilder, default_suite};

    use super::*;

    fn write_temp_file(dir: &Path, name: &str, content: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, content).unwrap();
        path
    }

    fn assert_default_suite_identity(suite: &SuiteSpec) {
        assert_eq!(suite.frontmatter.suite_id, "example.suite");
        assert_eq!(suite.frontmatter.groups, vec!["groups/g01.md"]);
        assert!(!suite.frontmatter.keep_clusters);
        assert_eq!(suite.frontmatter.feature, "example");
    }

    fn assert_default_suite_profiles(suite: &SuiteSpec) {
        assert_eq!(suite.frontmatter.scope.as_deref(), Some("unit"));
        assert_eq!(suite.frontmatter.profiles, vec!["single-zone"]);
        assert!(suite.frontmatter.requires.is_empty());
        assert!(suite.frontmatter.user_stories.is_empty());
        assert!(suite.frontmatter.variant_decisions.is_empty());
    }

    fn assert_default_suite_coverage(suite: &SuiteSpec) {
        assert_eq!(
            suite.frontmatter.coverage_expectations,
            vec!["configure", "consume", "debug"]
        );
        assert!(suite.frontmatter.baseline_files.is_empty());
        assert!(suite.frontmatter.skipped_groups.is_empty());
    }

    #[test]
    fn test_load_suite() {
        let dir = tempfile::tempdir().unwrap();
        let path = default_suite().write_to(&dir.path().join("suite.md"));
        let suite = SuiteSpec::from_markdown(&path).unwrap();
        assert_default_suite_identity(&suite);
        assert_default_suite_profiles(&suite);
        assert_default_suite_coverage(&suite);
    }

    #[test]
    fn test_load_suite_missing_fields() {
        let dir = tempfile::tempdir().unwrap();
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
        if !path.exists() {
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
    fn test_load_suite_supports_required_dependencies_alias() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_temp_file(
            dir.path(),
            "suite.md",
            "---\n\
suite_id: alias.suite\n\
feature: example\n\
scope: unit\n\
keep_clusters: false\n\
required_dependencies:\n\
  - demo-workload\n\
groups:\n\
  - groups/g01.md\n\
---\n\nBody.\n",
        );
        let suite = SuiteSpec::from_markdown(&path).unwrap();
        assert_eq!(suite.frontmatter.requires, vec!["demo-workload"]);
    }

    #[test]
    fn test_load_suite_supports_structured_baseline_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_temp_file(
            dir.path(),
            "suite.md",
            "---\n\
suite_id: baseline.suite\n\
feature: example\n\
scope: unit\n\
keep_clusters: false\n\
baseline_files:\n\
  - path: baseline/namespace.yaml\n\
    clusters: all\n\
groups:\n\
  - groups/g01.md\n\
---\n\nBody.\n",
        );
        let suite = SuiteSpec::from_markdown(&path).unwrap();
        assert_eq!(
            suite.frontmatter.baseline_files,
            vec!["baseline/namespace.yaml"]
        );
    }

    #[test]
    fn test_load_suite_supports_structured_skipped_groups() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_temp_file(
            dir.path(),
            "suite.md",
            "---\n\
suite_id: skipped.suite\n\
feature: example\n\
scope: unit\n\
keep_clusters: false\n\
skipped_groups:\n\
  - g03-runtime: omitted in the example\n\
groups:\n\
  - groups/g01.md\n\
---\n\nBody.\n",
        );
        let suite = SuiteSpec::from_markdown(&path).unwrap();
        assert_eq!(
            suite.frontmatter.skipped_groups,
            vec!["g03-runtime: omitted in the example"]
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
    fn test_load_suite_rejects_broken_yaml() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_temp_file(dir.path(), "suite.md", "---\n: [\n---\n\nBody.\n");
        let err = SuiteSpec::from_markdown(&path).unwrap_err();
        assert!(
            err.message().contains("suite frontmatter"),
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
