use std::borrow::Cow;
use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::io;

use super::parsers::{split_frontmatter, yaml_str, yaml_str_list};

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
pub(super) fn render_frontmatter_list_into(out: &mut String, key: &str, values: &[String]) {
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
pub(super) fn yaml_quote_if_needed(s: &str) -> Cow<'_, str> {
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
