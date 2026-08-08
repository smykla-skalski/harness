use harness_protocol::daemon::summaries::{
    AgentWorkspaceMemberOperationOutcome, AgentWorkspaceMembershipStatus,
};
use sqlx::{query, query_scalar};

use super::super::{AsyncAgentWorkspaceTeamOperationQueries, AsyncAgentWorkspaceTeamQueries};
use super::support::{DAEMON_ID, Fixture};

#[tokio::test]
async fn session_deletion_preserves_removal_after_source_progress() {
    let fixture = Fixture::new().await;
    let session_id = "session-remove-progress-delete";
    let agent_id = "agent-remove-progress-delete";
    let workspace_id = fixture
        .seed_workspace("project-remove-progress-delete", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            agent_id,
            "acp",
            "acp-remove-progress-delete",
            "runtime-remove-progress-delete",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable member before removal");
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
        .expect("record durable membership removal");
    query(
        "UPDATE agents SET status = '\"idle\"', updated_at = '2026-08-06T11:00:00Z'
         WHERE session_id = ?1 AND agent_id = ?2",
    )
    .bind(session_id)
    .bind(agent_id)
    .execute(fixture.db.pool())
    .await
    .expect("advance source after durable removal");
    let progressed = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile progressed removal")
        .team
        .expect("durable team after source progress");
    assert_eq!(
        progressed.members[0].membership_status,
        AgentWorkspaceMembershipStatus::Removed
    );
    fixture.reconcile_activity(&workspace_id).await;

    query("DELETE FROM sessions WHERE session_id = ?1")
        .bind(session_id)
        .execute(fixture.db.pool())
        .await
        .expect("delete progressed source Session");
    let detached = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load detached removal")
        .team
        .expect("detached durable team");
    assert_eq!(
        detached.members[0].membership_status,
        AgentWorkspaceMembershipStatus::Removed
    );
    let override_marker = query_scalar::<_, Option<String>>(
        "SELECT membership_override_source_digest
         FROM agent_workspace_members WHERE workspace_id = ?1",
    )
    .bind(&workspace_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load detached membership override");
    assert!(override_marker.is_some());
}
