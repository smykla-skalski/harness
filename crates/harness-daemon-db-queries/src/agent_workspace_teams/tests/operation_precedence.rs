use harness_protocol::daemon::summaries::{
    AgentWorkspaceMemberOperationOutcome, AgentWorkspaceMemberSummary,
    AgentWorkspaceMembershipStatus, AgentWorkspaceRuntimeLifecycle,
};
use harness_protocol::session::ManagedAgentKind;
use sqlx::query;

use super::super::{AsyncAgentWorkspaceTeamOperationQueries, AsyncAgentWorkspaceTeamQueries};
use super::support::{DAEMON_ID, Fixture, NOW};

#[tokio::test]
async fn membership_removal_ignores_unrelated_source_updates() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-operation-scope", "session-operation-scope")
        .await;
    for agent in ["target", "unrelated"] {
        fixture
            .seed_agent(
                "session-operation-scope",
                agent,
                "acp",
                &format!("acp-{agent}"),
                &format!("runtime-{agent}"),
            )
            .await;
    }
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable team");
    fixture
        .db
        .record_agent_workspace_membership_removal(
            DAEMON_ID,
            "session-operation-scope",
            "target",
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record target removal");
    query(
        "UPDATE agents SET status = '\"idle\"', updated_at = ?1
         WHERE session_id = 'session-operation-scope' AND agent_id = 'unrelated'",
    )
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("update unrelated registration");

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile unrelated source update");
    let target = response
        .team
        .expect("durable team")
        .members
        .into_iter()
        .find(|member| member.display_name == "target")
        .expect("target member");
    assert_eq!(
        target.membership_status,
        AgentWorkspaceMembershipStatus::Removed
    );
}

#[tokio::test]
async fn operations_materialize_a_team_before_its_first_read() {
    let fixture = Fixture::new().await;
    let session_id = "session-operation-first-read";
    let agent_id = "agent-operation-first-read";
    let tui_id = "tui-operation-first-read";
    let workspace_id = fixture
        .seed_workspace("project-operation-first-read", session_id)
        .await;
    fixture
        .seed_agent(session_id, agent_id, "tui", tui_id, "binding-first-read")
        .await;
    fixture
        .seed_tui(session_id, tui_id, agent_id, "running")
        .await;

    let stopped = fixture
        .db
        .record_agent_workspace_runtime_stop(
            DAEMON_ID,
            ManagedAgentKind::Tui,
            tui_id,
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record stop before first team read");
    let removed = fixture
        .db
        .record_agent_workspace_membership_removal(
            DAEMON_ID,
            session_id,
            agent_id,
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record removal before first team read");
    assert!(stopped);
    assert!(removed);

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("read materialized team");
    let member = &response.team.expect("durable team").members[0];
    assert_member_state(
        member,
        AgentWorkspaceMembershipStatus::Removed,
        AgentWorkspaceRuntimeLifecycle::Completed,
    );
    assert_eq!(member.recent_operations.len(), 2);
}

#[tokio::test]
async fn source_progress_preserves_durable_membership_removal() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-operation-progress", "session-operation-progress")
        .await;
    fixture
        .seed_agent(
            "session-operation-progress",
            "agent-operation-progress",
            "tui",
            "tui-operation-progress",
            "binding-operation-progress",
        )
        .await;
    fixture
        .seed_tui(
            "session-operation-progress",
            "tui-operation-progress",
            "agent-operation-progress",
            "running",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable team");
    fixture
        .db
        .record_agent_workspace_membership_removal(
            DAEMON_ID,
            "session-operation-progress",
            "agent-operation-progress",
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record membership removal");
    fixture
        .db
        .record_agent_workspace_runtime_stop(
            DAEMON_ID,
            ManagedAgentKind::Tui,
            "tui-operation-progress",
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record runtime stop");

    query(
        "UPDATE agents SET status = '\"idle\"', updated_at = ?1
         WHERE session_id = 'session-operation-progress'",
    )
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("advance membership source at same timestamp");
    let membership_progress = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile membership source progress");
    let member = &membership_progress.team.expect("durable team").members[0];
    assert_eq!(
        member.membership_status,
        AgentWorkspaceMembershipStatus::Removed
    );
    assert_eq!(
        member.runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Completed
    );

    query(
        "UPDATE agent_tuis SET status = 'starting', updated_at = ?1
         WHERE tui_id = 'tui-operation-progress'",
    )
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("advance runtime source at same timestamp");
    let runtime_progress = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile runtime source progress");
    let member = &runtime_progress.team.expect("durable team").members[0];
    assert_eq!(
        member.membership_status,
        AgentWorkspaceMembershipStatus::Removed
    );
    assert_eq!(
        member.runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Recoverable
    );
}

#[tokio::test]
async fn session_detachment_preserves_independent_operation_overrides() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-operation-detach", "session-operation-detach")
        .await;
    fixture
        .seed_agent(
            "session-operation-detach",
            "agent-operation-detach",
            "tui",
            "tui-operation-detach",
            "binding-operation-detach",
        )
        .await;
    fixture
        .seed_tui(
            "session-operation-detach",
            "tui-operation-detach",
            "agent-operation-detach",
            "running",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable team");
    fixture
        .db
        .record_agent_workspace_membership_removal(
            DAEMON_ID,
            "session-operation-detach",
            "agent-operation-detach",
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record membership removal");
    fixture
        .db
        .record_agent_workspace_runtime_stop(
            DAEMON_ID,
            ManagedAgentKind::Tui,
            "tui-operation-detach",
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record runtime stop");
    fixture.reconcile_activity(&workspace_id).await;

    query("DELETE FROM sessions WHERE session_id = 'session-operation-detach'")
        .execute(fixture.db.pool())
        .await
        .expect("delete legacy Session");
    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load detached team");
    let member = &response.team.expect("durable team").members[0];
    assert_eq!(
        member.membership_status,
        AgentWorkspaceMembershipStatus::Removed
    );
    assert_eq!(
        member.runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Completed
    );
}

#[tokio::test]
async fn source_disappearance_preserves_independent_operation_overrides() {
    let fixture = Fixture::new().await;
    let session_id = "session-operation-disappear";
    let agent_id = "agent-operation-disappear";
    let tui_id = "tui-operation-disappear";
    let workspace_id = fixture
        .seed_workspace("project-operation-disappear", session_id)
        .await;
    fixture
        .seed_agent(session_id, agent_id, "tui", tui_id, "binding-disappear")
        .await;
    fixture
        .seed_tui(session_id, tui_id, agent_id, "running")
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable team");
    fixture
        .db
        .record_agent_workspace_membership_removal(
            DAEMON_ID,
            session_id,
            agent_id,
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record membership removal");
    fixture
        .db
        .record_agent_workspace_runtime_stop(
            DAEMON_ID,
            ManagedAgentKind::Tui,
            tui_id,
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record runtime stop");

    query("DELETE FROM agents WHERE session_id = ?1 AND agent_id = ?2")
        .bind(session_id)
        .bind(agent_id)
        .execute(fixture.db.pool())
        .await
        .expect("delete registration source");
    query("DELETE FROM agent_tuis WHERE tui_id = ?1")
        .bind(tui_id)
        .execute(fixture.db.pool())
        .await
        .expect("delete runtime source");
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile missing sources");

    fixture
        .seed_agent(session_id, agent_id, "tui", tui_id, "binding-disappear")
        .await;
    fixture
        .seed_tui(session_id, tui_id, agent_id, "running")
        .await;
    let restored = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile unchanged restored sources");
    let member = &restored.team.expect("durable team").members[0];
    assert_member_state(
        member,
        AgentWorkspaceMembershipStatus::Removed,
        AgentWorkspaceRuntimeLifecycle::Completed,
    );

    query("UPDATE agents SET status = '\"idle\"' WHERE session_id = ?1 AND agent_id = ?2")
        .bind(session_id)
        .bind(agent_id)
        .execute(fixture.db.pool())
        .await
        .expect("advance restored membership source");
    query("UPDATE agent_tuis SET status = 'starting' WHERE tui_id = ?1")
        .bind(tui_id)
        .execute(fixture.db.pool())
        .await
        .expect("advance restored runtime source");
    let progressed = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile progressed restored sources");
    let member = &progressed.team.expect("durable team").members[0];
    assert_member_state(
        member,
        AgentWorkspaceMembershipStatus::Removed,
        AgentWorkspaceRuntimeLifecycle::Recoverable,
    );
}

#[tokio::test]
async fn runtime_stop_anchors_override_after_source_status_update() {
    let fixture = Fixture::new().await;
    let session_id = "session-operation-current-marker";
    let agent_id = "agent-operation-current-marker";
    let managed_id = "acp-operation-current-marker";
    let workspace_id = fixture
        .seed_workspace("project-operation-current-marker", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            agent_id,
            "acp",
            managed_id,
            "binding-operation-current-marker",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable team");
    query(
        "UPDATE agents
         SET status = '{\"state\":\"disconnected\",\"reason\":\"session_stopped\"}',
             updated_at = '2026-08-06T11:00:00Z'
         WHERE session_id = ?1 AND agent_id = ?2",
    )
    .bind(session_id)
    .bind(agent_id)
    .execute(fixture.db.pool())
    .await
    .expect("persist stopped ACP source status");

    fixture
        .db
        .record_agent_workspace_runtime_stop(
            DAEMON_ID,
            ManagedAgentKind::Acp,
            managed_id,
            AgentWorkspaceMemberOperationOutcome::Succeeded,
            None,
        )
        .await
        .expect("record stop against current source marker");
    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile stopped ACP source");
    let member = &response.team.expect("durable team").members[0];
    assert_eq!(
        member.runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Completed
    );
    assert_eq!(member.runtime_evidence, "runtime_stop_succeeded");
}

#[tokio::test]
async fn membership_removal_does_not_complete_acp_runtime() {
    let fixture = Fixture::new().await;
    let session_id = "session-membership-runtime-independent";
    let agent_id = "agent-membership-runtime-independent";
    let workspace_id = fixture
        .seed_workspace("project-membership-runtime-independent", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            agent_id,
            "acp",
            "acp-membership-runtime-independent",
            "runtime-membership-runtime-independent",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable ACP member");

    query("UPDATE agents SET status = '\"removed\"' WHERE session_id = ?1 AND agent_id = ?2")
        .bind(session_id)
        .bind(agent_id)
        .execute(fixture.db.pool())
        .await
        .expect("remove Session membership without stopping runtime");
    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile independent membership removal");
    let member = &response.team.expect("durable ACP team").members[0];
    assert_member_state(
        member,
        AgentWorkspaceMembershipStatus::Removed,
        AgentWorkspaceRuntimeLifecycle::Unavailable,
    );
    assert!(member.recent_operations.is_empty());
}

fn assert_member_state(
    member: &AgentWorkspaceMemberSummary,
    membership: AgentWorkspaceMembershipStatus,
    runtime: AgentWorkspaceRuntimeLifecycle,
) {
    assert_eq!(member.membership_status, membership);
    assert_eq!(member.runtime_lifecycle, runtime);
}
