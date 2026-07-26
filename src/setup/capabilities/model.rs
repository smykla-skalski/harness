use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Feature identifier, serialized as `snake_case`.
///
/// Variants are declared in alphabetical order by `snake_case` name so that the
/// derived `Ord` produces the same key order as the previous `BTreeMap` output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum Feature {
    Bootstrap,
    BugFoundGate,
    GlobalDelay,
    HookSystem,
    IdempotentGroupReporting,
    JsonDiff,
    Observation,
    PreCompactHandoff,
    ProgressHeartbeat,
    RunLifecycle,
    SessionLifecycle,
    TaskManagement,
    TrackedRecording,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeatureInfo {
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commands: Option<Vec<String>>,
    pub description: String,
}

impl FeatureInfo {
    pub(super) fn new(description: &str) -> Self {
        Self {
            available: true,
            command: None,
            commands: None,
            description: description.into(),
        }
    }

    pub(super) fn command(mut self, value: &str) -> Self {
        self.command = Some(value.into());
        self
    }

    pub(super) fn commands(mut self, values: &[&str]) -> Self {
        self.commands = Some(values.iter().map(|&s| s.into()).collect());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateInfo {
    pub available: bool,
    pub commands: Vec<String>,
    pub description: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadinessCheckScope {
    Machine,
    Project,
    Repo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadinessStatus {
    Pass,
    Fail,
    Skipped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessScope {
    pub cwd: String,
    pub project_dir: String,
    pub repo_root: Option<String>,
    pub explicit_project_dir: bool,
    pub explicit_repo_root: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessCheck {
    pub code: String,
    pub scope: ReadinessCheckScope,
    pub status: ReadinessStatus,
    pub summary: String,
    pub path: Option<String>,
    pub hint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessSummary {
    pub ready: bool,
    pub blocking_checks: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessReport {
    pub scope: ReadinessScope,
    pub checks: Vec<ReadinessCheck>,
    pub create: ReadinessSummary,
    pub features: BTreeMap<Feature, ReadinessSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilitiesReport {
    pub create: CreateInfo,
    pub features: BTreeMap<Feature, FeatureInfo>,
    pub readiness: ReadinessReport,
}
