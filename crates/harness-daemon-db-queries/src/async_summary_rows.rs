use std::path::PathBuf;

use harness_daemon_db_core::{AsyncDaemonDb, db_error};
use harness_kernel::errors::CliError;
use harness_protocol::session::SessionState;
use harness_session::index::DiscoveredProject;
use harness_session::service::canonicalize_persisted_session_state;
use harness_session::wire::SessionSummary;

use crate::async_writes::AsyncSessionWriteQueries;
use crate::summary_rows::{
    SessionSummaryScalars, SessionSummaryStateProjection, build_session_summary_fast,
    build_session_summary_from_state, parse_session_status_db_label, session_summary_is_legacy,
};

#[derive(sqlx::FromRow)]
pub struct AsyncSessionSummaryRow {
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

impl AsyncSessionSummaryRow {
    /// # Errors
    /// Returns [`CliError`] when the stored state cannot be parsed, or when
    /// canonicalization needs to persist a repaired row and that write fails.
    pub async fn into_summary(self, db: &AsyncDaemonDb) -> Result<SessionSummary, CliError> {
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
    ) -> Result<SessionSummary, CliError> {
        let mut state: SessionState = serde_json::from_str(&self.state_json)
            .map_err(|error| db_error(format!("parse session state: {error}")))?;
        let project = self.discovered_project();
        if canonicalize_persisted_session_state(
            &mut state,
            &harness_workspace::workspace::utc_now(),
        ) {
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
