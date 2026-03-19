use serde::{Deserialize, Serialize};

/// File inventory payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileInventory {
    pub scoped_files: Vec<String>,
}

/// A coverage group.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoverageGroup {
    pub group_id: String,
    pub title: String,
    #[serde(default)]
    pub has_material: bool,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_files: Vec<String>,
}

/// Coverage summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoverageSummary {
    pub summary: String,
    #[serde(default)]
    pub groups: Vec<CoverageGroup>,
}

/// A variant signal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VariantSignal {
    pub signal_id: String,
    pub strength: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_files: Vec<String>,
    #[serde(default)]
    pub suggested_groups: Vec<String>,
}

/// Variant summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VariantSummary {
    pub summary: String,
    #[serde(default)]
    pub signals: Vec<VariantSignal>,
}

/// A schema fact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchemaFact {
    pub resource: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_files: Vec<String>,
    #[serde(default)]
    pub required_fields: Vec<String>,
}

/// Schema summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchemaSummary {
    pub summary: String,
    #[serde(default)]
    pub facts: Vec<SchemaFact>,
}

/// A proposal group.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProposalGroup {
    pub group_id: String,
    pub title: String,
    #[serde(default)]
    pub included: bool,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source_refs: Vec<String>,
}

/// Proposal summary result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProposalSummary {
    pub summary: String,
    #[serde(default)]
    pub suite_name: Option<String>,
    #[serde(default)]
    pub suite_dir: Option<String>,
    #[serde(default)]
    pub run_command: Option<String>,
    #[serde(default)]
    pub groups: Vec<ProposalGroup>,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub skipped_groups: Vec<String>,
}

impl ProposalSummary {
    #[must_use]
    pub fn effective_requires(&self) -> Vec<String> {
        self.requires.clone()
    }
}

/// Draft edit request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftEditRequest {
    pub summary: String,
    #[serde(default)]
    pub targets: Vec<String>,
}
