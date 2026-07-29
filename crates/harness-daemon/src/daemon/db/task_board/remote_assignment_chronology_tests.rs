use sqlx::query;

use super::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_test_support::{
    CLAIMED_AT, INSTANCE, PRINCIPAL, accept_executor, claim_request, executor_fixture,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn executor_start_before_the_durable_claim_is_rejected_without_mutation() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    let claim = claim_request(&fixture.request, &accepted);
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(&claim, PRINCIPAL, CLAIMED_AT)
            .await
            .expect("claim assignment"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));

    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_start_authority(
                &fixture.request.binding.assignment_id,
                INSTANCE,
                "2026-07-19T10:00:09Z",
            )
            .await
            .expect("reject early executor start authority")
            .is_none()
    );

    let unchanged = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("reload assignment")
        .expect("assignment exists");
    assert_eq!(unchanged.state, TaskBoardRemoteAssignmentState::Claimed);
    assert_eq!(unchanged.claimed_at.as_deref(), Some(CLAIMED_AT));
    assert!(unchanged.started_at.is_none());
    assert!(unchanged.workspace_ref.is_none());
}

#[tokio::test]
async fn malformed_and_noncanonical_persisted_times_fail_closed_on_load() {
    for claimed_at in ["not-a-time", "2026-07-19T10:00:10+00:00"] {
        let fixture = executor_fixture(1).await;
        let accepted = accept_executor(&fixture, &fixture.request).await;
        let claim = claim_request(&fixture.request, &accepted);
        fixture
            .db
            .claim_task_board_remote_assignment(&claim, PRINCIPAL, CLAIMED_AT)
            .await
            .expect("claim assignment");
        let corruption = query(
            "UPDATE task_board_remote_assignments SET claimed_at = ?2
             WHERE assignment_id = ?1",
        )
        .bind(&fixture.request.binding.assignment_id)
        .bind(claimed_at)
        .execute(fixture.db.pool())
        .await;
        match corruption {
            Err(error) => assert!(error.to_string().contains("CHECK constraint failed")),
            Ok(_) => {
                let error = fixture
                    .db
                    .task_board_remote_assignment(&fixture.request.binding.assignment_id)
                    .await
                    .expect_err("noncanonical persisted time must fail closed");
                assert!(
                    error
                        .to_string()
                        .contains("durable remote assignment claim time")
                );
            }
        }
    }
}

#[tokio::test]
async fn persisted_start_before_claim_fails_closed_on_load() {
    let fixture = executor_fixture(1).await;
    let accepted = accept_executor(&fixture, &fixture.request).await;
    let claim = claim_request(&fixture.request, &accepted);
    fixture
        .db
        .claim_task_board_remote_assignment(&claim, PRINCIPAL, CLAIMED_AT)
        .await
        .expect("claim assignment");
    // Null the executor settings so the started row persists without a start
    // receipt (the v43 CHECK needs config_revision null or a receipt sha) and
    // keeps the both-or-neither settings-evidence invariant intact; load then
    // reaches the chronology guard on the reversed start/claim times.
    query(
        "UPDATE task_board_remote_assignments
         SET state = 'started', started_at = ?2, workspace_ref = ?3,
             executor_configuration_revision = NULL, executor_checkout_path = NULL
         WHERE assignment_id = ?1",
    )
    .bind(&fixture.request.binding.assignment_id)
    .bind("2026-07-19T10:00:09Z")
    .bind("workspace-with-reversed-evidence")
    .execute(fixture.db.pool())
    .await
    .expect("corrupt durable start chronology");

    let error = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect_err("reversed persisted chronology must fail closed");
    assert!(error.to_string().contains("start time precedes claim time"));
}
