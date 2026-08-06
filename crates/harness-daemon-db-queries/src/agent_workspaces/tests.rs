use std::path::{Path, PathBuf};

use harness_daemon_db_core::{AsyncDaemonDb, DaemonDb, SchemaRepairHooks};
use harness_kernel::errors::CliError;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceAvailability, AgentWorkspaceConflictKind, AgentWorkspaceOrchestrationAuthority,
};
use harness_protocol::session::{CURRENT_VERSION, SessionState};
use serde_json::json;
use sqlx::{SqlitePool, query, query_scalar};
use tempfile::TempDir;

use super::AsyncAgentWorkspaceQueries;

const DAEMON_ID: &str = "daemon-test";
const NOW: &str = "2026-08-06T10:00:00Z";

mod adversarial;
mod availability;
mod tie_break;

#[tokio::test]
async fn reconciliation_is_restart_safe_and_workspace_survives_session_deletion() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-a", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-a",
        "active",
        NOW,
        false,
    )
    .await;

    let first = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile workspace");
    assert!(first.conflicts.is_empty());
    assert_eq!(first.workspaces.len(), 1);
    let workspace_id = first.workspaces[0].workspace_id.clone();
    assert_eq!(
        first.workspaces[0]
            .provenance
            .selected_legacy_session_id
            .as_deref(),
        Some("session-a")
    );

    let restarted = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("repeat reconciliation");
    assert_eq!(restarted.workspaces[0].workspace_id, workspace_id);
    assert_eq!(workspace_count(fixture.db.pool()).await, 1);

    query("DELETE FROM sessions WHERE session_id = 'session-a'")
        .execute(fixture.db.pool())
        .await
        .expect("delete legacy Session");
    let detached = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("detach legacy correlation");
    assert_eq!(detached.workspaces[0].workspace_id, workspace_id);
    assert_eq!(
        detached.workspaces[0].orchestration_authority,
        AgentWorkspaceOrchestrationAuthority::NoOwner
    );
    assert!(
        detached.workspaces[0]
            .provenance
            .selected_legacy_session_id
            .is_none()
    );
    assert!(
        detached.workspaces[0]
            .provenance
            .legacy_session_ids
            .is_empty()
    );
}

#[tokio::test]
async fn active_collision_blocks_every_owner_write() {
    let fixture = Fixture::new().await;
    let ready = fixture.project("project-ready", true);
    seed_project(fixture.db.pool(), &ready).await;
    seed_session(
        fixture.db.pool(),
        &ready,
        "session-ready",
        "active",
        NOW,
        false,
    )
    .await;

    let collision = fixture.project("project-collision", true);
    seed_project(fixture.db.pool(), &collision).await;
    seed_session(
        fixture.db.pool(),
        &collision,
        "session-a",
        "active",
        NOW,
        true,
    )
    .await;
    seed_session(
        fixture.db.pool(),
        &collision,
        "session-b",
        "active",
        NOW,
        true,
    )
    .await;

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("report collision");
    assert!(response.workspaces.is_empty());
    assert_eq!(response.conflicts.len(), 1);
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::ActiveOwnerCollision
    );
    assert_eq!(workspace_count(fixture.db.pool()).await, 0);
}

#[tokio::test]
async fn missing_checkout_keeps_exact_workspace_unavailable() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-missing", false);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-missing",
        "ended",
        NOW,
        false,
    )
    .await;

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile unavailable workspace");
    assert!(response.conflicts.is_empty());
    assert_eq!(
        response.workspaces[0].availability,
        AgentWorkspaceAvailability::MissingWorktree
    );
    assert_eq!(
        response.workspaces[0].checkout_root.as_deref(),
        project.checkout_root.to_str()
    );
}

#[tokio::test]
async fn untracked_shadow_disagreement_preserves_legacy_authority() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-shadow", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-shadow",
        "active",
        NOW,
        false,
    )
    .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    query("UPDATE agent_workspaces SET manifest_digest = 'tampered'")
        .execute(fixture.db.pool())
        .await
        .expect("tamper shadow workspace");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("detect shadow disagreement");
    assert!(response.workspaces.is_empty());
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceConflictKind::SourceDisagreement
    );
    let manifest = query_scalar::<_, String>("SELECT manifest_digest FROM agent_workspaces")
        .fetch_one(fixture.db.pool())
        .await
        .expect("load untouched shadow");
    assert_eq!(manifest, "tampered");
}

#[tokio::test]
async fn tracked_legacy_write_updates_shadow_without_duplication() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-update", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-update",
        "active",
        NOW,
        false,
    )
    .await;
    let first = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("create workspace");
    let first_manifest = first.workspaces[0].provenance.manifest_digest.clone();

    let later = "2026-08-06T10:01:00Z";
    let state = state_json("session-update", "active", later, 2);
    query(
        "UPDATE sessions
         SET state_version = 2, updated_at = ?2, state_json = ?3
         WHERE session_id = ?1",
    )
    .bind("session-update")
    .bind(later)
    .bind(state.to_string())
    .execute(fixture.db.pool())
    .await
    .expect("update legacy source");

    let updated = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("dual-write shadow");
    assert!(updated.conflicts.is_empty());
    assert_ne!(
        updated.workspaces[0].provenance.manifest_digest,
        first_manifest
    );
    assert_eq!(workspace_count(fixture.db.pool()).await, 1);
}

struct Fixture {
    temp: TempDir,
    db: AsyncDaemonDb,
}

impl Fixture {
    async fn new() -> Self {
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

    fn project(&self, id: &str, available: bool) -> ProjectFixture {
        let checkout_root = self.temp.path().join(id);
        if available {
            std::fs::create_dir_all(&checkout_root).expect("create checkout");
        }
        ProjectFixture {
            id: id.to_string(),
            repository_root: checkout_root.clone(),
            checkout_root,
            is_worktree: false,
            worktree_name: None,
        }
    }

    fn worktree_project(&self, id: &str) -> ProjectFixture {
        let repository_root = self.temp.path().join(format!("{id}-repository"));
        harness_testkit::init_git_repo_with_seed(&repository_root);
        let checkout_root = self.temp.path().join(format!("{id}-worktree"));
        harness_testkit::add_git_worktree(&repository_root, &checkout_root, id);
        ProjectFixture {
            id: id.to_string(),
            repository_root,
            checkout_root,
            is_worktree: true,
            worktree_name: Some(format!("{id}-worktree")),
        }
    }
}

struct ProjectFixture {
    id: String,
    checkout_root: PathBuf,
    repository_root: PathBuf,
    is_worktree: bool,
    worktree_name: Option<String>,
}

async fn seed_project(pool: &SqlitePool, project: &ProjectFixture) {
    let context_root = project.checkout_root.join(".context");
    query(
        "INSERT INTO projects (
            project_id, name, project_dir, repository_root, checkout_id, checkout_name,
            context_root, is_worktree, worktree_name, origin_json, discovered_at, updated_at
         ) VALUES (?1, ?1, ?2, ?3, ?1, ?6, ?4, ?7, ?8, NULL, ?5, ?5)",
    )
    .bind(&project.id)
    .bind(path_text(&project.checkout_root))
    .bind(path_text(&project.repository_root))
    .bind(path_text(&context_root))
    .bind(NOW)
    .bind(if project.is_worktree {
        "worktree"
    } else {
        "main"
    })
    .bind(project.is_worktree)
    .bind(&project.worktree_name)
    .execute(pool)
    .await
    .expect("seed project");
}

async fn seed_session(
    pool: &SqlitePool,
    project: &ProjectFixture,
    session_id: &str,
    status: &str,
    updated_at: &str,
    active_turn: bool,
) {
    let state = state_json(session_id, status, updated_at, 1);
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
    .execute(pool)
    .await
    .expect("seed Session");
    if active_turn {
        query(
            "INSERT INTO agent_turn_runs (
                run_id, session_id, requested_runtime, status, created_at, updated_at
             ) VALUES (?1, ?2, 'codex', 'running', ?3, ?3)",
        )
        .bind(format!("run-{session_id}"))
        .bind(session_id)
        .bind(updated_at)
        .execute(pool)
        .await
        .expect("seed active turn");
    }
}

fn state_json(
    session_id: &str,
    status: &str,
    updated_at: &str,
    state_version: u64,
) -> serde_json::Value {
    json!({
        "schema_version": CURRENT_VERSION,
        "state_version": state_version,
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

async fn workspace_count(pool: &SqlitePool) -> i64 {
    query_scalar("SELECT COUNT(*) FROM agent_workspaces")
        .fetch_one(pool)
        .await
        .expect("count workspaces")
}

fn path_text(path: &Path) -> String {
    path.display().to_string()
}

#[expect(
    clippy::unnecessary_wraps,
    reason = "SchemaRepairHooks callbacks must return Result"
)]
fn noop_sync_session(
    _db: &DaemonDb,
    _project_id: &str,
    _state: &SessionState,
) -> Result<(), CliError> {
    Ok(())
}

#[expect(
    clippy::unnecessary_wraps,
    reason = "SchemaRepairHooks callbacks must return Result"
)]
fn noop_backfill(_db: &DaemonDb) -> Result<(), CliError> {
    Ok(())
}
