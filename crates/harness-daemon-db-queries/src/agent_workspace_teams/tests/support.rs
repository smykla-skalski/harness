use std::path::{Path, PathBuf};

use harness_daemon_db_core::{AsyncDaemonDb, DaemonDb, SchemaRepairHooks};
use harness_kernel::errors::CliError;
use harness_protocol::session::{CURRENT_VERSION, SessionState};
use harness_protocol::timeline::TimelineWindowRequest;
use serde_json::json;
use sqlx::query;
use tempfile::TempDir;

use crate::{AsyncAgentWorkspaceActivityQueries, AsyncAgentWorkspaceQueries};

pub(super) const DAEMON_ID: &str = "daemon-team-test";
pub(super) const NOW: &str = "2026-08-06T10:00:00Z";

pub(super) struct Fixture {
    temp: TempDir,
    pub(super) db: AsyncDaemonDb,
}

impl Fixture {
    pub(super) async fn new() -> Self {
        let temp = tempfile::tempdir().expect("tempdir");
        let path = temp.path().join("harness.db");
        let hooks = SchemaRepairHooks {
            sync_session: noop_sync_session,
            backfill_legacy_timelines: noop_backfill,
        };
        let db = AsyncDaemonDb::connect_with_hooks(&path, &hooks)
            .await
            .expect("open async database");
        Self { temp, db }
    }

    pub(super) fn project(&self, id: &str) -> ProjectFixture {
        let root = self.temp.path().join(id);
        std::fs::create_dir_all(&root).expect("create checkout");
        ProjectFixture {
            id: id.to_string(),
            checkout_root: root,
        }
    }

    pub(super) async fn seed_workspace(&self, project_id: &str, session_id: &str) -> String {
        let project = self.project(project_id);
        self.seed_project(&project).await;
        self.seed_session(&project, session_id, "active", NOW).await;
        let response = self
            .db
            .reconcile_agent_workspaces(DAEMON_ID)
            .await
            .expect("seed durable workspace");
        response.workspaces[0].workspace_id.clone()
    }

    pub(super) async fn reconcile_activity(&self, workspace_id: &str) {
        self.db
            .load_agent_workspace_activity(
                DAEMON_ID,
                workspace_id,
                &TimelineWindowRequest::default(),
            )
            .await
            .expect("reconcile durable agent activity");
    }

    pub(super) async fn seed_project(&self, project: &ProjectFixture) {
        let context_root = project.checkout_root.join(".context");
        query(
            "INSERT INTO projects (
                project_id, name, project_dir, repository_root, checkout_id, checkout_name,
                context_root, is_worktree, worktree_name, origin_json, discovered_at, updated_at
             ) VALUES (?1, ?1, ?2, ?2, ?1, 'main', ?3, 0, NULL, NULL, ?4, ?4)",
        )
        .bind(&project.id)
        .bind(path_text(&project.checkout_root))
        .bind(path_text(&context_root))
        .bind(NOW)
        .execute(self.db.pool())
        .await
        .expect("seed project");
    }

    pub(super) async fn seed_session(
        &self,
        project: &ProjectFixture,
        session_id: &str,
        status: &str,
        updated_at: &str,
    ) {
        let state = state_json(session_id, status, updated_at);
        query(
            "INSERT INTO sessions (
                session_id, project_id, schema_version, state_version, title, context,
                status, leader_id, observe_id, created_at, updated_at, last_activity_at,
                archived_at, pending_leader_transfer, metrics_json, state_json, is_active
             ) VALUES (?1, ?2, ?3, 1, '', 'test', ?4, NULL, NULL, ?5, ?6, NULL,
                       NULL, NULL, '{}', ?7, ?8)",
        )
        .bind(session_id)
        .bind(&project.id)
        .bind(i64::from(CURRENT_VERSION))
        .bind(status)
        .bind(NOW)
        .bind(updated_at)
        .bind(state.to_string())
        .bind(status != "ended")
        .execute(self.db.pool())
        .await
        .expect("seed Session");
    }

    pub(super) async fn seed_agent(
        &self,
        session_id: &str,
        agent_id: &str,
        managed_kind: &str,
        managed_id: &str,
        runtime_session_id: &str,
    ) {
        query(
            "INSERT INTO agents (
                agent_id, session_id, name, runtime, role, capabilities_json,
                status, agent_session_id, managed_agent_kind, managed_agent_id,
                joined_at, updated_at, last_activity_at, current_task_id,
                runtime_capabilities_json
             ) VALUES (?1, ?2, ?1, ?3, 'worker', '[]', ?7, ?5,
                       ?3, ?4, ?6, ?6, ?6, NULL, '{}')",
        )
        .bind(agent_id)
        .bind(session_id)
        .bind(managed_kind)
        .bind(managed_id)
        .bind(runtime_session_id)
        .bind(NOW)
        .bind("\"active\"")
        .execute(self.db.pool())
        .await
        .expect("seed agent");
    }

    pub(super) async fn seed_tui(
        &self,
        session_id: &str,
        tui_id: &str,
        agent_id: &str,
        status: &str,
    ) {
        query(
            "INSERT INTO agent_tuis (
                tui_id, session_id, agent_id, runtime, status, argv_json,
                project_dir, rows, cols, cursor_row, cursor_col, screen_text,
                transcript_path, exit_code, signal, error, created_at, updated_at
             ) VALUES (?1, ?2, ?3, 'codex', ?4, '[]', '/tmp', 30, 120, 0, 0, '',
                       '/tmp/transcript', NULL, NULL, NULL, ?5, ?5)",
        )
        .bind(tui_id)
        .bind(session_id)
        .bind(agent_id)
        .bind(status)
        .bind(NOW)
        .execute(self.db.pool())
        .await
        .expect("seed terminal runtime");
    }

    pub(super) async fn seed_codex(
        &self,
        session_id: &str,
        run_id: &str,
        agent_id: &str,
        status: &str,
    ) {
        query(
            "INSERT INTO codex_runs (
                run_id, session_id, session_agent_id, display_name, project_dir,
                mode, status, prompt, pending_approvals_json,
                resolved_approvals_json, events_json, created_at, updated_at
             ) VALUES (?1, ?2, ?3, ?3, '/tmp', 'single_turn', ?4, 'test',
                       '[]', '[]', '[]', ?5, ?5)",
        )
        .bind(run_id)
        .bind(session_id)
        .bind(agent_id)
        .bind(status)
        .bind(NOW)
        .execute(self.db.pool())
        .await
        .expect("seed Codex runtime");
    }
}

pub(super) struct ProjectFixture {
    id: String,
    checkout_root: PathBuf,
}

fn state_json(session_id: &str, status: &str, updated_at: &str) -> serde_json::Value {
    json!({
        "schema_version": CURRENT_VERSION,
        "state_version": 1,
        "session_id": session_id,
        "project_name": "test",
        "worktree_path": "",
        "shared_path": "",
        "origin_path": "",
        "branch_ref": "",
        "title": "",
        "context": "test",
        "status": status,
        "created_at": NOW,
        "updated_at": updated_at,
        "agents": {},
        "tasks": {},
        "leader_id": null,
        "metrics": {}
    })
}

fn path_text(path: &Path) -> String {
    path.display().to_string()
}

#[expect(clippy::unnecessary_wraps, reason = "schema repair callback contract")]
fn noop_sync_session(
    _db: &DaemonDb,
    _project_id: &str,
    _state: &SessionState,
) -> Result<(), CliError> {
    Ok(())
}

#[expect(clippy::unnecessary_wraps, reason = "schema repair callback contract")]
fn noop_backfill(_db: &DaemonDb) -> Result<(), CliError> {
    Ok(())
}
