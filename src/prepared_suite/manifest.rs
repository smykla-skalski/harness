use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

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
    pub text: Cow<'static, str>,
}

/// Status of a manifest validation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ValidationStatus {
    Pending,
    Passed,
    Failed,
}

impl fmt::Display for ValidationStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pending => f.write_str("pending"),
            Self::Passed => f.write_str("passed"),
            Self::Failed => f.write_str("failed"),
        }
    }
}

/// Validation result for a manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestValidation {
    #[serde(default)]
    pub output_path: Option<String>,
    pub status: ValidationStatus,
    #[serde(default)]
    pub checked_at: Option<String>,
    #[serde(default)]
    pub resource_kinds: Vec<String>,
}

/// Scope of a prepared manifest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ManifestScope {
    Baseline,
    Group,
}

pub type HelmValues = BTreeMap<String, serde_json::Value>;

/// Reference to a manifest in the prepared suite.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ManifestRef {
    pub manifest_id: String,
    pub scope: ManifestScope,
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
    pub helm_values: HelmValues,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
    #[serde(default)]
    pub skip_validation_orders: Vec<i64>,
    #[serde(default)]
    pub manifests: Vec<ManifestRef>,
}
