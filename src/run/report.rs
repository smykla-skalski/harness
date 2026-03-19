use std::borrow::Cow;
use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::io;

/// Overall verdict for a tracked run.
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

/// Per-group verdict recorded in run status and reports.
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
        let parsed = io::parse_frontmatter::<RunReportFrontmatter>(&text, "report")?;

        Ok(Self {
            frontmatter: parsed.frontmatter,
            path: path.to_path_buf(),
            body: parsed.body,
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
        use std::fmt::Write as _;

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

fn render_frontmatter_list_into(out: &mut String, key: &str, values: &[String]) {
    use std::fmt::Write as _;

    if values.is_empty() {
        writeln!(out, "{key}: []").unwrap();
        return;
    }
    writeln!(out, "{key}:").unwrap();
    for value in values {
        writeln!(out, "  - {}", yaml_quote_if_needed(value)).unwrap();
    }
}

fn yaml_quote_if_needed(value: &str) -> Cow<'_, str> {
    const SPECIAL: &[char] = &[':', '#', '`', '[', ']', '{', '}', '&', '*', '!', '%'];
    if value.contains(SPECIAL) {
        let escaped = value.replace('\'', "''");
        Cow::Owned(format!("'{escaped}'"))
    } else {
        Cow::Borrowed(value)
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

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
                    "g02 PASS - story with commas, updates, and deletes | evidence: `commands/g02.txt`".to_string(),
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
}
