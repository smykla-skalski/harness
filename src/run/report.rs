use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::io;

mod markdown;

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
        markdown::render_report(self)
    }

    /// Save the report to disk.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn save(&self) -> Result<(), CliError> {
        io::write_text(&self.path, &self.to_markdown())
    }
}

#[cfg(test)]
mod tests;
