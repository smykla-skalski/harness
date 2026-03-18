use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io;
use crate::rules;

use super::frontmatter::SuiteFrontmatter;

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
        let (yaml_text, _body) = io::extract_raw_frontmatter(&text)?;

        // First pass: check required keys exist in the mapping.
        let map: serde_yml::Mapping = serde_yml::from_str(&yaml_text)
            .map_err(|e| CliErrorKind::workflow_parse(format!("frontmatter YAML: {e}")))?;

        let mut missing = Vec::new();
        for key in ["suite_id", "feature", "scope", "keep_clusters"] {
            if !map.contains_key(serde_yml::Value::String(key.to_string())) {
                missing.push(key);
            }
        }
        if !missing.is_empty() {
            return Err(
                CliErrorKind::missing_fields("suite frontmatter", missing.join(", ")).into(),
            );
        }

        // Second pass: typed deserialization.
        let frontmatter: SuiteFrontmatter = serde_yml::from_str(&yaml_text)
            .map_err(|e| CliErrorKind::workflow_parse(format!("suite frontmatter: {e}")))?;

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
        let (yaml_text, body) = io::extract_raw_frontmatter(&text)?;

        // Check required sections in body
        let missing = rules::shared::GroupSection::missing_from(&body);
        if !missing.is_empty() {
            let labels: Vec<&str> = missing.iter().map(|s| s.as_str()).collect();
            return Err(CliErrorKind::missing_sections("group body", labels.join(", ")).into());
        }

        let frontmatter: GroupFrontmatter = serde_yml::from_str(&yaml_text)
            .map_err(|e| CliErrorKind::workflow_parse(format!("group frontmatter: {e}")))?;

        Ok(Self {
            frontmatter,
            path: path.to_path_buf(),
            body,
        })
    }
}
