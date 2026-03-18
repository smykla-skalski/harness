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
    pub required_dependencies: Vec<String>,
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
        merge_requirement_lists(&self.requires, &self.required_dependencies)
    }
}

/// Merge `requires` with legacy `required_dependencies`, deduplicating entries.
///
/// When `requires` is empty, falls back to `required_dependencies` for backward
/// compatibility. Otherwise returns `requires` extended with any entries from
/// `required_dependencies` not already present.
#[must_use]
pub fn merge_requirement_lists(requires: &[String], legacy: &[String]) -> Vec<String> {
    if requires.is_empty() {
        return legacy.to_vec();
    }

    let mut merged = requires.to_vec();
    for entry in legacy {
        if !merged.contains(entry) {
            merged.push(entry.clone());
        }
    }
    merged
}
