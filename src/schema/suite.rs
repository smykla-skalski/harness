use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io;

use super::frontmatter::{SuiteFrontmatter, SuiteFrontmatterUnchecked};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum GroupSection {
    Configure,
    Consume,
    Debug,
}

impl GroupSection {
    pub const ALL: &[Self] = &[Self::Configure, Self::Consume, Self::Debug];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Configure => "## Configure",
            Self::Consume => "## Consume",
            Self::Debug => "## Debug",
        }
    }

    #[must_use]
    pub fn missing_from(text: &str) -> Vec<Self> {
        Self::ALL
            .iter()
            .filter(|section| !text.contains(section.as_str()))
            .copied()
            .collect()
    }
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
        let parsed = io::parse_frontmatter::<SuiteFrontmatterUnchecked>(&text, "suite")?;
        let frontmatter = SuiteFrontmatter::try_from(parsed.frontmatter)?;

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
        let parsed = io::parse_frontmatter::<GroupFrontmatter>(&text, "group")?;
        let body = parsed.body;

        // Check required sections in body
        let missing = GroupSection::missing_from(&body);
        if !missing.is_empty() {
            let labels: Vec<&str> = missing.iter().map(|s| s.as_str()).collect();
            return Err(CliErrorKind::missing_sections("group body", labels.join(", ")).into());
        }

        Ok(Self {
            frontmatter: parsed.frontmatter,
            path: path.to_path_buf(),
            body,
        })
    }
}
