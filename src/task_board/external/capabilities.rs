use clap::ValueEnum;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ExternalSyncConflictPolicy {
    #[default]
    Report,
    PreferLocal,
    PreferRemote,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ExternalSyncField {
    Title,
    Body,
    Status,
    Project,
    Url,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalProviderCapabilities {
    pub create: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub update_fields: Vec<ExternalSyncField>,
}

impl ExternalProviderCapabilities {
    #[must_use]
    pub fn creates_only() -> Self {
        Self {
            create: true,
            update_fields: Vec::new(),
        }
    }

    #[must_use]
    pub fn with_update_fields(fields: impl Into<Vec<ExternalSyncField>>) -> Self {
        Self {
            create: true,
            update_fields: fields.into(),
        }
    }

    #[must_use]
    pub fn supports_update(&self, field: ExternalSyncField) -> bool {
        self.update_fields.contains(&field)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalTaskUpdate {
    pub changed_fields: Vec<ExternalSyncField>,
    pub precondition_updated_at: Option<String>,
}

impl ExternalTaskUpdate {
    #[must_use]
    pub fn new(changed_fields: Vec<ExternalSyncField>) -> Self {
        Self {
            changed_fields,
            precondition_updated_at: None,
        }
    }

    #[must_use]
    pub fn with_precondition_updated_at(mut self, updated_at: Option<String>) -> Self {
        self.precondition_updated_at = updated_at;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExternalUpdateOutcome {
    Applied {
        reference: super::ExternalTaskRef,
        provider_revision: Option<String>,
    },
    PreconditionFailed {
        current: super::ExternalTask,
    },
}
