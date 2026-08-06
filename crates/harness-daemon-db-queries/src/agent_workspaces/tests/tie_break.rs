use super::*;

#[tokio::test]
async fn pre_session_turn_run_does_not_abort_reconciliation() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-pre-session-run", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-existing",
        "active",
        NOW,
        false,
    )
    .await;
    query(
        "INSERT INTO agent_turn_runs (
            run_id, session_id, requested_runtime, status, created_at, updated_at
         ) VALUES ('run-before-session', NULL, 'openrouter', 'queued', ?1, ?1)",
    )
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("seed turn before its Session");

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("ignore uncorrelated turn activity");
    assert!(response.conflicts.is_empty());
    assert_eq!(response.workspaces.len(), 1);
}

#[tokio::test]
async fn stale_tie_uses_unsigned_session_id_byte_order() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-tie", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-a",
        "active",
        NOW,
        false,
    )
    .await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-z",
        "active",
        NOW,
        false,
    )
    .await;

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("select stale candidate");
    assert!(response.conflicts.is_empty());
    assert_eq!(
        response.workspaces[0]
            .provenance
            .selected_legacy_session_id
            .as_deref(),
        Some("session-z")
    );
}

#[tokio::test]
async fn stale_tie_compares_timestamp_instants_before_session_ids() {
    let fixture = Fixture::new().await;
    let project = fixture.project("project-offset-tie", true);
    seed_project(fixture.db.pool(), &project).await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-z",
        "active",
        "2026-08-06T10:00:00+02:00",
        false,
    )
    .await;
    seed_session(
        fixture.db.pool(),
        &project,
        "session-a",
        "active",
        "2026-08-06T09:00:00Z",
        false,
    )
    .await;
    for session_id in ["session-z", "session-a"] {
        query(
            "INSERT INTO tasks (
                task_id, session_id, title, severity, status, created_at, updated_at
             ) VALUES (?1, ?2, 'completed task', 'info', 'completed', ?3, ?3)",
        )
        .bind(format!("task-{session_id}"))
        .bind(session_id)
        .bind("2026-08-06T12:00:00Z")
        .execute(fixture.db.pool())
        .await
        .expect("seed equal later activity");
    }

    let response = fixture
        .db
        .reconcile_agent_workspaces(DAEMON_ID)
        .await
        .expect("select candidate by timestamp instant");
    assert!(response.conflicts.is_empty());
    assert_eq!(
        response.workspaces[0]
            .provenance
            .selected_legacy_session_id
            .as_deref(),
        Some("session-a")
    );
}
