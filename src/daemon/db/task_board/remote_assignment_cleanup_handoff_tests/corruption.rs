use super::*;

#[tokio::test]
async fn cleanup_handoff_bypasses_an_undecodable_parent_but_no_handoff_fails_closed() {
    let fixture = controller_fixture(1).await;
    let superseded = superseded_detached_controller_assignment(&fixture).await;
    record_pending_cleanup_handoff(&fixture, &superseded).await;
    let settlement = settle_controller_assignment(&fixture, &superseded).await;
    let cleanup =
        RemoteCleanupObservationRequest::for_settlement(&settlement).expect("seal cleanup request");
    let response = RemoteCleanupObservationResponse::for_completed(&cleanup, CLEANED_AT.into())
        .expect("seal cleanup response");
    let trust = fixture
        .db
        .task_board_remote_host_trust_fence(HOST)
        .await
        .expect("load cleanup trust");
    corrupt_parent_json(&fixture).await;
    assert!(
        fixture
            .db
            .claim_task_board_remote_cleanup_observation_fenced(&cleanup, HOST, &trust)
            .await
            .expect("claim cleanup without decoding an immutable-handoff parent")
            .is_none()
    );
    assert!(matches!(
        fixture
            .db
            .record_task_board_remote_cleanup_observation(&cleanup, &response, HOST, &trust)
            .await
            .expect("record cleanup without decoding an immutable-handoff parent"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));

    for missing_parent in [false, true] {
        let fixture = controller_fixture(1).await;
        let superseded = superseded_detached_controller_assignment(&fixture).await;
        record_pending_cleanup_handoff(&fixture, &superseded).await;
        let settlement = settle_controller_assignment(&fixture, &superseded).await;
        let cleanup = RemoteCleanupObservationRequest::for_settlement(&settlement)
            .expect("seal no-handoff cleanup request");
        let trust = fixture
            .db
            .task_board_remote_host_trust_fence(HOST)
            .await
            .expect("load no-handoff cleanup trust");
        clear_handoff_for_explicit_corruption(&fixture, &superseded.assignment_id).await;
        if missing_parent {
            query("DELETE FROM task_board_workflow_executions WHERE execution_id = ?1")
                .bind(&fixture.execution.execution_id)
                .execute(fixture.db.pool())
                .await
                .expect("delete no-handoff parent");
        } else {
            corrupt_parent_json(&fixture).await;
        }
        assert!(
            fixture
                .db
                .claim_task_board_remote_cleanup_observation_fenced(&cleanup, HOST, &trust)
                .await
                .is_err()
        );
    }
}
