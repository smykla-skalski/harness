use super::*;

#[tokio::test]
async fn lifecycle_stop_intent_survives_ambiguity_and_fences_every_owner() {
    let fixture = executor_fixture(1).await;
    let accepted = claim_executor(&fixture).await;
    let started = match authorize_and_start_executor(
        &fixture,
        &accepted.assignment_id,
        STARTED_AT,
    )
    .await
    {
        TaskBoardRemoteMutationOutcome::Updated(record) => record,
        other => panic!("expected started executor, got {other:?}"),
    };
    let owner = started
        .executor_lifecycle_owner
        .clone()
        .expect("initial lifecycle owner");
    let immutable_receipt = started.start_receipt.clone();
    let mut run = fixture
        .db
        .codex_run(
            &started
                .start_receipt
                .as_ref()
                .expect("start receipt")
                .run_id,
        )
        .await
        .expect("load executor run")
        .expect("executor run");
    let source = TaskBoardRemoteExecutorStopAuthority::Lifecycle(owner.clone());
    let pending = fixture
        .db
        .claim_task_board_remote_executor_stop_pending(
            &source,
            &run,
            TaskBoardRemoteExecutorStopReason::LifecycleEvidenceInvalid,
            "2026-07-19T10:00:21Z",
        )
        .await
        .expect("claim lifecycle stop authority")
        .expect("lifecycle stop authority");
    let replay = fixture
        .db
        .claim_task_board_remote_executor_stop_pending(
            &source,
            &run,
            TaskBoardRemoteExecutorStopReason::LifecycleEvidenceInvalid,
            "2026-07-19T10:00:22Z",
        )
        .await
        .expect("replay lifecycle stop authority")
        .expect("replayed lifecycle stop authority");
    assert_eq!(replay, pending);
    assert_owner_is_stop_only(&fixture, &started, &owner, &pending).await;

    run.status = CodexRunStatus::Cancelled;
    run.updated_at = "2026-07-19T10:00:23Z".into();
    fixture
        .db
        .save_codex_run(&run)
        .await
        .expect("persist stopped executor run");
    let settled = fixture
        .db
        .settle_task_board_remote_executor_stop_pending(
            &pending,
            "2026-07-19T10:00:24Z",
        )
        .await
        .expect("settle lifecycle stop authority");
    assert!(matches!(
        settled,
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Unknown
                && record.executor_lifecycle_owner.is_none()
                && record.executor_stop_pending.is_none()
                && record.start_receipt == immutable_receipt
    ));
    assert!(matches!(
        fixture
            .db
            .settle_task_board_remote_executor_stop_pending(
                &pending,
                "2026-07-19T10:00:25Z",
            )
            .await
            .expect("replay lifecycle stop settlement"),
        TaskBoardRemoteMutationOutcome::Replayed(_)
    ));
}

async fn assert_owner_is_stop_only(
    fixture: &ExecutorFixture,
    started: &TaskBoardRemoteAssignmentRecord,
    owner: &TaskBoardRemoteExecutorLifecycleOwner,
    pending: &TaskBoardRemoteExecutorStopPending,
) {
    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_lifecycle_owner(
                &started.assignment_id,
                "instance-successor",
                AFTER_EXPIRY,
            )
            .await
            .expect("stop-only lifecycle transfer")
            .is_none()
    );
    assert!(matches!(
        fixture
            .db
            .mark_task_board_remote_assignment_running(
                &started.assignment_id,
                owner,
                "2026-07-19T10:00:22Z",
            )
            .await
            .expect("stop-only running transition"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    assert!(matches!(
        fixture
            .db
            .settle_task_board_remote_executor_stop_pending(
                pending,
                "2026-07-19T10:00:22Z",
            )
            .await
            .expect("active stop remains ambiguous"),
        TaskBoardRemoteMutationOutcome::Stale(ref record)
            if record.executor_stop_pending.as_ref() == Some(pending)
    ));
    let (response, artifacts) = completed_evidence(started);
    assert!(matches!(
        fixture
            .db
            .complete_task_board_remote_executor_terminal(owner, &response, &artifacts)
            .await
            .expect("stop-only terminal attempt"),
        TaskBoardRemoteMutationOutcome::Stale(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Started
                && record.executor_stop_pending.as_ref() == Some(pending)
                && record.status_response.is_none()
    ));
    assert_other_executor_mutations_are_stale(fixture, started, pending).await;
}

async fn assert_other_executor_mutations_are_stale(
    fixture: &ExecutorFixture,
    started: &TaskBoardRemoteAssignmentRecord,
    pending: &TaskBoardRemoteExecutorStopPending,
) {
    let renewal = fixture
        .db
        .build_task_board_remote_renew_request(&started.assignment_id)
        .await
        .expect("build stop-only renewal")
        .expect("stop-only renewal request");
    let cancel = RemoteCancelRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: fixture.request.binding.clone(),
        lease_id: started.lease_id.clone().expect("stop-only lease"),
        offer_request_sha256: fixture.request.request_sha256.clone(),
        reason: "controller cancellation raced compensation".into(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal stop-only cancellation");
    let renewal = fixture
        .db
        .renew_task_board_remote_assignment_lease(
            &renewal,
            PRINCIPAL,
            "2026-07-19T10:00:22Z",
        )
        .await
        .expect("stop-only renewal");
    let cancellation = fixture
        .db
        .cancel_task_board_remote_assignment(
            &cancel,
            PRINCIPAL,
            "2026-07-19T10:00:22Z",
        )
        .await
        .expect("stop-only cancellation");
    let unknown = fixture
        .db
        .mark_task_board_remote_assignment_unknown(
            &fixture.request.binding,
            "generic ambiguity raced compensation",
            "2026-07-19T10:00:22Z",
        )
        .await
        .expect("stop-only generic unknown");
    for outcome in [renewal, cancellation, unknown] {
        assert!(matches!(
            outcome,
            TaskBoardRemoteMutationOutcome::Stale(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Started
                    && record.executor_stop_pending.as_ref() == Some(pending)
        ));
    }
}
