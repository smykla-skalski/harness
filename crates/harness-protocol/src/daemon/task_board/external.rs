//! The external-sync domain's pure-data surface, relocated here from
//! `harness-task-board::external`. `ExternalTask`, `ExternalTaskRef`,
//! `ExternalCreateOutcome`, the `ExternalSyncClient` trait, and the rest of
//! that module's sync engine, including `ExternalSyncDirection`/
//! `ExternalSyncOptions`, stay in `harness-task-board`: they reach the full
//! `TaskBoardItem` domain entity and `CliError`-returning async provider
//! clients this move has no need for. `ExternalProvider` moves because
//! `TaskBoardProviderSyncSummary` (`harness-task-board::summary`) embeds it
//! directly; `ExternalSyncOperation`/`ExternalSyncAction`/`ExternalSyncField`
//! move because `TaskBoardSyncSummary` embeds `ExternalSyncOperation` in
//! turn. `harness-task-board` re-exports every name below at the same path.

use std::fmt;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use super::item_fields::ExternalRefProvider;

pub const HARNESS_GITHUB_TOKEN_ENV: &str = "HARNESS_GITHUB_TOKEN";
pub const GH_TOKEN_ENV: &str = "GH_TOKEN";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum ExternalProvider {
    #[value(name = "github", alias = "git_hub")]
    #[serde(rename = "github", alias = "git_hub")]
    GitHub,
}

impl ExternalProvider {
    #[must_use]
    pub const fn token_env_names(self) -> &'static [&'static str] {
        match self {
            Self::GitHub => &[HARNESS_GITHUB_TOKEN_ENV, GH_TOKEN_ENV],
        }
    }
}

impl fmt::Display for ExternalProvider {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::GitHub => formatter.write_str("github"),
        }
    }
}

impl From<ExternalRefProvider> for ExternalProvider {
    fn from(provider: ExternalRefProvider) -> Self {
        match provider {
            ExternalRefProvider::GitHub => Self::GitHub,
        }
    }
}

impl From<ExternalProvider> for ExternalRefProvider {
    fn from(provider: ExternalProvider) -> Self {
        match provider {
            ExternalProvider::GitHub => Self::GitHub,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum ExternalSyncAction {
    Pull,
    Push,
    Conflict,
    Delete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum ExternalSyncField {
    Title,
    Body,
    Status,
    Project,
    Url,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ExternalSyncOperation {
    pub provider: ExternalProvider,
    pub action: ExternalSyncAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub board_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub dry_run: bool,
    pub applied: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub changed_fields: Vec<ExternalSyncField>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unsupported_fields: Vec<ExternalSyncField>,
}

// Existing coverage for these types stays in `harness-task-board::external`
// and its submodules, exercised through the re-export below.
