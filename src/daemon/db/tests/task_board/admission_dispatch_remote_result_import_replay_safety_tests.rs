use super::*;

#[tokio::test]
async fn applied_import_replays_only_after_fresh_exact_git_proof() {
    let candidate = import_candidate("result-import-replay").await;
    let applied = import_result(&candidate, &candidate.parent).await;
    assert_eq!(applied.state, TaskBoardRemoteResultImportState::Applied);
    candidate.git.assert_applied();

    let current = load_parent(&candidate.prepared).await;
    let reopened = candidate.prepared.db.reopen().await;
    let replayed = import_task_board_remote_implementation_result(
        &reopened,
        &TaskBoardWorkflowExecutionCas::from(&current),
        &candidate.request,
    )
    .await
    .expect("replay applied import after restart");

    assert_eq!(replayed, applied);
    candidate.git.assert_applied();
}

#[tokio::test]
async fn dirty_applied_replay_projects_manual_required_without_overwriting_worktree() {
    let candidate = import_candidate("result-import-dirty").await;
    import_result(&candidate, &candidate.parent).await;
    fs::write(
        candidate.git.controller.join("result.txt"),
        "preserve this user edit\n",
    )
    .expect("write user edit after applied import");
    let before = load_parent(&candidate.prepared).await;

    import_task_board_remote_implementation_result(
        &candidate.prepared.db,
        &TaskBoardWorkflowExecutionCas::from(&before),
        &candidate.request,
    )
    .await
    .expect_err("dirty applied replay must require human review");

    let journal = candidate
        .prepared
        .db
        .task_board_remote_result_import(
            &candidate.prepared.offer.binding.assignment_id,
            1,
        )
        .await
        .expect("load manual import journal")
        .expect("manual import journal");
    assert_eq!(journal.state, TaskBoardRemoteResultImportState::ManualRequired);
    assert!(journal.last_error.as_deref().is_some_and(|error| error.contains("unsafe")));
    let parent = load_parent(&candidate.prepared).await;
    assert_eq!(parent.transition.execution_state, TaskBoardExecutionState::HumanRequired);
    assert_eq!(parent.blocked_reason.as_deref(), Some("remote_result_import_manual_required"));
    assert_eq!(parent.attempts[0].state, TaskBoardAttemptState::Failed);
    assert_eq!(parent.attempts[0].failure_class, Some(TaskBoardFailureClass::Permanent));
    assert!(!parent
        .ownership
        .resources
        .contains_key(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE));
    assert_eq!(
        candidate
            .prepared
            .db
            .task_board_item(&candidate.item_id)
            .await
            .expect("load projected item")
            .status,
        TaskBoardStatus::HumanRequired
    );
    assert_eq!(intent_status(&candidate.prepared.db, &candidate.prepared.intent).await, "completed");
    assert_eq!(
        ledger_kind_state(&candidate.prepared.db, &candidate.prepared.intent, "rate").await,
        "committed"
    );
    assert_eq!(
        ledger_kind_state(
            &candidate.prepared.db,
            &candidate.prepared.intent,
            "concurrency",
        )
        .await,
        "released"
    );
    assert_eq!(
        fs::read_to_string(candidate.git.controller.join("result.txt")).expect("read user edit"),
        "preserve this user edit\n"
    );
    let sequence = candidate
        .prepared
        .db
        .current_change_sequence()
        .await
        .expect("load manual sequence");
    import_task_board_remote_implementation_result(
        &candidate.prepared.db,
        &TaskBoardWorkflowExecutionCas::from(&parent),
        &candidate.request,
    )
    .await
    .expect_err("manual import replay remains terminal");
    assert_eq!(
        candidate
            .prepared
            .db
            .current_change_sequence()
            .await
            .expect("load replay sequence"),
        sequence
    );
}
