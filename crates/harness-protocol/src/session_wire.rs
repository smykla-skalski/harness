//! Session-domain request/response and on-disk registry contracts.
//!
//! The daemon canonically owns these shapes, but a client that talks to the
//! daemon over HTTP, or falls back to reading session state directly when
//! the daemon is unreachable, needs the identical shape on its own side of
//! the wire or the disk file. Before this module existed, `harness-hook`
//! hand-copied each one instead of depending on it, so a field added to one
//! side alone would silently stop round-tripping - the same class of bug
//! fixed for the daemon manifest types.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::agent::AckResult;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ResolvedRuntimeSessionAgent {
    pub orchestration_session_id: String,
    pub session_agent_id: String,
}

/// Wire-level outcome of a runtime-session lookup.
///
/// Returned by `GET /v1/runtime-sessions/resolve`. `resolved` is `None` when
/// no live agent matches; `Some` carries the single unambiguous match. The
/// daemon surfaces ambiguity as a `session_ambiguous` error instead of
/// populating this response with multiple entries.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct RuntimeSessionResolutionResponse {
    pub resolved: Option<ResolvedRuntimeSessionAgent>,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct SessionLeaveRequest {
    pub agent_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct SignalAckRequest {
    pub agent_id: String,
    pub signal_id: String,
    pub result: AckResult,
    pub project_dir: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentRuntimeSessionRegistrationRequest {
    pub managed_agent_id: String,
    pub runtime: String,
    pub runtime_session_id: String,
    pub project_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentRuntimeSessionRegistrationResponse {
    pub registered: bool,
}

/// Per-project active-session registry.
///
/// Stored at `<sessions_root>/<project_name>/.active.json`. The map key is
/// the session id; the value is the creation timestamp.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ActiveRegistry {
    #[serde(default)]
    pub sessions: BTreeMap<String, String>,
}

/// Recorded origin of a project's session context.
///
/// Stored at `project-origin.json` so cross-project discovery can recover
/// the directory a context root was created from, and which external
/// session roots have been adopted into it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectOriginRecord {
    pub recorded_from_dir: String,
    pub repository_root: Option<String>,
    pub checkout_root: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub adopted_session_roots: BTreeMap<String, String>,
    pub recorded_at: String,
}
