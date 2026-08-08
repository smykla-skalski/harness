use harness_protocol::daemon::summaries::{
    AgentWorkspaceMembershipStatus, AgentWorkspaceRuntimeLifecycle,
};
use sqlx::{query, query_as};

use super::super::AsyncAgentWorkspaceTeamQueries;
use super::support::{DAEMON_ID, Fixture, NOW};
use crate::AsyncAgentWorkspaceQueries;

#[tokio::test]
async fn historical_session_delete_preserves_late_registration() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-historical-delete");
    fixture.seed_project(&project).await;
    fixture
        .seed_session(&project, "session-current", "active", NOW)
        .await;
    fixture
        .seed_session(
            &project,
            "session-historical",
            "ended",
            "2026-08-05T10:00:00Z",
        )
        .await;
    let workspaces = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile workspace identity");
    let workspace_id = workspaces.workspaces[0].workspace_id.clone();
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable team");

    fixture
        .seed_agent(
            "session-historical",
            "agent-late",
            "acp",
            "acp-late",
            "runtime-late",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile late historical registration");
    fixture.reconcile_activity(&workspace_id).await;
    query("DELETE FROM sessions WHERE session_id = 'session-historical'")
        .execute(fixture.db.pool())
        .await
        .expect("delete historical Session");

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load team after historical deletion");
    assert!(response.conflicts.is_empty());
    let late = response
        .team
        .expect("durable team")
        .members
        .into_iter()
        .find(|member| member.display_name == "agent-late")
        .expect("late historical member");
    assert_eq!(
        late.membership_status,
        AgentWorkspaceMembershipStatus::Historical
    );
    assert_eq!(late.runtime_session_id.as_deref(), Some("runtime-late"));
    let selected = query_as::<_, (i64,)>(
        "SELECT is_selected FROM agent_workspace_member_provenance
         WHERE workspace_id = ?1 AND source_session_id = 'session-historical'",
    )
    .bind(&workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load historical provenance selection")
    .0;
    assert_eq!(selected, 0);
}

#[tokio::test]
async fn reconciliation_preserves_deleted_session_provenance_for_shared_member() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-shared-provenance");
    fixture.seed_project(&project).await;
    fixture
        .seed_session(&project, "session-current", "active", NOW)
        .await;
    fixture
        .seed_session(&project, "session-deleted", "ended", "2026-08-05T10:00:00Z")
        .await;
    fixture
        .seed_agent(
            "session-current",
            "agent-current",
            "acp",
            "acp-shared",
            "runtime-shared",
        )
        .await;
    fixture
        .seed_agent(
            "session-deleted",
            "agent-deleted",
            "acp",
            "acp-shared",
            "runtime-shared",
        )
        .await;
    let workspace_id = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile shared workspace")
        .workspaces[0]
        .workspace_id
        .clone();
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create shared durable member");
    fixture.reconcile_activity(&workspace_id).await;

    query("DELETE FROM sessions WHERE session_id = 'session-deleted'")
        .execute(fixture.db.pool())
        .await
        .expect("delete historical source Session");
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile surviving source Session");

    let provenance_count = query_as::<_, (i64,)>(
        "SELECT COUNT(*) FROM agent_workspace_member_provenance
         WHERE workspace_id = ?1 AND source_session_id IN (
             'session-current', 'session-deleted'
         )",
    )
    .bind(&workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("count preserved shared provenance")
    .0;
    assert_eq!(provenance_count, 2);
}

#[tokio::test]
async fn session_delete_rejects_malformed_registration_before_artifact_cleanup() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-malformed-delete", "session-malformed-delete")
        .await;
    fixture
        .seed_agent(
            "session-malformed-delete",
            "agent-malformed",
            "acp",
            "runtime-malformed",
            "binding-malformed",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile valid registration");
    fixture.reconcile_activity(&workspace_id).await;
    query(
        "UPDATE agents SET managed_agent_kind = 'unknown', role = 'unknown'
         WHERE session_id = 'session-malformed-delete'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("corrupt legacy registration");

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("report malformed registration");
    assert_eq!(response.conflicts.len(), 1);
    let error = query("DELETE FROM sessions WHERE session_id = 'session-malformed-delete'")
        .execute(fixture.db.pool())
        .await
        .expect_err("malformed source must block Session detachment");
    assert!(
        error
            .to_string()
            .contains("cannot detach Session before agent team reconciliation")
    );
}

#[tokio::test]
async fn session_delete_rejects_conflicting_runtime_bindings() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-conflicting-delete", "session-conflicting-delete")
        .await;
    fixture
        .seed_agent(
            "session-conflicting-delete",
            "agent-left",
            "acp",
            "acp-shared",
            "binding-left",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile unambiguous registration");
    fixture.reconcile_activity(&workspace_id).await;
    fixture
        .seed_agent(
            "session-conflicting-delete",
            "agent-right",
            "acp",
            "acp-shared",
            "binding-right",
        )
        .await;

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("report conflicting runtime bindings");
    assert_eq!(response.conflicts.len(), 1);
    let error = query("DELETE FROM sessions WHERE session_id = 'session-conflicting-delete'")
        .execute(fixture.db.pool())
        .await
        .expect_err("ambiguous team must block Session detachment");
    assert!(
        error
            .to_string()
            .contains("cannot detach Session with conflicting managed agent bindings")
    );
    let source_exists = query_as::<_, (i64,)>(
        "SELECT EXISTS (
             SELECT 1 FROM sessions WHERE session_id = 'session-conflicting-delete'
         )",
    )
    .fetch_one(fixture.db.pool())
    .await
    .expect("inspect preserved conflicting Session")
    .0;
    assert_eq!(source_exists, 1);
}

#[tokio::test]
async fn session_delete_preserves_runtime_failure_evidence() {
    let fixture = Fixture::new().await;
    let session_id = "session-failure-evidence";
    let workspace_id = fixture
        .seed_workspace("project-failure-evidence", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            "terminal-member",
            "tui",
            "tui-failed",
            "terminal-binding",
        )
        .await;
    fixture
        .seed_tui(session_id, "tui-failed", "terminal-member", "failed")
        .await;
    query(
        "UPDATE agent_tuis
         SET exit_code = 9, signal = 'SIGTERM', error = 'terminal crashed'
         WHERE tui_id = 'tui-failed'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("seed terminal failure evidence");
    fixture
        .seed_agent(
            session_id,
            "codex-member",
            "codex",
            "codex-failed",
            "thread-failed",
        )
        .await;
    fixture
        .seed_codex(session_id, "codex-failed", "codex-member", "failed")
        .await;
    query(
        "UPDATE codex_runs
         SET thread_id = 'thread-failed', error = 'turn crashed'
         WHERE run_id = 'codex-failed'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("seed Codex failure evidence");
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("persist team before Session deletion");
    fixture.reconcile_activity(&workspace_id).await;

    query("DELETE FROM sessions WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("delete failure source Session");
    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load detached team failure evidence");
    let team = response.team.expect("detached durable team");
    let terminal = team
        .members
        .iter()
        .find(|member| member.display_name == "terminal-member")
        .expect("terminal member");
    assert_eq!(
        terminal.runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Failed
    );
    assert_eq!(
        terminal.runtime_evidence,
        "family=tui;status=failed;primary=9;secondary=SIGTERM;error=terminal crashed"
    );
    let codex = team
        .members
        .iter()
        .find(|member| member.display_name == "codex-member")
        .expect("Codex member");
    assert_eq!(
        codex.runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Failed
    );
    assert_eq!(
        codex.runtime_evidence,
        "family=codex;status=failed;primary=thread-failed;secondary=;error=turn crashed"
    );
}

#[tokio::test]
async fn workspace_selection_change_reassigns_current_membership() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-selection");
    fixture.seed_project(&project).await;
    fixture
        .seed_session(&project, "session-old", "active", NOW)
        .await;
    fixture
        .seed_agent("session-old", "agent-old", "acp", "acp-old", "runtime-old")
        .await;
    let initial = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile initial workspace");
    let workspace_id = initial.workspaces[0].workspace_id.clone();
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create initial team");

    query(
        "UPDATE sessions
         SET status = 'ended', is_active = 0, updated_at = '2026-08-06T11:00:00Z',
             state_json = json_set(
                 state_json,
                 '$.status', 'ended',
                 '$.updated_at', '2026-08-06T11:00:00Z'
             )
         WHERE session_id = 'session-old'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("end old Session");
    fixture
        .seed_session(&project, "session-new", "active", "2026-08-06T12:00:00Z")
        .await;
    fixture
        .seed_agent("session-new", "agent-new", "acp", "acp-new", "runtime-new")
        .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("select new Session");

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile replacement team source");
    let team = response.team.expect("durable team");
    let old = team
        .members
        .iter()
        .find(|member| member.display_name == "agent-old")
        .expect("old member");
    let new = team
        .members
        .iter()
        .find(|member| member.display_name == "agent-new")
        .expect("new member");
    assert_eq!(
        old.membership_status,
        AgentWorkspaceMembershipStatus::Historical
    );
    assert_eq!(
        new.membership_status,
        AgentWorkspaceMembershipStatus::Joined
    );
}

#[tokio::test]
async fn unchanged_workspace_reconcile_keeps_team_source_clean() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-clean-source", "session-clean-source")
        .await;
    fixture
        .seed_agent(
            "session-clean-source",
            "agent-clean-source",
            "acp",
            "acp-clean-source",
            "runtime-clean-source",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("settle workspace provenance");
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable team");
    let before = query_as::<_, (i64, i64)>(
        "SELECT source_revision, reconciled_revision
         FROM agent_workspace_teams WHERE workspace_id = ?1",
    )
    .bind(&workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load clean team revision");
    assert_eq!(before.0, before.1);

    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("repeat unchanged workspace reconciliation");
    let after = query_as::<_, (i64, i64)>(
        "SELECT source_revision, reconciled_revision
         FROM agent_workspace_teams WHERE workspace_id = ?1",
    )
    .bind(&workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load repeated team revision");
    assert_eq!(after, before);
}

#[tokio::test]
async fn detached_team_settles_after_workspace_provenance_cleanup() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-detached-clean", "session-detached-clean")
        .await;
    fixture
        .seed_agent(
            "session-detached-clean",
            "agent-detached-clean",
            "acp",
            "acp-detached-clean",
            "runtime-detached-clean",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable team");
    fixture.reconcile_activity(&workspace_id).await;
    query("DELETE FROM sessions WHERE session_id = 'session-detached-clean'")
        .execute(fixture.db.pool())
        .await
        .expect("delete legacy Session");
    fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("retire workspace provenance");

    let revisions = query_as::<_, (i64, i64)>(
        "SELECT source_revision, reconciled_revision
         FROM agent_workspace_teams WHERE workspace_id = ?1",
    )
    .bind(&workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load detached team revisions");
    assert_eq!(revisions.0, revisions.1);
}
