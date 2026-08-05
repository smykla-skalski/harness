//! `SessionSummaryRow` (the sync path) moved here since `summaries.rs` needs
//! it and calls `SessionWriteQueries::sync_session` (also moving). The async
//! counterpart, `AsyncSessionSummaryRow`, stays behind in `harness-daemon`:
//! its `into_summary_canonicalized` calls `AsyncSessionWriteQueries::save_session_state`,
//! which hasn't moved yet, and this crate cannot depend back on `harness-daemon`.
//! The shared helpers below are `pub` so that remnant can still reach them.

use std::path::PathBuf;

use harness_daemon_db_core::{DaemonDb, db_error};
use harness_kernel::errors::CliError;
use harness_protocol::session::{
    CURRENT_VERSION, PendingLeaderTransfer, SessionMetrics, SessionState, SessionStatus,
};
use harness_session::index::DiscoveredProject;
use harness_session::service::canonicalize_persisted_session_state;
use harness_session::wire::SessionSummary;
use harness_workspace::workspace::utc_now;
use serde::Deserialize;

use crate::writes::SessionWriteQueries;

#[must_use]
pub fn parse_session_status_db_label(status: &str) -> SessionStatus {
    serde_json::from_value(serde_json::Value::String(status.to_string()))
        .unwrap_or(SessionStatus::Ended)
}

/// Fields a session summary needs that live only inside `state_json`. Declaring
/// just these lets serde skip materializing the `agents`, `tasks`, and `signals`
/// maps that dominate a full [`SessionState`] deserialization.
#[derive(Debug, Default, Deserialize)]
pub struct SessionSummaryStateProjection {
    #[serde(default)]
    pub worktree_path: String,
    #[serde(default)]
    pub shared_path: String,
    #[serde(default)]
    pub origin_path: String,
    #[serde(default)]
    pub branch_ref: String,
    #[serde(default)]
    pub external_origin: Option<String>,
    #[serde(default)]
    pub adopted_at: Option<String>,
    #[serde(default)]
    pub schema_version: i64,
}

impl SessionSummaryStateProjection {
    /// # Errors
    /// Returns [`CliError`] when `state_json` is not valid JSON.
    pub fn parse(state_json: &str) -> Result<Self, CliError> {
        serde_json::from_str(state_json)
            .map_err(|error| db_error(format!("parse session summary projection: {error}")))
    }
}

/// Already-selected scalar columns a summary needs, so the fast path never
/// re-parses them out of `state_json`.
pub struct SessionSummaryScalars {
    pub session_id: String,
    pub title: String,
    pub context: String,
    pub status_label: String,
    pub created_at: String,
    pub updated_at: String,
    pub last_activity_at: Option<String>,
    pub leader_id: Option<String>,
    pub observe_id: Option<String>,
    pub pending_leader_transfer_json: Option<String>,
    pub metrics_json: String,
}

/// Whether a persisted row is in one of the two shapes
/// [`canonicalize_persisted_session_state`] repairs. Mirrors its triggers so the
/// fast path is taken only when canonicalization would be a no-op; legacy rows
/// fall through to the slow path that parses, repairs, and writes back.
#[must_use]
pub fn session_summary_is_legacy(
    status: SessionStatus,
    leader_id: Option<&str>,
    archived_at: Option<&str>,
    schema_version: i64,
) -> bool {
    let active_without_leader = status == SessionStatus::Active && leader_id.is_none();
    let legacy_ended_archived = status == SessionStatus::Ended
        && archived_at.is_some()
        && schema_version < i64::from(CURRENT_VERSION);
    active_without_leader || legacy_ended_archived
}

/// Assemble a summary from the selected scalar columns plus the lightweight
/// `state_json` projection, with no full-state deserialization.
///
/// # Errors
/// Returns [`CliError`] when the cached metrics or pending-transfer JSON
/// cannot be parsed.
pub fn build_session_summary_fast(
    scalars: SessionSummaryScalars,
    projection: SessionSummaryStateProjection,
    project: &DiscoveredProject,
) -> Result<SessionSummary, CliError> {
    let metrics: SessionMetrics = serde_json::from_str(&scalars.metrics_json)
        .map_err(|error| db_error(format!("parse session metrics: {error}")))?;
    let pending_leader_transfer = scalars
        .pending_leader_transfer_json
        .as_deref()
        .map(serde_json::from_str::<PendingLeaderTransfer>)
        .transpose()
        .map_err(|error| db_error(format!("parse pending leader transfer: {error}")))?;
    Ok(SessionSummary {
        project_id: project.summary_project_id(),
        project_name: project.summary_project_name(),
        project_dir: project.summary_project_dir(),
        context_root: project.summary_context_root(),
        worktree_path: projection.worktree_path,
        shared_path: projection.shared_path,
        origin_path: projection.origin_path,
        branch_ref: projection.branch_ref,
        session_id: scalars.session_id,
        title: scalars.title,
        context: scalars.context,
        status: parse_session_status_db_label(&scalars.status_label),
        created_at: scalars.created_at,
        updated_at: scalars.updated_at,
        last_activity_at: scalars.last_activity_at,
        leader_id: scalars.leader_id,
        observe_id: scalars.observe_id,
        pending_leader_transfer,
        external_origin: projection.external_origin,
        adopted_at: projection.adopted_at,
        metrics,
    })
}

/// Assemble a summary from a fully parsed (and possibly canonicalized) state.
/// Shared by both slow paths.
#[must_use]
pub fn build_session_summary_from_state(
    state: SessionState,
    project: &DiscoveredProject,
) -> SessionSummary {
    SessionSummary {
        project_id: project.summary_project_id(),
        project_name: project.summary_project_name(),
        project_dir: project.summary_project_dir(),
        context_root: project.summary_context_root(),
        worktree_path: state.worktree_path.to_string_lossy().into_owned(),
        shared_path: state.shared_path.to_string_lossy().into_owned(),
        origin_path: state.origin_path.to_string_lossy().into_owned(),
        branch_ref: state.branch_ref,
        session_id: state.session_id,
        title: state.title,
        context: state.context,
        status: state.status,
        created_at: state.created_at,
        updated_at: state.updated_at,
        last_activity_at: state.last_activity_at,
        leader_id: state.leader_id,
        observe_id: state.observe_id,
        pending_leader_transfer: state.pending_leader_transfer,
        external_origin: state
            .external_origin
            .map(|path| path.to_string_lossy().into_owned()),
        adopted_at: state.adopted_at,
        metrics: state.metrics,
    }
}

pub struct SessionSummaryRow {
    pub session_id: String,
    pub title: String,
    pub context: String,
    pub status: String,
    pub created_at: String,
    pub updated_at: String,
    pub last_activity_at: Option<String>,
    pub leader_id: Option<String>,
    pub observe_id: Option<String>,
    pub pending_leader_transfer_json: Option<String>,
    pub metrics_json: String,
    pub state_json: String,
    pub archived_at: Option<String>,
    pub project_id: String,
    pub project_name: String,
    pub project_dir: Option<String>,
    pub repository_root: Option<String>,
    pub context_root: String,
    pub checkout_id: String,
    pub checkout_name: String,
    pub is_worktree: bool,
    pub worktree_name: Option<String>,
}

impl SessionSummaryRow {
    /// # Errors
    /// Returns [`CliError`] when the stored state cannot be parsed, or when
    /// canonicalization needs to persist a repaired row and that write fails.
    pub fn into_summary(self, db: &DaemonDb) -> Result<SessionSummary, CliError> {
        let projection = SessionSummaryStateProjection::parse(&self.state_json)?;
        if session_summary_is_legacy(
            parse_session_status_db_label(&self.status),
            self.leader_id.as_deref(),
            self.archived_at.as_deref(),
            projection.schema_version,
        ) {
            return self.into_summary_canonicalized(db);
        }
        let project = self.discovered_project();
        build_session_summary_fast(self.into_scalars(), projection, &project)
    }

    fn into_summary_canonicalized(self, db: &DaemonDb) -> Result<SessionSummary, CliError> {
        let mut state: SessionState = serde_json::from_str(&self.state_json)
            .map_err(|error| db_error(format!("parse session state: {error}")))?;
        let project = self.discovered_project();
        if canonicalize_persisted_session_state(&mut state, &utc_now()) {
            db.sync_session(&project.project_id, &state)?;
        }
        Ok(build_session_summary_from_state(state, &project))
    }

    fn discovered_project(&self) -> DiscoveredProject {
        DiscoveredProject {
            project_id: self.project_id.clone(),
            name: self.project_name.clone(),
            project_dir: self.project_dir.as_deref().map(PathBuf::from),
            repository_root: self.repository_root.as_deref().map(PathBuf::from),
            checkout_id: self.checkout_id.clone(),
            checkout_name: self.checkout_name.clone(),
            context_root: PathBuf::from(&self.context_root),
            is_worktree: self.is_worktree,
            worktree_name: self.worktree_name.clone(),
        }
    }

    fn into_scalars(self) -> SessionSummaryScalars {
        SessionSummaryScalars {
            session_id: self.session_id,
            title: self.title,
            context: self.context,
            status_label: self.status,
            created_at: self.created_at,
            updated_at: self.updated_at,
            last_activity_at: self.last_activity_at,
            leader_id: self.leader_id,
            observe_id: self.observe_id,
            pending_leader_transfer_json: self.pending_leader_transfer_json,
            metrics_json: self.metrics_json,
        }
    }
}
