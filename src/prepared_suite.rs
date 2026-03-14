use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

/// A file to copy from source to prepared location.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedCopy {
    pub source_path: PathBuf,
    pub prepared_path: PathBuf,
}

/// A file to write with generated content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedWrite {
    pub prepared_path: PathBuf,
    pub text: String,
}

/// SHA256 digest of a source file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceDigest {
    pub source_path: String,
    pub digest: String,
}

/// Validation result for a manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestValidation {
    #[serde(default)]
    pub output_path: Option<String>,
    pub status: String,
    #[serde(default)]
    pub checked_at: Option<String>,
    #[serde(default)]
    pub resource_kinds: Vec<String>,
}

/// Reference to a manifest in the prepared suite.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ManifestRef {
    pub manifest_id: String,
    pub scope: String,
    pub source_path: String,
    #[serde(default)]
    pub validation: Option<ManifestValidation>,
    #[serde(default)]
    pub group_id: Option<String>,
    #[serde(default)]
    pub prepared_path: Option<String>,
    #[serde(default)]
    pub digest: Option<String>,
    #[serde(default)]
    pub order: Option<i64>,
    #[serde(default)]
    pub applied: bool,
    #[serde(default)]
    pub applied_at: Option<String>,
    #[serde(default)]
    pub step: Option<String>,
    #[serde(default)]
    pub applied_path: Option<String>,
}

/// A prepared group with its manifests.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreparedGroup {
    pub group_id: String,
    pub source_path: String,
    #[serde(default)]
    pub helm_values: serde_json::Value,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
    #[serde(default)]
    pub skip_validation_orders: Vec<i64>,
    #[serde(default)]
    pub manifests: Vec<ManifestRef>,
}

/// The full prepared suite artifact.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreparedSuiteArtifact {
    pub suite_path: String,
    pub profile: String,
    pub prepared_at: String,
    #[serde(default)]
    pub source_digests: Vec<SourceDigest>,
    #[serde(default)]
    pub baselines: Vec<ManifestRef>,
    #[serde(default)]
    pub groups: Vec<PreparedGroup>,
}

impl PreparedSuiteArtifact {
    /// Load from a JSON file.
    ///
    /// # Errors
    /// Returns `CliError` if the file is missing or invalid.
    pub fn load(_path: &Path) -> Result<Option<Self>, CliError> {
        todo!()
    }

    /// Save to the canonical location.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn save(&self, _path: &Path) -> Result<(), CliError> {
        todo!()
    }
}

/// Plan for materializing a prepared suite.
#[derive(Debug, Clone)]
pub struct PreparedSuitePlan {
    pub artifact: PreparedSuiteArtifact,
    pub baseline_copies: Vec<PreparedCopy>,
    pub group_writes: Vec<PreparedWrite>,
}

/// Extract the Configure section from a group body.
#[must_use]
pub fn configure_section(_body: &str) -> Option<String> {
    todo!()
}

/// Extract the Consume section from a group body.
#[must_use]
pub fn consume_section(_body: &str) -> Option<String> {
    todo!()
}

/// Extract YAML code blocks from text.
#[must_use]
pub fn yaml_blocks(_text: &str) -> Vec<String> {
    todo!()
}

/// Extract shell code blocks from text.
#[must_use]
pub fn shell_blocks(_text: &str) -> Vec<String> {
    todo!()
}

#[cfg(test)]
mod tests {}
