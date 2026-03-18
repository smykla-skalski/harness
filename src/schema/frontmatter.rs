use serde::{Deserialize, Serialize};

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
    pub requires: Vec<String>,
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

impl SuiteFrontmatter {
    #[must_use]
    pub fn effective_requires(&self) -> Vec<String> {
        self.requires.clone()
    }
}
