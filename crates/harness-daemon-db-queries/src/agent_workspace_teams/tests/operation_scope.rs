use harness_protocol::daemon::summaries::{
    AgentWorkspaceMemberOperationOutcome, AgentWorkspaceMembershipStatus,
    AgentWorkspaceRuntimeLifecycle,
};
use harness_protocol::session::ManagedAgentKind;

use crate::AsyncAgentWorkspaceQueries;

use super::super::{AsyncAgentWorkspaceTeamOperationQueries, AsyncAgentWorkspaceTeamQueries};
use super::support::{DAEMON_ID, Fixture};

#[tokio::test]
async fn operations_are_scoped_to_one_daemon_projection() {
    const OTHER_DAEMON_ID: &str = "daemon-team-test-other";

    let fixture = Fixture::new().await;
    let session_id = "session-multi-daemon-operation";
    let agent_id = "agent-multi-daemon-operation";
    let tui_id = "tui-multi-daemon-operation";
    let workspace_id = fixture
        .seed_workspace("project-multi-daemon-operation", session_id)
        .await;
    fixture
        .seed_agent(session_id, agent_id, "tui", tui_id, "binding-multi-daemon")
        .await;
    fixture
        .seed_tui(session_id, tui_id, agent_id, "running")
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("create first daemon team");
    let other_workspace_id = fixture
        .db
        .reconcile_agent_workspaces(OTHER_DAEMON_ID)
        .await
        .expect("create second daemon projection")
        .workspaces[0]
        .workspace_id
        .clone();
    let other_before = fixture
        .db
        .reconcile_agent_workspace_team(OTHER_DAEMON_ID, &other_workspace_id)
        .await
        .expect("create second daemon team")
        .team
        .expect("second daemon team");
    let other_member_id = other_before.members[0].member_id.clone();

    assert!(
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
            .expect("stop runtime in first daemon projection")
    );
    assert!(
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
            .expect("remove membership in first daemon projection")
    );
    assert!(
        !fixture
            .db
            .record_agent_workspace_member_removal(
                DAEMON_ID,
                &other_workspace_id,
                &other_member_id,
                AgentWorkspaceMemberOperationOutcome::Succeeded,
                None,
            )
            .await
            .expect("reject second daemon workspace identity")
    );

    let first = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("load first daemon team")
        .team
        .expect("first daemon team");
    assert_member_state(
        &first.members[0],
        AgentWorkspaceMembershipStatus::Removed,
        AgentWorkspaceRuntimeLifecycle::Completed,
    );
    let other = fixture
        .db
        .reconcile_agent_workspace_team(OTHER_DAEMON_ID, &other_workspace_id)
        .await
        .expect("load untouched second daemon team")
        .team
        .expect("second daemon team");
    assert_member_state(
        &other.members[0],
        AgentWorkspaceMembershipStatus::Joined,
        AgentWorkspaceRuntimeLifecycle::Recoverable,
    );
    assert!(other.members[0].recent_operations.is_empty());
}

fn assert_member_state(
    member: &harness_protocol::daemon::summaries::AgentWorkspaceMemberSummary,
    membership: AgentWorkspaceMembershipStatus,
    runtime: AgentWorkspaceRuntimeLifecycle,
) {
    assert_eq!(member.membership_status, membership);
    assert_eq!(member.runtime_lifecycle, runtime);
}
