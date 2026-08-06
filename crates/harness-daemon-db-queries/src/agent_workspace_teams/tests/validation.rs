use harness_protocol::daemon::summaries::AgentWorkspaceTeamConflictKind;
use sqlx::query;

use super::super::AsyncAgentWorkspaceTeamQueries;
use super::support::{DAEMON_ID, Fixture};

#[tokio::test]
async fn malformed_registration_values_report_conflicts_before_persistence() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-malformed-source", "session-malformed-source")
        .await;
    fixture
        .seed_agent(
            "session-malformed-source",
            "agent-malformed-source",
            "acp",
            "acp-malformed-source",
            "runtime-malformed-source",
        )
        .await;

    for (column, value) in [("managed_agent_kind", "unknown"), ("role", "unknown")] {
        let statement: &'static str = match column {
            "managed_agent_kind" => {
                "UPDATE agents SET managed_agent_kind = ?1
                 WHERE session_id = 'session-malformed-source'"
            }
            "role" => {
                "UPDATE agents SET role = ?1
                 WHERE session_id = 'session-malformed-source'"
            }
            _ => unreachable!(),
        };
        query(statement)
            .bind(value)
            .execute(fixture.db.pool())
            .await
            .expect("corrupt registration source");
        let response = fixture
            .db
            .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
            .await
            .expect("report malformed registration source");
        assert_eq!(response.conflicts.len(), 1);
        assert_eq!(
            response.conflicts[0].kind,
            AgentWorkspaceTeamConflictKind::MalformedSource
        );
        assert!(
            response
                .team
                .expect("unchanged durable team")
                .members
                .is_empty()
        );
        query(
            "UPDATE agents SET managed_agent_kind = 'acp', role = 'worker'
             WHERE session_id = 'session-malformed-source'",
        )
        .execute(fixture.db.pool())
        .await
        .expect("restore registration source");
    }
}

#[tokio::test]
async fn malformed_runtime_status_identifies_its_legacy_source() {
    for family in ["tui", "codex"] {
        let fixture = Fixture::new().await;
        let session_id = format!("session-malformed-{family}");
        let workspace_id = fixture
            .seed_workspace(&format!("project-malformed-{family}"), &session_id)
            .await;
        match family {
            "tui" => {
                fixture
                    .seed_tui(&session_id, "runtime-malformed-tui", "", "unknown")
                    .await;
            }
            "codex" => {
                fixture
                    .seed_codex(&session_id, "runtime-malformed-codex", "", "unknown")
                    .await;
            }
            _ => unreachable!(),
        }

        let response = fixture
            .db
            .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
            .await
            .expect("report malformed runtime source");
        assert_eq!(response.conflicts.len(), 1);
        assert_eq!(
            response.conflicts[0].kind,
            AgentWorkspaceTeamConflictKind::MalformedSource
        );
        assert_eq!(response.conflicts[0].legacy_session_ids, vec![session_id]);
    }
}

#[tokio::test]
async fn codex_registration_and_runtime_binding_disagreement_is_a_conflict() {
    let fixture = Fixture::new().await;
    let session_id = "session-codex-binding-conflict";
    let workspace_id = fixture
        .seed_workspace("project-codex-binding-conflict", session_id)
        .await;
    fixture
        .seed_agent(
            session_id,
            "agent-codex-binding-conflict",
            "codex",
            "run-binding-conflict",
            "thread-registration",
        )
        .await;
    fixture
        .seed_codex(
            session_id,
            "run-binding-conflict",
            "agent-codex-binding-conflict",
            "running",
        )
        .await;
    query(
        "UPDATE codex_runs SET thread_id = 'thread-runtime'
         WHERE run_id = 'run-binding-conflict'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("seed contradictory Codex runtime binding");

    let response = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("report contradictory Codex binding");
    assert_eq!(response.conflicts.len(), 1);
    assert_eq!(
        response.conflicts[0].kind,
        AgentWorkspaceTeamConflictKind::IdentityCollision
    );
    assert!(
        response.conflicts[0]
            .detail
            .contains("conflicting bindings 'thread-registration' and 'thread-runtime'")
    );
}
