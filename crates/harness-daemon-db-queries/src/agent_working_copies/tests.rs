use harness_daemon_db_core::{AsyncDaemonDb, DaemonDb, SchemaRepairHooks};
use harness_kernel::errors::CliError;
use harness_protocol::session::SessionState;
use harness_session::index::DiscoveredProject;
use sqlx::query_scalar;
use tempfile::TempDir;

use super::{
    AgentWorkingCopy, AsyncAgentWorkingCopyQueries, WorkspaceCheckoutRequest,
    WorkspaceManagedAgentKind, WorkspaceMemberRegistration,
};
use crate::AsyncAgentWorkspaceQueries;

const DAEMON_ID: &str = "daemon-test";

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

    /// A real linked worktree, because the provision path verifies the checkout
    /// through git rather than trusting the caller's paths.
    fn worktree_checkout(&self, name: &str) -> DiscoveredProject {
        let repository_root = self.temp.path().join(format!("{name}-repository"));
        harness_testkit::init_git_repo_with_seed(&repository_root);
        let checkout_root = self.temp.path().join(format!("{name}-worktree"));
        harness_testkit::add_git_worktree(&repository_root, &checkout_root, name);
        DiscoveredProject {
            project_id: format!("project-{name}"),
            name: name.to_string(),
            project_dir: Some(checkout_root.clone()),
            repository_root: Some(repository_root),
            checkout_id: format!("checkout-{name}"),
            checkout_name: name.to_string(),
            context_root: checkout_root.join(".context"),
            is_worktree: true,
            worktree_name: Some(format!("{name}-worktree")),
        }
    }

    fn request(&self, name: &str, working_copy_id: &str) -> WorkspaceCheckoutRequest {
        let project = self.worktree_checkout(name);
        let worktree_path = project
            .project_dir
            .as_ref()
            .expect("checkout has a directory")
            .to_string_lossy()
            .into_owned();
        WorkspaceCheckoutRequest {
            daemon_id: DAEMON_ID.to_string(),
            project,
            working_copy_id: working_copy_id.to_string(),
            origin_path: self.temp.path().join("origin").to_string_lossy().into_owned(),
            project_name: name.to_string(),
            worktree_path,
            branch_ref: format!("harness/{working_copy_id}"),
        }
    }
}

fn noop_sync_session(_: &DaemonDb, _: &str, _: &SessionState) -> Result<(), CliError> {
    Ok(())
}

fn noop_backfill(_: &DaemonDb) -> Result<(), CliError> {
    Ok(())
}

#[tokio::test]
async fn provisioning_creates_the_workspace_its_team_and_the_checkout() {
    let fixture = Fixture::new().await;
    let request = fixture.request("alpha", "copy-alpha");

    let provisioned = fixture
        .db
        .provision_agent_workspace_checkout(&request)
        .await
        .expect("provision checkout");

    assert_eq!(provisioned.working_copy_id, "copy-alpha");
    assert_eq!(provisioned.worktree_path, request.worktree_path);
    let authority = query_scalar::<_, String>(
        "SELECT orchestration_authority FROM agent_workspaces WHERE workspace_id = ?1",
    )
    .bind(&provisioned.workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load workspace authority");
    assert_eq!(
        authority, "workspace",
        "a workspace the daemon provisioned owns its own orchestration"
    );
    let teams = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM agent_workspace_teams WHERE workspace_id = ?1",
    )
    .bind(&provisioned.workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("count teams");
    assert_eq!(teams, 1);
    let sessions = query_scalar::<_, i64>("SELECT COUNT(*) FROM sessions")
        .fetch_one(fixture.db.pool())
        .await
        .expect("count sessions");
    assert_eq!(sessions, 0, "provisioning must not create a Session");
    let stored = fixture
        .db
        .load_agent_working_copy("copy-alpha")
        .await
        .expect("load working copy");
    assert_eq!(
        stored,
        Some(AgentWorkingCopy {
            working_copy_id: "copy-alpha".to_string(),
            workspace_id: provisioned.workspace_id,
            origin_path: request.origin_path,
            project_name: "alpha".to_string(),
            worktree_path: request.worktree_path,
            branch_ref: "harness/copy-alpha".to_string(),
            released: false,
        })
    );
}

/// A preparation that crashed after creating the checkout retries with the same
/// reserved id. That retry has to land on the row it already wrote, or the
/// live-path index turns a recoverable retry into a permanent failure.
#[tokio::test]
async fn re_provisioning_the_same_id_leaves_one_checkout() {
    let fixture = Fixture::new().await;
    let request = fixture.request("beta", "copy-beta");

    let first = fixture
        .db
        .provision_agent_workspace_checkout(&request)
        .await
        .expect("provision checkout");
    let second = fixture
        .db
        .provision_agent_workspace_checkout(&request)
        .await
        .expect("re-provision checkout");

    assert_eq!(first, second);
    let copies = query_scalar::<_, i64>("SELECT COUNT(*) FROM agent_working_copies")
        .fetch_one(fixture.db.pool())
        .await
        .expect("count working copies");
    assert_eq!(copies, 1);
}

/// Reconciliation recomputes every workspace's shadow digest and reports a
/// mismatch as corruption. A provisioned workspace has no legacy candidate to
/// rebuild from, so its digest has to be written the way reconciliation will
/// read it back.
#[tokio::test]
async fn a_provisioned_workspace_survives_reconciliation() {
    let fixture = Fixture::new().await;
    let request = fixture.request("gamma", "copy-gamma");
    let provisioned = fixture
        .db
        .provision_agent_workspace_checkout(&request)
        .await
        .expect("provision checkout");

    let reconciled = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile workspaces");

    assert!(
        reconciled.conflicts.is_empty(),
        "a provisioned workspace must not read as corrupted, got {:?}",
        reconciled.conflicts
    );
    assert!(
        reconciled
            .workspaces
            .iter()
            .any(|workspace| workspace.workspace_id == provisioned.workspace_id),
        "reconciliation must keep the provisioned workspace"
    );
}

#[tokio::test]
async fn releasing_a_checkout_is_reported_once() {
    let fixture = Fixture::new().await;
    let request = fixture.request("delta", "copy-delta");
    fixture
        .db
        .provision_agent_workspace_checkout(&request)
        .await
        .expect("provision checkout");

    assert!(
        fixture
            .db
            .release_agent_working_copy("copy-delta", "compensated")
            .await
            .expect("release checkout"),
        "the first release owns the cleanup"
    );
    assert!(
        !fixture
            .db
            .release_agent_working_copy("copy-delta", "compensated")
            .await
            .expect("repeat release"),
        "a repeated release must not claim cleanup a second time"
    );
    let stored = fixture
        .db
        .load_agent_working_copy("copy-delta")
        .await
        .expect("load released copy")
        .expect("released copy is still readable");
    assert!(stored.released);
}

#[tokio::test]
async fn a_started_worker_joins_its_workspace_team_once() {
    let fixture = Fixture::new().await;
    let request = fixture.request("epsilon", "copy-epsilon");
    let provisioned = fixture
        .db
        .provision_agent_workspace_checkout(&request)
        .await
        .expect("provision checkout");
    let registration = WorkspaceMemberRegistration {
        workspace_id: provisioned.workspace_id.clone(),
        kind: WorkspaceManagedAgentKind::Codex,
        managed_agent_id: "codex-dispatch-intent-1".to_string(),
        runtime_kind: "codex".to_string(),
        display_name: "Task Board: ship it".to_string(),
        assignment_id: Some("task-board-1".to_string()),
    };

    let member_id = fixture
        .db
        .register_workspace_managed_member(&registration)
        .await
        .expect("join workspace team");
    let repeated = fixture
        .db
        .register_workspace_managed_member(&registration)
        .await
        .expect("re-join workspace team");

    assert_eq!(member_id, repeated);
    let members =
        query_scalar::<_, i64>("SELECT COUNT(*) FROM agent_workspace_members WHERE workspace_id = ?1")
            .bind(&provisioned.workspace_id)
            .fetch_one(fixture.db.pool())
            .await
            .expect("count members");
    assert_eq!(members, 1, "a reclaimed start must not add a second member");
    let lifecycle = query_scalar::<_, String>(
        "SELECT runtime_lifecycle FROM agent_workspace_members WHERE member_id = ?1",
    )
    .bind(&member_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load member lifecycle");
    assert_eq!(lifecycle, "running");

    fixture
        .db
        .record_workspace_member_runtime_stop(&provisioned.workspace_id, &member_id, "compensated")
        .await
        .expect("record runtime stop");

    let after: (String, String) = sqlx::query_as(
        "SELECT runtime_lifecycle, membership_status
         FROM agent_workspace_members WHERE member_id = ?1",
    )
    .bind(&member_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load stopped member");
    assert_eq!(
        after,
        ("completed".to_string(), "joined".to_string()),
        "stopping a runtime must not remove the membership behind it"
    );
}
