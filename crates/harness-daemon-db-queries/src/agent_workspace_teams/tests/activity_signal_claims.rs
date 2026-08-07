use super::super::AsyncAgentWorkspaceTeamQueries;
use super::support::{DAEMON_ID, Fixture, NOW};
use crate::AsyncAgentWorkspaceActivityQueries;

#[tokio::test]
async fn signal_wake_claim_is_a_tokenized_lease() {
    let fixture = Fixture::new().await;
    let workspace_id = fixture
        .seed_workspace("project-signal-wake-claim", "session-signal-wake-claim")
        .await;
    fixture
        .seed_agent(
            "session-signal-wake-claim",
            "agent-signal-wake-claim",
            "codex",
            "run-signal-wake-claim",
            "thread-signal-wake-claim",
        )
        .await;
    let member_id = fixture
        .db
        .reconcile_agent_workspace_team(DAEMON_ID, &workspace_id)
        .await
        .expect("reconcile signal wake member")
        .team
        .expect("durable team")
        .members[0]
        .member_id
        .clone();
    let signal = harness_session::service::build_signal(
        "test",
        "continue",
        "continue work",
        None,
        &workspace_id,
        &member_id,
        NOW,
    );
    fixture
        .db
        .insert_agent_workspace_signal(DAEMON_ID, &workspace_id, &member_id, "codex", &signal)
        .await
        .expect("insert signal for wake claim");

    assert_tokenized_lease(&fixture, &workspace_id, &member_id, &signal.signal_id).await;
}

async fn assert_tokenized_lease(
    fixture: &Fixture,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
) {
    let first = "2026-08-06T12:00:00Z";
    let active_retry = "2026-08-06T12:00:01Z";
    let reclaimed = "2026-08-06T12:00:31Z";
    assert!(claim(fixture, workspace_id, member_id, signal_id, first).await);
    assert!(!claim(fixture, workspace_id, member_id, signal_id, active_retry).await);
    assert!(claim(fixture, workspace_id, member_id, signal_id, reclaimed).await);
    release(fixture, workspace_id, member_id, signal_id, first).await;
    assert!(
        !claim(
            fixture,
            workspace_id,
            member_id,
            signal_id,
            "2026-08-06T12:00:32Z",
        )
        .await
    );
    release(fixture, workspace_id, member_id, signal_id, reclaimed).await;
    sqlx::query(
        "UPDATE agent_workspace_signals
         SET signal_json = json_set(signal_json, '$.expires_at', '2000-01-01T00:00:00Z')
         WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
    )
    .bind(workspace_id)
    .bind(member_id)
    .bind(signal_id)
    .execute(fixture.db.pool())
    .await
    .expect("expire signal before a later wake claim");
    assert!(
        !claim(
            fixture,
            workspace_id,
            member_id,
            signal_id,
            "2026-08-06T13:00:00Z",
        )
        .await
    );
}

async fn claim(
    fixture: &Fixture,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
    claimed_at: &str,
) -> bool {
    fixture
        .db
        .claim_agent_workspace_signal_wake(
            DAEMON_ID,
            workspace_id,
            member_id,
            signal_id,
            claimed_at,
        )
        .await
        .expect("claim native signal wake")
}

async fn release(
    fixture: &Fixture,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
    claimed_at: &str,
) {
    fixture
        .db
        .release_agent_workspace_signal_wake(
            DAEMON_ID,
            workspace_id,
            member_id,
            signal_id,
            claimed_at,
        )
        .await
        .expect("release native signal wake");
}
