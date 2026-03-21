use std::borrow::Cow;
use std::fmt;

use serde::{Deserialize, Serialize};

use super::fingerprint::FileFingerprint;

/// Runner handoff state for compaction.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunnerHandoff<'a> {
    pub run_dir: Cow<'a, str>,
    pub run_id: Cow<'a, str>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_id: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_path: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner_phase: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verdict: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_state_capture: Option<Cow<'a, str>>,
    pub next_action: Cow<'a, str>,
    #[serde(default)]
    pub executed_groups: Vec<Cow<'a, str>>,
    #[serde(default)]
    pub remaining_groups: Vec<Cow<'a, str>>,
    #[serde(default)]
    pub state_paths: Vec<Cow<'a, str>>,
}

/// Create handoff state for compaction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateHandoff<'a> {
    pub suite_dir: Cow<'a, str>,
    pub next_action: Cow<'a, str>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub create_phase: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suite_name: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub feature: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<Cow<'a, str>>,
    #[serde(default)]
    pub saved_payloads: Vec<Cow<'a, str>>,
    #[serde(default)]
    pub suite_files: Vec<Cow<'a, str>>,
    #[serde(default)]
    pub state_paths: Vec<Cow<'a, str>>,
}

/// Status of a compact handoff.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum HandoffStatus {
    Pending,
    Consumed,
}

impl fmt::Display for HandoffStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pending => f.write_str("pending"),
            Self::Consumed => f.write_str("consumed"),
        }
    }
}

/// Full compact handoff payload.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompactHandoff<'a> {
    pub version: u32,
    pub project_dir: Cow<'a, str>,
    pub created_at: Cow<'a, str>,
    pub status: HandoffStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_session_scope: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_session_id: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_path: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trigger: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_instructions: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consumed_at: Option<Cow<'a, str>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runner: Option<RunnerHandoff<'a>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub create: Option<CreateHandoff<'a>>,
    #[serde(default)]
    pub fingerprints: Vec<FileFingerprint<'a>>,
}

impl CompactHandoff<'_> {
    /// Whether the handoff has any active section.
    #[must_use]
    pub fn has_sections(&self) -> bool {
        self.runner.is_some() || self.create.is_some()
    }
}
