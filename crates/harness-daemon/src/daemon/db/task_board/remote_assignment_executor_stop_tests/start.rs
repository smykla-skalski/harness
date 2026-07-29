use super::*;

#[tokio::test]
async fn crash_before_stop_io_restarts_in_stop_only_mode() {
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
    let (_, permit) = persist_executor_run(&fixture, &assignment, &authority, STARTED_AT).await;
    let snapshot = fixture
        .db
        .codex_run(&authority.identity.run_id)
        .await
        .expect("load executor run")
        .expect("executor run");
    let pending = fixture
        .db
        .claim_task_board_remote_executor_stop_pending(
            &TaskBoardRemoteExecutorStopAuthority::Start(Box::new(permit.clone())),
            &snapshot,
            TaskBoardRemoteExecutorStopReason::StartAdoptionFailed,
            "2026-07-19T10:00:21Z",
        )
        .await
        .expect("persist stop before I/O")
        .expect("stop-pending marker");

    let database_path = fixture._temp.path().join("executor.db");
    let temp = fixture._temp;
    drop(fixture.db);
    let db = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("restart executor database");
    let restarted = db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load stop-pending assignment after restart")
        .expect("stop-pending assignment after restart");
    assert_eq!(restarted.executor_stop_pending.as_ref(), Some(&pending));
    assert!(
        db.claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            INSTANCE,
            "2026-07-19T10:00:22Z",
        )
        .await
        .expect("restart start claim")
        .is_none()
    );
    assert!(matches!(
        db.adopt_task_board_remote_executor_start(
            &permit,
            std::path::Path::new(&snapshot.project_dir),
            STARTED_AT,
        )
        .await
        .expect("restart adoption remains stop-only"),
        TaskBoardRemoteMutationOutcome::Stale(_)
    ));
    drop(temp);
}

#[tokio::test]
async fn wrong_run_identity_cannot_persist_a_stop_marker() {
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
    let (_, permit) = persist_executor_run(&fixture, &assignment, &authority, STARTED_AT).await;
    let mut wrong_run = fixture
        .db
        .codex_run(&authority.identity.run_id)
        .await
        .expect("load executor run")
        .expect("executor run");
    wrong_run.run_id = "unrelated-remote-codex-run".into();
    fixture
        .db
        .save_codex_run(&wrong_run)
        .await
        .expect("persist unrelated durable run");

    assert!(
        fixture
            .db
            .claim_task_board_remote_executor_stop_pending(
                &TaskBoardRemoteExecutorStopAuthority::Start(Box::new(permit)),
                &wrong_run,
                TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
                "2026-07-19T10:00:21Z",
            )
            .await
            .expect("reject unrelated stop evidence")
            .is_none()
    );
    let unchanged = fixture
        .db
        .task_board_remote_assignment(&accepted.assignment_id)
        .await
        .expect("load unchanged assignment")
        .expect("unchanged assignment");
    assert!(unchanged.executor_stop_pending.is_none());
    assert!(unchanged.executor_start_authority_sha256.is_some());
}

#[tokio::test]
async fn exact_run_with_invalid_launch_fields_can_stop_and_settle() {
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
    let (_, permit) = persist_executor_run(&fixture, &assignment, &authority, STARTED_AT).await;
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
            &TaskBoardRemoteExecutorStopAuthority::Start(Box::new(permit)),
            &invalid_run,
            TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid,
            "2026-07-19T10:00:21Z",
        )
        .await
        .expect("claim exact invalid-run stop")
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
            .expect("settle exact invalid-run stop"),
        TaskBoardRemoteMutationOutcome::Updated(ref record)
            if record.state == TaskBoardRemoteAssignmentState::Unknown
                && record.executor_stop_pending.is_none()
                && record.executor_start_authority_sha256.is_none()
    ));
}
