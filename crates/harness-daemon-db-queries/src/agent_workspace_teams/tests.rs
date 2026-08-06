use harness_protocol::daemon::summaries::{
    AgentWorkspaceLivenessStatus, AgentWorkspaceMemberOperationKind,
    AgentWorkspaceMemberOperationOutcome, AgentWorkspaceMemberSummary,
    AgentWorkspaceMembershipStatus, AgentWorkspaceRuntimeLifecycle, AgentWorkspaceTeamAuthority,
    AgentWorkspaceTeamConflictKind,
};
use harness_protocol::session::ManagedAgentKind;
use sqlx::{query, query_scalar};

use super::{AsyncAgentWorkspaceTeamOperationQueries, AsyncAgentWorkspaceTeamQueries};
use crate::AsyncAgentWorkspaceQueries;

mod activity;
mod activity_streams;
mod deletion_safety;
mod operation_precedence;
mod operation_scope;
mod reconciliation;
mod removal_durability;
mod runtime_sources;
mod support;
mod validation;

use support::{DAEMON_ID, Fixture, NOW};

#[tokio::test]
async fn delayed_terminal_registration_enriches_one_stable_member() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-delayed", "session-delayed")
        .await;
    fixture
        .seed_tui("session-delayed", "tui-1", "", "running")
        .await;

    let pending = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile pending terminal");
    let pending_team = pending.team.expect("durable team");
    assert_eq!(
        pending_team.authority,
        AgentWorkspaceTeamAuthority::Workspace
    );
    assert_eq!(pending_team.members.len(), 1);
    let member_id = pending_team.members[0].member_id.clone();
    assert_eq!(
        pending_team.members[0].membership_status,
        AgentWorkspaceMembershipStatus::PendingRegistration
    );
    assert_eq!(
        pending_team.members[0].runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Recoverable
    );

    fixture
        .seed_agent(
            "session-delayed",
            "agent-1",
            "tui",
            "tui-1",
            "runtime-session-1",
        )
        .await;
    query("UPDATE sessions SET leader_id = 'agent-1' WHERE session_id = 'session-delayed'")
        .execute(fixture.db.pool())
        .await
        .expect("select leader");
    let joined = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile joined terminal");
    let joined_team = joined.team.expect("joined durable team");
    assert_eq!(joined_team.members.len(), 1);
    assert_eq!(joined_team.members[0].member_id, member_id);
    assert_eq!(
        joined_team.leader_member_id.as_deref(),
        Some(member_id.as_str())
    );
    assert_eq!(
        joined_team.members[0].membership_status,
        AgentWorkspaceMembershipStatus::Joined
    );
    assert_eq!(
        joined_team.members[0].liveness_status,
        AgentWorkspaceLivenessStatus::Active
    );
}

#[tokio::test]
async fn runtime_family_qualifies_equal_native_identifiers() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-family", "session-family")
        .await;
    fixture
        .seed_agent(
            "session-family",
            "terminal-agent",
            "tui",
            "shared-id",
            "terminal-session",
        )
        .await;
    fixture
        .seed_agent(
            "session-family",
            "codex-agent",
            "codex",
            "shared-id",
            "codex-session",
        )
        .await;

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile qualified identities");
    let team = response.team.expect("durable team");
    assert!(response.conflicts.is_empty());
    assert_eq!(team.members.len(), 2);
    assert_ne!(team.members[0].member_id, team.members[1].member_id);
    assert_ne!(
        team.members[0]
            .managed_identity
            .as_ref()
            .map(|identity| identity.kind),
        team.members[1]
            .managed_identity
            .as_ref()
            .map(|identity| identity.kind)
    );
}

#[tokio::test]
async fn conflicting_runtime_bindings_block_reconciliation_without_guessing() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-collision");
    fixture.seed_project(&project).await;
    fixture
        .seed_session(&project, "session-current", "active", NOW)
        .await;
    fixture
        .seed_session(&project, "session-old", "ended", "2026-08-05T10:00:00Z")
        .await;
    fixture
        .seed_agent(
            "session-current",
            "current-agent",
            "codex",
            "run-shared",
            "thread-current",
        )
        .await;
    fixture
        .seed_agent(
            "session-old",
            "old-agent",
            "codex",
            "run-shared",
            "thread-old",
        )
        .await;
    let workspaces = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("reconcile workspace identity");
    let workspace_id = &workspaces.workspaces[0].workspace_id;

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, workspace_id)
        .await
        .expect("report identity collision");
    assert_eq!(response.conflicts.len(), 1);
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceTeamConflictKind::IdentityCollision
    );
    assert_eq!(response.conflicts[0].legacy_session_ids.len(), 2);
}

#[tokio::test]
async fn session_delete_preserves_latest_team_and_runtime_binding() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-delete", "session-delete")
        .await;
    fixture
        .seed_agent(
            "session-delete",
            "agent-delete",
            "acp",
            "acp-delete",
            "runtime-delete",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile latest runtime binding");

    query("DELETE FROM sessions WHERE session_id = 'session-delete'")
        .execute(fixture.db.pool())
        .await
        .expect("delete legacy Session");
    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load detached durable team");
    let team = response.team.expect("detached durable team");
    assert!(response.conflicts.is_empty());
    assert_eq!(team.authority, AgentWorkspaceTeamAuthority::Workspace);
    assert_eq!(team.members.len(), 1);
    assert_eq!(team.members[0].display_name, "agent-delete");
    assert_eq!(
        team.members[0].runtime_session_id.as_deref(),
        Some("runtime-delete")
    );
    assert_eq!(
        team.members[0].membership_status,
        AgentWorkspaceMembershipStatus::Joined
    );
    assert_eq!(
        team.members[0].runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Unavailable
    );
    let source_exists = query_scalar::<_, i64>(
        "SELECT EXISTS (SELECT 1 FROM sessions WHERE session_id = 'session-delete')",
    )
    .fetch_one(fixture.db.pool())
    .await
    .expect("inspect deleted Session");
    assert_eq!(source_exists, 0);
}

#[tokio::test]
async fn durable_team_tampering_is_reported_without_overwrite() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-tamper", "session-tamper")
        .await;
    fixture
        .seed_agent(
            "session-tamper",
            "agent-tamper",
            "acp",
            "acp-tamper",
            "runtime-tamper",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable member");
    query(
        "UPDATE agent_workspace_members SET display_name = 'tampered'
         WHERE workspace_id = ?1",
    )
    .bind(&workspace_id)
    .execute(fixture.db.pool())
    .await
    .expect("tamper durable team");

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("report shadow mismatch");
    assert_eq!(response.conflicts.len(), 1);
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceTeamConflictKind::SourceDisagreement
    );
    assert_eq!(
        response.team.expect("unchanged team").members[0].display_name,
        "tampered"
    );
}

#[tokio::test]
async fn durable_team_authority_tampering_is_reported() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-authority-tamper", "session-authority-tamper")
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable team");
    query(
        "UPDATE agent_workspace_teams SET authority = 'legacy_session'
         WHERE workspace_id = ?1",
    )
    .bind(&workspace_id)
    .execute(fixture.db.pool())
    .await
    .expect("tamper team authority");

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("report authority mismatch");
    assert_eq!(response.conflicts.len(), 1);
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceTeamConflictKind::SourceDisagreement
    );
}

#[tokio::test]
async fn runtime_stop_and_membership_removal_record_independent_results() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-operations", "session-operations")
        .await;
    fixture
        .seed_agent(
            "session-operations",
            "agent-operations",
            "acp",
            "acp-operations",
            "runtime-operations",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create durable operation target");

    assert!(
        fixture
            .db
            .record_agent_workspace_runtime_stop(
                DAEMON_ID,
                ManagedAgentKind::Acp,
                "acp-operations",
                AgentWorkspaceMemberOperationOutcome::Succeeded,
                None,
            )
            .await
            .expect("record runtime stop")
    );
    assert!(
        fixture
            .db
            .record_agent_workspace_membership_removal(
                DAEMON_ID,
                "session-operations",
                "agent-operations",
                AgentWorkspaceMemberOperationOutcome::Failed,
                Some("leave signal was rejected"),
            )
            .await
            .expect("record membership failure")
    );

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load independent operation results");
    let member = &response.team.expect("durable team").members[0];
    assert_independent_operation_results(member);

    assert!(
        fixture
            .db
            .record_agent_workspace_membership_removal(
                DAEMON_ID,
                "session-operations",
                "agent-operations",
                AgentWorkspaceMemberOperationOutcome::Failed,
                Some("second rejection in the same second"),
            )
            .await
            .expect("record second membership failure")
    );
    let repeated = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load repeated operation results");
    assert_eq!(
        repeated.team.expect("durable team").members[0]
            .recent_operations
            .len(),
        3
    );
}

fn assert_independent_operation_results(member: &AgentWorkspaceMemberSummary) {
    assert_eq!(
        member.runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Completed
    );
    assert_eq!(
        member.membership_status,
        AgentWorkspaceMembershipStatus::Joined
    );
    assert_eq!(member.recent_operations.len(), 2);
    assert!(member.recent_operations.iter().any(|operation| {
        operation.kind == AgentWorkspaceMemberOperationKind::RuntimeStop
            && operation.outcome == AgentWorkspaceMemberOperationOutcome::Succeeded
    }));
    assert!(member.recent_operations.iter().any(|operation| {
        operation.kind == AgentWorkspaceMemberOperationKind::MembershipRemove
            && operation.outcome == AgentWorkspaceMemberOperationOutcome::Failed
    }));
    let runtime_stop = member
        .recent_operations
        .iter()
        .find(|operation| operation.kind == AgentWorkspaceMemberOperationKind::RuntimeStop)
        .expect("runtime stop result");
    assert_eq!(runtime_stop.before_state, "unavailable");
    assert_eq!(runtime_stop.after_state, "completed");
    let membership_remove = member
        .recent_operations
        .iter()
        .find(|operation| operation.kind == AgentWorkspaceMemberOperationKind::MembershipRemove)
        .expect("membership removal result");
    assert_eq!(membership_remove.before_state, "joined");
    assert_eq!(membership_remove.after_state, "joined");
}
