use super::*;

#[tokio::test]
async fn pre_permit_invalid_run_stops_and_settles_under_the_start_authority() {
    let fixture = executor_fixture(1).await;
    let accepted = claim_executor(&fixture).await;
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            INSTANCE,
            STARTED_AT,
        )
        .await
        .expect("claim start authority")
        .expect("start authority");
    let assignment = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load start-authorized assignment")
        .expect("start-authorized assignment");
    // The permit transaction rolled back after the run side-effect: a durable run
    // exists while the assignment stays Claimed with a start authority and no permit.
    persist_pre_permit_executor_run(&fixture, &assignment, &authority, STARTED_AT).await;
    let pre_permit = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load pre-permit assignment")
        .expect("pre-permit assignment");
    assert_eq!(pre_permit.state, TaskBoardRemoteAssignmentState::Claimed);
    assert!(pre_permit.executor_start_authority_sha256.is_some());
    assert!(pre_permit.executor_start_io_permit_sha256.is_none());
    assert!(pre_permit.start_receipt.is_none());
    assert!(pre_permit.executor_lifecycle_owner.is_none());

    let mut invalid_run = fixture
        .db
        .codex_run(&authority.identity.run_id)
        .await
        .expect("load executor run")
        .expect("executor run");
    invalid_run.prompt = "launch fields diverged from the sealed offer".into();
    fixture
        .db
        .save_codex_run(&invalid_run)
        .await
        .expect("persist invalid launch evidence");
    let pending = fixture
        .db
        .claim_task_board_remote_executor_stop_pending(
            &TaskBoardRemoteExecutorStopAuthority::PrePermit(authority.clone()),
            &invalid_run,
            TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
            "2026-07-19T10:00:21Z",
        )
        .await
        .expect("claim pre-permit invalid-run stop")
        .expect("stop-pending marker");

    invalid_run.status = CodexRunStatus::Cancelled;
    invalid_run.updated_at = "2026-07-19T10:00:22Z".into();
    fixture
        .db
        .save_codex_run(&invalid_run)
        .await
        .expect("persist stopped invalid run");
    assert!(matches!(
        fixture
            .db
            .settle_task_board_remote_executor_stop_pending(
                &pending,
                "2026-07-19T10:00:23Z",
            )
            .await
            .expect("settle pre-permit invalid-run stop"),
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Unknown
                && record.executor_stop_pending.is_none()
                && record.executor_start_authority_sha256.is_none()
    ));
}

#[tokio::test]
async fn pre_permit_stop_is_refused_when_a_start_permit_is_durable() {
    let fixture = executor_fixture(1).await;
    let accepted = claim_executor(&fixture).await;
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            INSTANCE,
            STARTED_AT,
        )
        .await
        .expect("claim start authority")
        .expect("start authority");
    let assignment = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load start-authorized assignment")
        .expect("start-authorized assignment");
    // A durable Start I/O permit exists, so the stronger Start arm fences the stop;
    // the pre-permit authority must not be able to stand in for it.
    let (_, _permit) = persist_executor_run(&fixture, &assignment, &authority, STARTED_AT).await;
    let run = fixture
        .db
        .codex_run(&authority.identity.run_id)
        .await
        .expect("load executor run")
        .expect("executor run");

    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_stop_pending(
                &TaskBoardRemoteExecutorStopAuthority::PrePermit(authority),
                &run,
                TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
                "2026-07-19T10:00:21Z",
            )
            .await
            .expect("evaluate pre-permit stop against a permitted run")
            .is_none()
    );
    let unchanged = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load unchanged assignment")
        .expect("unchanged assignment");
    assert!(unchanged.executor_stop_pending.is_none());
    assert!(unchanged.executor_start_io_permit_sha256.is_some());
}
