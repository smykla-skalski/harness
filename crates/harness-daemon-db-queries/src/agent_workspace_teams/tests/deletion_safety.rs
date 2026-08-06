use harness_protocol::agent::DisconnectReason;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceMemberOperationOutcome, AgentWorkspaceMembershipStatus,
    AgentWorkspaceRuntimeLifecycle,
};
use harness_protocol::session::AgentStatus;
use sqlx::{query, query_as, query_scalar};

use super::super::{AsyncAgentWorkspaceTeamOperationQueries, AsyncAgentWorkspaceTeamQueries};
use super::support::{DAEMON_ID, Fixture, NOW};

#[tokio::test]
async fn unreconciled_team_sources_block_raw_session_deletion() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-unreconciled-delete");
    fixture.seed_project(&project).await;
    fixture
        .seed_session(&project, "session-unreconciled-delete", "active", NOW)
        .await;
    fixture
        .seed_agent(
            "session-unreconciled-delete",
            "agent-unreconciled-delete",
            "acp",
            "acp-unreconciled-delete",
            "runtime-unreconciled-delete",
        )
        .await;

    let error = query("DELETE FROM sessions WHERE session_id = 'session-unreconciled-delete'")
        .execute(fixture.db.pool())
        .await
        .expect_err("raw deletion must not discard unreconciled team sources");
    assert!(
        error
            .to_string()
            .contains("cannot detach Session before agent workspace reconciliation")
    );
    let source_exists = query_scalar::<_, i64>(
        "SELECT EXISTS (
             SELECT 1 FROM sessions WHERE session_id = 'session-unreconciled-delete'
         )",
    )
    .fetch_one(fixture.db.pool())
    .await
    .expect("inspect protected source Session");
    assert_eq!(source_exists, 1);
}

#[tokio::test]
async fn selected_session_deletion_preserves_durable_leadership() {
    let fixture = Fixture::new().await;
    let session_id = "session-leader-delete";
    let workspace_id = fixture
        .seed_workspace("project-leader-delete", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            "agent-leader-delete",
            "acp",
            "acp-leader-delete",
            "runtime-leader-delete",
        )
        .await;
    query("UPDATE sessions SET leader_id = 'agent-leader-delete' WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("select source leader");
    let before = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile source leader")
        .team
        .expect("durable team before deletion");
    let leader_member_id = before.leader_member_id.expect("durable leader");

    query("DELETE FROM sessions WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("delete selected source Session");
    let after = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load detached team")
        .team
        .expect("durable team after deletion");
    assert_eq!(
        after.leader_member_id.as_deref(),
        Some(leader_member_id.as_str())
    );
}

#[tokio::test]
async fn dirty_leadership_blocks_raw_session_deletion() {
    let fixture = Fixture::new().await;
    let session_id = "session-dirty-leader-delete";
    let workspace_id = fixture
        .seed_workspace("project-dirty-leader-delete", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            "agent-first-leader",
            "acp",
            "acp-first-leader",
            "runtime-first-leader",
        )
        .await;
    fixture
        .seed_agent(
            session_id,
            "agent-second-leader",
            "acp",
            "acp-second-leader",
            "runtime-second-leader",
        )
        .await;
    query("UPDATE sessions SET leader_id = 'agent-first-leader' WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("select first source leader");
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile first source leader");
    query("UPDATE sessions SET leader_id = 'agent-second-leader' WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("change source leader without reconciliation");

    let error = query("DELETE FROM sessions WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect_err("dirty leadership must be reconciled before detachment");
    assert!(
        error
            .to_string()
            .contains("cannot detach Session before agent team reconciliation")
    );
}

#[tokio::test]
async fn codex_binding_disagreement_blocks_session_detachment() {
    let fixture = Fixture::new().await;
    let session_id = "session-codex-detach-conflict";
    fixture
        .seed_workspace("project-codex-detach-conflict", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            "agent-codex-detach-conflict",
            "codex",
            "run-codex-detach-conflict",
            "thread-registration",
        )
        .await;
    fixture
        .seed_codex(
            session_id,
            "run-codex-detach-conflict",
            "agent-codex-detach-conflict",
            "running",
        )
        .await;
    query(
        "UPDATE codex_runs SET thread_id = 'thread-runtime'
         WHERE run_id = 'run-codex-detach-conflict'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("seed contradictory Codex runtime binding");

    let error = query("DELETE FROM sessions WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect_err("contradictory Codex binding must block detachment");
    assert!(
        error
            .to_string()
            .contains("cannot detach Session with conflicting Codex runtime binding")
    );
}

#[tokio::test]
async fn empty_managed_identifier_detaches_as_readable_legacy_member() {
    let fixture = Fixture::new().await;
    let session_id = "session-empty-managed-id";
    let workspace_id = fixture
        .seed_workspace("project-empty-managed-id", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            "agent-empty-managed-id",
            "acp",
            "temporary-managed-id",
            "runtime-empty-managed-id",
        )
        .await;
    query("UPDATE agents SET managed_agent_id = '' WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("seed empty managed identifier");
    let reconciled = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile malformed legacy registration");
    assert!(
        reconciled.conflicts.is_empty(),
        "unexpected malformed registration conflict: {:?}",
        reconciled.conflicts
    );

    query("DELETE FROM sessions WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("detach malformed legacy registration");
    let stored = query_as::<_, (String, Option<String>, Option<String>)>(
        "SELECT member_id, managed_agent_kind, managed_agent_id
         FROM agent_workspace_members WHERE workspace_id = ?1",
    )
    .bind(&workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load preserved legacy member");
    assert!(stored.0.starts_with("member-l-"));
    assert_eq!(stored.1, None);
    assert_eq!(stored.2, None);
    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load readable detached team");
    assert!(response.conflicts.is_empty());
    assert_eq!(response.team.expect("detached team").members.len(), 1);
}

#[tokio::test]
async fn persisted_acp_disconnect_remains_recoverable_after_session_deletion() {
    let fixture = Fixture::new().await;
    let session_id = "session-acp-recoverable";
    let workspace_id = fixture
        .seed_workspace("project-acp-recoverable", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            "agent-acp-recoverable",
            "acp",
            "acp-recoverable",
            "runtime-acp-recoverable",
        )
        .await;
    let status = serde_json::to_string(&AgentStatus::Disconnected {
        reason: DisconnectReason::ProcessExited {
            code: Some(1),
            signal: None,
        },
        stderr_tail: Some("process exited".to_string()),
    })
    .expect("serialize recoverable ACP status");
    query("UPDATE agents SET status = ?2 WHERE session_id = ?1")
        .bind(session_id)
        .bind(&status)
        .execute(fixture.db.pool())
        .await
        .expect("seed recoverable ACP status");
    let before = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile recoverable ACP status")
        .team
        .expect("durable ACP team");
    assert_eq!(
        before.members[0].runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Recoverable
    );

    query("DELETE FROM sessions WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("delete recoverable ACP source Session");
    let after = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load detached recoverable ACP status")
        .team
        .expect("detached ACP team");
    assert_eq!(
        after.members[0].runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Recoverable
    );
    assert!(after.members[0].runtime_evidence.contains("process_exited"));
}

#[tokio::test]
async fn detached_member_can_be_removed_without_its_session() {
    let fixture = Fixture::new().await;
    let session_id = "session-detached-member-removal";
    let workspace_id = fixture
        .seed_workspace("project-detached-member-removal", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            "agent-detached-member-removal",
            "acp",
            "acp-detached-member-removal",
            "runtime-detached-member-removal",
        )
        .await;
    query("UPDATE sessions SET leader_id = ?2 WHERE session_id = ?1")
        .bind(session_id)
        .bind("agent-detached-member-removal")
        .execute(fixture.db.pool())
        .await
        .expect("select source leader");
    let before = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile durable member")
        .team
        .expect("durable team before Session deletion");
    let member = before.members.first().expect("durable member");
    let member_id = member.member_id.clone();
    assert_eq!(before.leader_member_id.as_deref(), Some(member_id.as_str()));
    let runtime_lifecycle = member.runtime_lifecycle;
    query("DELETE FROM sessions WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("detach source Session");

    let recorded = fixture
        .db
        .record_agent_workspace_member_removal(
            DAEMON_ID,
            &workspace_id,
            &member_id,
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("remove detached durable member");
    assert!(recorded);
    let after = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load removed durable member")
        .team
        .expect("durable team after removal");
    let member = after.members.first().expect("removed durable member");
    assert_eq!(
        member.membership_status,
        AgentWorkspaceMembershipStatus::Removed
    );
    assert_eq!(member.runtime_lifecycle, runtime_lifecycle);
    assert_eq!(member.recent_operations.len(), 1);
    assert!(after.leader_member_id.is_none());
}

#[tokio::test]
async fn selected_session_leader_removal_requires_leadership_transfer() {
    let fixture = Fixture::new().await;
    let session_id = "session-selected-leader-removal";
    let agent_id = "agent-selected-leader-removal";
    let workspace_id = fixture
        .seed_workspace("project-selected-leader-removal", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            agent_id,
            "acp",
            "acp-selected-leader-removal",
            "runtime-selected-leader-removal",
        )
        .await;
    query("UPDATE sessions SET leader_id = ?2 WHERE session_id = ?1")
        .bind(session_id)
        .bind(agent_id)
        .execute(fixture.db.pool())
        .await
        .expect("select source leader");
    let before = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile selected leader")
        .team
        .expect("durable selected team");
    let member_id = before.leader_member_id.expect("durable selected leader");

    let error = fixture
        .db
        .record_agent_workspace_member_removal(
            DAEMON_ID,
            &workspace_id,
            &member_id,
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect_err("selected Session leader removal must require transfer");
    assert!(
        error
            .message()
            .contains("cannot remove the durable team leader while a Session owns leadership")
    );
    let after = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load selected leader after rejected removal")
        .team
        .expect("durable selected team after rejection");
    assert_eq!(after.leader_member_id.as_deref(), Some(member_id.as_str()));
    assert_eq!(
        after.members[0].membership_status,
        AgentWorkspaceMembershipStatus::Joined
    );
    assert!(after.members[0].recent_operations.is_empty());
}
