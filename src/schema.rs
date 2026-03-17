use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind, cow};
use crate::io;
use crate::rules;

// ---------------------------------------------------------------------------
// Internal helpers for frontmatter parsing.
// ---------------------------------------------------------------------------

/// Split frontmatter from body using the shared `io::extract_raw_frontmatter`
/// helper. Returns parsed YAML mapping and body text.
fn split_frontmatter(text: &str) -> Result<(serde_yml::Mapping, String), CliError> {
    let (yaml_text, body) = io::extract_raw_frontmatter(text)?;
    let map: serde_yml::Mapping = serde_yml::from_str(&yaml_text)
        .map_err(|e| CliErrorKind::workflow_parse(cow!("frontmatter YAML: {e}")))?;
    Ok((map, body))
}

/// Extract a string field from a YAML mapping, returning None if missing or not a string.
fn yaml_str(map: &serde_yml::Mapping, key: &str) -> Option<String> {
    map.get(serde_yml::Value::String(key.to_string()))
        .and_then(serde_yml::Value::as_str)
        .map(String::from)
}

/// Extract a bool field, defaulting to false.
fn yaml_bool(map: &serde_yml::Mapping, key: &str) -> bool {
    map.get(serde_yml::Value::String(key.to_string()))
        .and_then(serde_yml::Value::as_bool)
        .unwrap_or(false)
}

/// Extract a list-of-strings field, defaulting to empty vec.
fn yaml_str_list(map: &serde_yml::Mapping, key: &str) -> Vec<String> {
    map.get(serde_yml::Value::String(key.to_string()))
        .and_then(serde_yml::Value::as_sequence)
        .map(|seq| {
            seq.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

/// Extract a list-of-integers field, defaulting to empty vec.
fn yaml_int_list(map: &serde_yml::Mapping, key: &str) -> Vec<i64> {
    map.get(serde_yml::Value::String(key.to_string()))
        .and_then(serde_yml::Value::as_sequence)
        .map(|seq| seq.iter().filter_map(serde_yml::Value::as_i64).collect())
        .unwrap_or_default()
}

/// Extract `helm_values` as a `HashMap<String, serde_json::Value>`.
fn yaml_helm_values(map: &serde_yml::Mapping, key: &str) -> HashMap<String, serde_json::Value> {
    let Some(val) = map.get(serde_yml::Value::String(key.to_string())) else {
        return HashMap::new();
    };
    let Some(mapping) = val.as_mapping() else {
        return HashMap::new();
    };
    mapping
        .iter()
        .filter_map(|(k, v)| {
            let key_str = k.as_str()?;
            let json_val = io::yaml_to_json(v);
            Some((key_str.to_string(), json_val))
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A single helm value entry (key=value).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HelmValueEntry {
    pub key: String,
    pub value: serde_json::Value,
}

/// Suite frontmatter payload deserialized from suite.md YAML header.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SuiteFrontmatter {
    pub suite_id: String,
    pub feature: String,
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub profiles: Vec<String>,
    #[serde(default)]
    pub required_dependencies: Vec<String>,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub variant_decisions: Vec<String>,
    #[serde(default)]
    pub coverage_expectations: Vec<String>,
    #[serde(default)]
    pub baseline_files: Vec<String>,
    #[serde(default)]
    pub groups: Vec<String>,
    #[serde(default)]
    pub skipped_groups: Vec<String>,
    #[serde(default)]
    pub keep_clusters: bool,
}

/// A loaded suite specification with its source path.
#[derive(Debug, Clone)]
pub struct SuiteSpec {
    pub frontmatter: SuiteFrontmatter,
    pub path: PathBuf,
}

impl SuiteSpec {
    /// Load a suite spec from a markdown file.
    ///
    /// # Errors
    /// Returns `CliError` if the file is missing or frontmatter is invalid.
    pub fn from_markdown(path: &Path) -> Result<Self, CliError> {
        let text = io::read_text(path)?;
        let (yaml, _body) = split_frontmatter(&text)?;
        let map = &yaml;

        let suite_id = yaml_str(map, "suite_id");
        let feature = yaml_str(map, "feature");

        // Require both suite_id and feature
        let mut missing = Vec::new();
        if suite_id.is_none() {
            missing.push("suite_id");
        }
        if feature.is_none() {
            missing.push("feature");
        }
        if yaml_str(map, "scope").is_none()
            && !map.contains_key(serde_yml::Value::String("scope".to_string()))
        {
            missing.push("scope");
        }
        if !map.contains_key(serde_yml::Value::String("keep_clusters".to_string())) {
            missing.push("keep_clusters");
        }
        if !missing.is_empty() {
            return Err(
                CliErrorKind::missing_fields("suite frontmatter", missing.join(", ")).into(),
            );
        }

        let frontmatter = SuiteFrontmatter {
            suite_id: suite_id.unwrap_or_default(),
            feature: feature.unwrap_or_default(),
            scope: yaml_str(map, "scope"),
            profiles: yaml_str_list(map, "profiles"),
            required_dependencies: yaml_str_list(map, "required_dependencies"),
            user_stories: yaml_str_list(map, "user_stories"),
            variant_decisions: yaml_str_list(map, "variant_decisions"),
            coverage_expectations: yaml_str_list(map, "coverage_expectations"),
            baseline_files: yaml_str_list(map, "baseline_files"),
            groups: yaml_str_list(map, "groups"),
            skipped_groups: yaml_str_list(map, "skipped_groups"),
            keep_clusters: yaml_bool(map, "keep_clusters"),
        };

        Ok(Self {
            frontmatter,
            path: path.to_path_buf(),
        })
    }

    #[must_use]
    pub fn suite_dir(&self) -> &Path {
        self.path.parent().unwrap_or(Path::new("."))
    }
}

/// Group frontmatter payload from a group markdown file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GroupFrontmatter {
    pub group_id: String,
    pub story: String,
    #[serde(default)]
    pub capability: Option<String>,
    #[serde(default)]
    pub profiles: Vec<String>,
    #[serde(default)]
    pub preconditions: Vec<String>,
    #[serde(default)]
    pub success_criteria: Vec<String>,
    #[serde(default)]
    pub debug_checks: Vec<String>,
    #[serde(default)]
    pub artifacts: Vec<String>,
    #[serde(default)]
    pub variant_source: Option<String>,
    #[serde(default)]
    pub helm_values: HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
    #[serde(default)]
    pub expected_rejection_orders: Vec<i64>,
}

/// A loaded group specification with path and body.
#[derive(Debug, Clone)]
pub struct GroupSpec {
    pub frontmatter: GroupFrontmatter,
    pub path: PathBuf,
    pub body: String,
}

impl GroupSpec {
    /// Load a group spec from a markdown file.
    ///
    /// # Errors
    /// Returns `CliError` if the file is missing, frontmatter is invalid,
    /// or required sections are missing.
    pub fn from_markdown(path: &Path) -> Result<Self, CliError> {
        let text = io::read_text(path)?;
        let (yaml, body) = split_frontmatter(&text)?;
        let map = &yaml;

        // Check required sections in body
        let missing = rules::shared::GroupSection::missing_from(&body);
        if !missing.is_empty() {
            let labels: Vec<&str> = missing.iter().map(|s| s.as_str()).collect();
            return Err(CliErrorKind::missing_sections("group body", labels.join(", ")).into());
        }

        let frontmatter = GroupFrontmatter {
            group_id: yaml_str(map, "group_id").unwrap_or_default(),
            story: yaml_str(map, "story").unwrap_or_default(),
            capability: yaml_str(map, "capability"),
            profiles: yaml_str_list(map, "profiles"),
            preconditions: yaml_str_list(map, "preconditions"),
            success_criteria: yaml_str_list(map, "success_criteria"),
            debug_checks: yaml_str_list(map, "debug_checks"),
            artifacts: yaml_str_list(map, "artifacts"),
            variant_source: yaml_str(map, "variant_source"),
            helm_values: yaml_helm_values(map, "helm_values"),
            restart_namespaces: yaml_str_list(map, "restart_namespaces"),
            expected_rejection_orders: yaml_int_list(map, "expected_rejection_orders"),
        };

        Ok(Self {
            frontmatter,
            path: path.to_path_buf(),
            body,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum Verdict {
    Pending,
    Pass,
    Fail,
    Aborted,
}

impl Verdict {
    #[must_use]
    pub fn is_finalized(self) -> bool {
        matches!(self, Self::Pass | Self::Fail | Self::Aborted)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GroupVerdict {
    Pass,
    Fail,
    Skip,
}

impl fmt::Display for GroupVerdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pass => f.write_str("pass"),
            Self::Fail => f.write_str("fail"),
            Self::Skip => f.write_str("skip"),
        }
    }
}

impl FromStr for GroupVerdict {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "pass" => Ok(Self::Pass),
            "fail" => Ok(Self::Fail),
            "skip" => Ok(Self::Skip),
            _ => Err(()),
        }
    }
}

impl fmt::Display for Verdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pending => f.write_str("pending"),
            Self::Pass => f.write_str("pass"),
            Self::Fail => f.write_str("fail"),
            Self::Aborted => f.write_str("aborted"),
        }
    }
}

/// Run report frontmatter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunReportFrontmatter {
    pub run_id: String,
    pub suite_id: String,
    pub profile: String,
    pub overall_verdict: Verdict,
    #[serde(default)]
    pub story_results: Vec<String>,
    #[serde(default)]
    pub debug_summary: Vec<String>,
}

/// A loaded run report.
#[derive(Debug, Clone)]
pub struct RunReport {
    pub frontmatter: RunReportFrontmatter,
    pub path: PathBuf,
    pub body: String,
}

impl RunReport {
    /// Load from a markdown file.
    ///
    /// # Errors
    /// Returns `CliError` on failure.
    pub fn from_markdown(path: &Path) -> Result<Self, CliError> {
        let text = io::read_text(path)?;
        let (yaml, body) = split_frontmatter(&text)?;
        let map = &yaml;

        // debug_summary can be a list of strings or an empty list []
        // In the Python test, debug_summary: [] is passed but it parses as empty tuple
        let debug_summary = yaml_str_list(map, "debug_summary");

        let frontmatter = RunReportFrontmatter {
            run_id: yaml_str(map, "run_id").unwrap_or_default(),
            suite_id: yaml_str(map, "suite_id").unwrap_or_default(),
            profile: yaml_str(map, "profile").unwrap_or_default(),
            overall_verdict: yaml_str(map, "overall_verdict")
                .and_then(|s| serde_json::from_value(serde_json::Value::String(s)).ok())
                .unwrap_or(Verdict::Pending),
            story_results: yaml_str_list(map, "story_results"),
            debug_summary,
        };

        Ok(Self {
            frontmatter,
            path: path.to_path_buf(),
            body,
        })
    }

    /// Create a new report that can be saved.
    #[must_use]
    pub fn new(path: PathBuf, frontmatter: RunReportFrontmatter, body: String) -> Self {
        Self {
            frontmatter,
            path,
            body,
        }
    }

    /// Render the report as markdown text.
    #[must_use]
    pub fn to_markdown(&self) -> String {
        use std::fmt::Write;
        let fm = &self.frontmatter;
        let mut out = String::new();
        writeln!(out, "---").unwrap();
        writeln!(out, "run_id: {}", fm.run_id).unwrap();
        writeln!(out, "suite_id: {}", fm.suite_id).unwrap();
        writeln!(out, "profile: {}", fm.profile).unwrap();
        writeln!(out, "overall_verdict: {}", fm.overall_verdict).unwrap();
        render_frontmatter_list_into(&mut out, "story_results", &fm.story_results);
        render_frontmatter_list_into(&mut out, "debug_summary", &fm.debug_summary);
        writeln!(out, "---").unwrap();
        writeln!(out).unwrap();
        writeln!(out, "{}", self.body.trim_end()).unwrap();
        out
    }

    /// Save the report to disk.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn save(&self) -> Result<(), CliError> {
        io::write_text(&self.path, &self.to_markdown())
    }
}

/// Write a YAML list field in block style (one `- item` per line) into a
/// String buffer. Values that contain YAML-special characters are
/// single-quoted so that `serde_yml` can parse them back without ambiguity.
fn render_frontmatter_list_into(out: &mut String, key: &str, values: &[String]) {
    use std::fmt::Write;
    if values.is_empty() {
        writeln!(out, "{key}: []").unwrap();
        return;
    }
    writeln!(out, "{key}:").unwrap();
    for v in values {
        writeln!(out, "  - {}", yaml_quote_if_needed(v)).unwrap();
    }
}

/// Single-quote a string value if it contains characters that are special in
/// YAML (colon-space, hash, backtick, brackets, braces, ampersand, asterisk,
/// exclamation, percent). Inside single quotes, only `'` needs escaping (as
/// `''`).
fn yaml_quote_if_needed(s: &str) -> Cow<'_, str> {
    const SPECIAL: &[char] = &[':', '#', '`', '[', ']', '{', '}', '&', '*', '!', '%'];
    if s.contains(SPECIAL) {
        let escaped = s.replace('\'', "''");
        Cow::Owned(format!("'{escaped}'"))
    } else {
        Cow::Borrowed(s)
    }
}

/// Counts of passed/failed/skipped groups in a run.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RunCounts {
    #[serde(default)]
    pub passed: u32,
    #[serde(default)]
    pub failed: u32,
    #[serde(default)]
    pub skipped: u32,
}

impl RunCounts {
    pub fn increment(&mut self, verdict: GroupVerdict) {
        match verdict {
            GroupVerdict::Pass => self.passed += 1,
            GroupVerdict::Fail => self.failed += 1,
            GroupVerdict::Skip => self.skipped += 1,
        }
    }

    pub fn decrement(&mut self, verdict: GroupVerdict) {
        match verdict {
            GroupVerdict::Pass => self.passed = self.passed.saturating_sub(1),
            GroupVerdict::Fail => self.failed = self.failed.saturating_sub(1),
            GroupVerdict::Skip => self.skipped = self.skipped.saturating_sub(1),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutedGroupRecord {
    pub group_id: String,
    pub verdict: GroupVerdict,
    pub completed_at: String,
    #[serde(default)]
    pub state_capture_at_report: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutedGroupChange {
    Noop,
    Inserted,
    Updated(GroupVerdict),
}

/// Run status tracked in run-status.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunStatus {
    pub run_id: String,
    pub suite_id: String,
    pub profile: String,
    pub started_at: String,
    pub overall_verdict: Verdict,
    #[serde(default)]
    pub completed_at: Option<String>,
    #[serde(default)]
    pub counts: RunCounts,
    #[serde(default)]
    pub executed_groups: Vec<ExecutedGroupRecord>,
    #[serde(default)]
    pub skipped_groups: Vec<String>,
    #[serde(default)]
    pub last_completed_group: Option<String>,
    #[serde(default)]
    pub last_state_capture: Option<String>,
    #[serde(default)]
    pub last_updated_utc: Option<String>,
    #[serde(default)]
    pub next_planned_group: Option<String>,
    #[serde(default)]
    pub notes: Vec<String>,
}

impl RunStatus {
    /// Load run status from a JSON file.
    ///
    /// # Errors
    /// Returns `CliError` if the file is missing or contains invalid JSON.
    pub fn load(path: &Path) -> Result<Self, CliError> {
        io::read_json_typed(path)
            .map_err(|e| -> CliError { CliErrorKind::json_parse(e.to_string()).into() })
    }

    /// Save run status to a JSON file.
    ///
    /// # Errors
    /// Returns `CliError` on IO or serialization failure.
    pub fn save(&self, path: &Path) -> Result<(), CliError> {
        io::write_json_pretty(path, self)
    }

    #[must_use]
    pub fn executed_group_ids(&self) -> Vec<&str> {
        self.executed_groups
            .iter()
            .map(|group| group.group_id.as_str())
            .collect()
    }

    #[must_use]
    pub fn group_verdict(&self, group_id: &str) -> Option<GroupVerdict> {
        self.executed_groups
            .iter()
            .find(|group| group.group_id == group_id)
            .map(|group| group.verdict)
    }

    pub fn record_group_result(
        &mut self,
        group_id: &str,
        verdict: GroupVerdict,
        completed_at: &str,
        state_capture_at_report: Option<&str>,
    ) -> ExecutedGroupChange {
        if let Some(group) = self
            .executed_groups
            .iter_mut()
            .find(|group| group.group_id == group_id)
        {
            if group.verdict == verdict {
                return ExecutedGroupChange::Noop;
            }
            let previous = group.verdict;
            self.counts.decrement(previous);
            group.verdict = verdict;
            group.completed_at = completed_at.to_string();
            group.state_capture_at_report = state_capture_at_report.map(str::to_string);
            self.counts.increment(verdict);
            return ExecutedGroupChange::Updated(previous);
        }

        self.executed_groups.push(ExecutedGroupRecord {
            group_id: group_id.to_string(),
            verdict,
            completed_at: completed_at.to_string(),
            state_capture_at_report: state_capture_at_report.map(str::to_string),
        });
        self.counts.increment(verdict);
        ExecutedGroupChange::Inserted
    }

    #[must_use]
    pub fn last_group_capture_value(&self) -> Option<&str> {
        self.executed_groups
            .last()
            .and_then(|group| group.state_capture_at_report.as_deref())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::cognitive_complexity)]

    use super::*;
    use std::fs;
    use std::io::Write as _;

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
