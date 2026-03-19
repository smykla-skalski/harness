use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer, Serialize};

use crate::errors::{CliError, CliErrorKind};

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
    #[serde(default, alias = "required_dependencies")]
    pub requires: Vec<String>,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub variant_decisions: Vec<String>,
    #[serde(default)]
    pub coverage_expectations: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_baseline_files")]
    pub baseline_files: Vec<String>,
    #[serde(default)]
    pub groups: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_skipped_groups")]
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

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct SuiteFrontmatterUnchecked {
    #[serde(default)]
    pub suite_id: Option<String>,
    #[serde(default)]
    pub feature: Option<String>,
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub profiles: Vec<String>,
    #[serde(default, alias = "required_dependencies")]
    pub requires: Vec<String>,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub variant_decisions: Vec<String>,
    #[serde(default)]
    pub coverage_expectations: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_baseline_files")]
    pub baseline_files: Vec<String>,
    #[serde(default)]
    pub groups: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_skipped_groups")]
    pub skipped_groups: Vec<String>,
    #[serde(default)]
    pub keep_clusters: Option<bool>,
}

impl TryFrom<SuiteFrontmatterUnchecked> for SuiteFrontmatter {
    type Error = CliError;

    fn try_from(raw: SuiteFrontmatterUnchecked) -> Result<Self, Self::Error> {
        let mut missing = Vec::new();
        if raw.suite_id.is_none() {
            missing.push("suite_id");
        }
        if raw.feature.is_none() {
            missing.push("feature");
        }
        if raw.scope.is_none() {
            missing.push("scope");
        }
        if raw.keep_clusters.is_none() {
            missing.push("keep_clusters");
        }
        if !missing.is_empty() {
            return Err(
                CliErrorKind::missing_fields("suite frontmatter", missing.join(", ")).into(),
            );
        }

        Ok(Self {
            suite_id: raw.suite_id.expect("validated suite_id"),
            feature: raw.feature.expect("validated feature"),
            scope: raw.scope,
            profiles: raw.profiles,
            requires: raw.requires,
            user_stories: raw.user_stories,
            variant_decisions: raw.variant_decisions,
            coverage_expectations: raw.coverage_expectations,
            baseline_files: raw.baseline_files,
            groups: raw.groups,
            skipped_groups: raw.skipped_groups,
            keep_clusters: raw.keep_clusters.expect("validated keep_clusters"),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
enum BaselineFileEntry {
    Path(String),
    Structured { path: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
enum SkippedGroupEntry {
    Label(String),
    Structured(BTreeMap<String, String>),
}

fn deserialize_baseline_files<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    Option::<Vec<BaselineFileEntry>>::deserialize(deserializer).map(|entries| {
        entries.map_or_else(Vec::new, |entries| {
            entries
                .into_iter()
                .map(|entry| match entry {
                    BaselineFileEntry::Path(path) | BaselineFileEntry::Structured { path } => path,
                })
                .collect()
            })
    })
}

fn deserialize_skipped_groups<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    Option::<Vec<SkippedGroupEntry>>::deserialize(deserializer).map(|entries| {
        entries.map_or_else(Vec::new, |entries| {
            entries
                .into_iter()
                .flat_map(|entry| match entry {
                    SkippedGroupEntry::Label(label) => vec![label],
                    SkippedGroupEntry::Structured(map) => map
                        .into_iter()
                        .map(|(group, reason)| format!("{group}: {reason}"))
                        .collect(),
                })
                .collect()
        })
    })
}
