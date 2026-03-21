use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::infra::io;

use super::markdown;
use super::verdict::Verdict;

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
