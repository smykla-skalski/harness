//! `SessionSummaryRow` (the sync path) and its shared helpers live in
//! `harness-daemon-db-queries` now (see that crate's `summary_rows` module) -
//! `AsyncSessionSummaryRow` stays here, since its `into_summary_canonicalized`
//! calls `AsyncSessionWriteQueries::save_session_state` (`async_writes.rs`),
//! not yet extracted; that crate cannot depend back on `harness-daemon`.

use std::path::PathBuf;

use harness_daemon_db_queries::{
    SessionSummaryScalars, SessionSummaryStateProjection, build_session_summary_fast,
    build_session_summary_from_state, parse_session_status_db_label, session_summary_is_legacy,
};

use super::async_writes::AsyncSessionWriteQueries;
use super::{AsyncDaemonDb, CliError, DiscoveredProject, SessionState, daemon_protocol, db_error};
use crate::session::service::canonicalize_persisted_session_state;
use crate::workspace::utc_now;

#[derive(sqlx::FromRow)]
pub(super) struct AsyncSessionSummaryRow {
    pub(super) session_id: String,
    title: String,
    context: String,
    status: String,
    created_at: String,
    updated_at: String,
    last_activity_at: Option<String>,
    leader_id: Option<String>,
    observe_id: Option<String>,
    pending_leader_transfer_json: Option<String>,
    metrics_json: String,
    state_json: String,
    archived_at: Option<String>,
    project_id: String,
    project_name: String,
    project_dir: Option<String>,
    repository_root: Option<String>,
    context_root: String,
    checkout_id: String,
    checkout_name: String,
    is_worktree: bool,
    worktree_name: Option<String>,
}

impl AsyncSessionSummaryRow {
    pub(super) async fn into_summary(
        self,
        db: &AsyncDaemonDb,
    ) -> Result<daemon_protocol::SessionSummary, CliError> {
        let projection = SessionSummaryStateProjection::parse(&self.state_json)?;
        if session_summary_is_legacy(
            parse_session_status_db_label(&self.status),
            self.leader_id.as_deref(),
            self.archived_at.as_deref(),
            projection.schema_version,
        ) {
            return self.into_summary_canonicalized(db).await;
        }
        let project = self.discovered_project();
        build_session_summary_fast(self.into_scalars(), projection, &project)
    }

    async fn into_summary_canonicalized(
        self,
        db: &AsyncDaemonDb,
    ) -> Result<daemon_protocol::SessionSummary, CliError> {
        let mut state: SessionState = serde_json::from_str(&self.state_json)
            .map_err(|error| db_error(format!("parse session state: {error}")))?;
        let project = self.discovered_project();
        if canonicalize_persisted_session_state(&mut state, &utc_now()) {
            db.save_session_state(&project.project_id, &state).await?;
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
