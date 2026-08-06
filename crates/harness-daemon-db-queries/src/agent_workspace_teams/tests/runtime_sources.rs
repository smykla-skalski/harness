use harness_protocol::daemon::summaries::AgentWorkspaceRuntimeLifecycle;
use sqlx::query;

use super::super::AsyncAgentWorkspaceTeamQueries;
use super::support::{DAEMON_ID, Fixture};

#[tokio::test]
async fn deleting_runtime_sources_retires_stale_runtime_evidence() {
    let fixture = Fixture::new().await;

    for (family, session_id, managed_id) in [
        ("tui", "session-delete-tui", "runtime-delete-tui"),
        ("codex", "session-delete-codex", "runtime-delete-codex"),
    ] {
        let workspace_id = fixture
            .seed_workspace(&format!("project-delete-{family}"), session_id)
            .await;
        fixture
            .seed_agent(
                session_id,
                &format!("agent-delete-{family}"),
                family,
                managed_id,
                &format!("binding-delete-{family}"),
            )
            .await;
        match family {
            "tui" => {
                fixture
                    .seed_tui(session_id, managed_id, "", "running")
                    .await;
            }
            "codex" => {
                fixture
                    .seed_codex(session_id, managed_id, "agent-delete-codex", "running")
                    .await;
            }
            _ => unreachable!(),
        }
        let initial = fixture
            .db
            .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
            .await
            .expect("reconcile runtime source");
        assert_eq!(
            initial.team.expect("durable team").members[0].runtime_lifecycle,
            AgentWorkspaceRuntimeLifecycle::Recoverable
        );

        let statement: &'static str = if family == "tui" {
            "DELETE FROM agent_tuis WHERE tui_id = ?1"
        } else {
            "DELETE FROM codex_runs WHERE run_id = ?1"
        };
        query(statement)
            .bind(managed_id)
            .execute(fixture.db.pool())
            .await
            .expect("delete runtime source");
        let reconciled = fixture
            .db
            .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
            .await
            .expect("reconcile deleted runtime source");
        assert_eq!(
            reconciled.team.expect("durable team").members[0].runtime_lifecycle,
            AgentWorkspaceRuntimeLifecycle::Unavailable
        );
    }
}

#[tokio::test]
async fn deleting_unregistered_runtime_marks_member_unavailable() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-delete-unregistered", "session-delete-unregistered")
        .await;
    fixture
        .seed_tui(
            "session-delete-unregistered",
            "tui-delete-unregistered",
            "",
            "running",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile pending runtime");

    query("DELETE FROM agent_tuis WHERE tui_id = 'tui-delete-unregistered'")
        .execute(fixture.db.pool())
        .await
        .expect("delete pending runtime source");
    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile deleted pending runtime");
    let member = &response.team.expect("durable team").members[0];
    assert_eq!(
        member.runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Unavailable
    );
    assert_eq!(member.runtime_evidence, "source_missing");
}

#[tokio::test]
async fn deleting_registration_does_not_make_existing_runtime_pending() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-delete-registration", "session-delete-registration")
        .await;
    fixture
        .seed_agent(
            "session-delete-registration",
            "agent-delete-registration",
            "tui",
            "tui-delete-registration",
            "binding-delete-registration",
        )
        .await;
    fixture
        .seed_tui(
            "session-delete-registration",
            "tui-delete-registration",
            "agent-delete-registration",
            "running",
        )
        .await;
    fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile registered runtime");

    query(
        "DELETE FROM agents
         WHERE session_id = 'session-delete-registration'
           AND agent_id = 'agent-delete-registration'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("delete runtime registration");
    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile deleted registration");
    let member = &response.team.expect("durable team").members[0];
    assert_eq!(
        member.membership_status,
        harness_protocol::daemon::summaries::AgentWorkspaceMembershipStatus::Removed
    );
    assert_eq!(
        member.runtime_lifecycle,
        AgentWorkspaceRuntimeLifecycle::Recoverable
    );

    query(
        "UPDATE agent_tuis SET status = 'starting'
         WHERE tui_id = 'tui-delete-registration'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("advance surviving runtime source");
    let repeated = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile surviving runtime progress");
    assert_eq!(
        repeated.team.expect("durable team").members[0].membership_status,
        harness_protocol::daemon::summaries::AgentWorkspaceMembershipStatus::Removed
    );
}
