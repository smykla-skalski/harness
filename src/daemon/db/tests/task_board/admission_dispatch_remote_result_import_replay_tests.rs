use super::*;
use crate::daemon::db::task_board::TaskBoardRemoteResultAdoptionOutcome;
use crate::task_board::{TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind};

#[tokio::test]
async fn production_orchestration_imports_adopts_and_cleans_exactly_once() {
    let candidate = import_candidate("result-import-production-orchestration").await;

    let TaskBoardRemoteResultAdoptionOutcome::Updated(adopted) =
        crate::daemon::service::import_and_adopt_task_board_remote_implementation_result(
            &candidate.prepared.db,
            &candidate.prepared.offer.binding.assignment_id,
            1,
        )
        .await
        .expect("import and adopt remote implementation")
    else {
        panic!("implementation orchestration did not advance the exact attempt")
    };

    assert_eq!(adopted.attempts[0].state, TaskBoardAttemptState::Completed);
    let journal = candidate
        .prepared
        .db
        .task_board_remote_result_import(&candidate.prepared.offer.binding.assignment_id, 1)
        .await
        .expect("load adopted production import")
        .expect("adopted production import journal");
    assert_eq!(journal.state, TaskBoardRemoteResultImportState::Adopted);
    assert!(!git_succeeds(
        &candidate.git.controller,
        &["rev-parse", "--verify", &journal.import_ref],
    ));
    let sequence = candidate
        .prepared
        .db
        .current_change_sequence()
        .await
        .expect("load adopted sequence");
    let reopened = candidate.prepared.db.reopen().await;

    assert!(matches!(
        crate::daemon::service::import_and_adopt_task_board_remote_implementation_result(
            &reopened,
            &candidate.prepared.offer.binding.assignment_id,
            1,
        )
        .await
        .expect("replay imported implementation after restart"),
        TaskBoardRemoteResultAdoptionOutcome::Replayed(ref replayed) if replayed == &adopted
    ));
    assert_eq!(
        reopened
            .current_change_sequence()
            .await
            .expect("load replayed sequence"),
        sequence
    );
}

#[tokio::test]
async fn durable_git_coordinate_drift_projects_manual_required_before_mutation() {
    let candidate = import_candidate("result-import-coordinate-drift").await;
    let mut request = candidate.request.clone();
    request.git_dir = candidate
        .git
        .controller
        .join("wrong-git-dir")
        .to_string_lossy()
        .into_owned();
    candidate
        .prepared
        .db
        .prepare_task_board_remote_result_import(
            &TaskBoardWorkflowExecutionCas::from(&candidate.parent),
            &request,
        )
        .await
        .expect("prepare import with durable but incorrect Git coordinate");
    let current = load_parent(&candidate.prepared).await;

    import_task_board_remote_implementation_result(
        &candidate.prepared.db,
        &TaskBoardWorkflowExecutionCas::from(&current),
        &request,
    )
    .await
    .expect_err("durable Git coordinate drift must require human review");

    let journal = candidate
        .prepared
        .db
        .task_board_remote_result_import(&candidate.prepared.offer.binding.assignment_id, 1)
        .await
        .expect("load failed result import")
        .expect("failed result import journal");
    assert_eq!(journal.state, TaskBoardRemoteResultImportState::ManualRequired);
    assert!(journal.last_error.as_deref().is_some_and(|detail| {
        detail.contains("differs from its exact Git worktree")
    }));
    let parent = load_parent(&candidate.prepared).await;
    assert_eq!(parent.transition.execution_state, TaskBoardExecutionState::HumanRequired);
    assert_eq!(git(&candidate.git.controller, &["rev-parse", "HEAD"]), candidate.git.base);
    assert!(git(&candidate.git.controller, &["status", "--porcelain"]).is_empty());
}

#[tokio::test]
async fn import_refuses_a_non_session_branch_before_git_mutation() {
    let candidate = import_candidate("result-import-wrong-branch").await;
    let mut request = candidate.request.clone();
    request.branch_ref = "refs/heads/not-the-session".into();

    candidate
        .prepared
        .db
        .prepare_task_board_remote_result_import(
            &TaskBoardWorkflowExecutionCas::from(&candidate.parent),
            &request,
        )
        .await
        .expect_err("non-session branch must not gain import authority");

    assert!(candidate
        .prepared
        .db
        .task_board_remote_result_import(&candidate.prepared.offer.binding.assignment_id, 1)
        .await
        .expect("load refused import journal")
        .is_none());
    assert_eq!(
        git(&candidate.git.controller, &["symbolic-ref", "HEAD"]),
        candidate.git.branch_ref
    );
    assert_eq!(
        git(&candidate.git.controller, &["rev-parse", "HEAD"]),
        candidate.git.base
    );
    assert!(!git_succeeds(
        &candidate.git.controller,
        &["rev-parse", "--verify", IMPORT_REF],
    ));
}

#[tokio::test]
async fn journal_evidence_drift_cannot_advance_git_or_import_state() {
    for (label, column) in [
        ("offer", "offer_request_sha256"),
        ("status", "status_sha256"),
        ("bundle", "bundle_sha256"),
    ] {
        let candidate = import_candidate(&format!("result-import-{label}-drift")).await;
        candidate
            .prepared
            .db
            .prepare_task_board_remote_result_import(
                &TaskBoardWorkflowExecutionCas::from(&candidate.parent),
                &candidate.request,
            )
            .await
            .expect("prepare exact import journal");
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "UPDATE task_board_remote_result_imports
             SET {column} = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
             WHERE assignment_id = ?1 AND fencing_epoch = 1"
        )))
        .bind(&candidate.prepared.offer.binding.assignment_id)
        .execute(candidate.prepared.db.pool())
        .await
        .expect("tamper journal evidence");
        let parent = load_parent(&candidate.prepared).await;

        import_task_board_remote_implementation_result(
            &candidate.prepared.db,
            &TaskBoardWorkflowExecutionCas::from(&parent),
            &candidate.request,
        )
        .await
        .expect_err("changed journal evidence must fail closed");

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
        let current = load_parent(&candidate.prepared).await;
        assert_eq!(
            current.transition.execution_state,
            TaskBoardExecutionState::HumanRequired
        );
        assert!(!current
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE));
        assert_eq!(
            git(&candidate.git.controller, &["rev-parse", "HEAD"]),
            candidate.git.base
        );
        assert!(git(&candidate.git.controller, &["status", "--porcelain"]).is_empty());
    }
}

#[tokio::test]
async fn noncanonical_durable_import_row_fails_restart_decode() {
    for (label, column, value) in [
        ("relative", "worktree_path", "relative/path"),
        ("duplicate-root", "worktree_path", "//tmp/result-import"),
        (
            "trailing-separator",
            "worktree_path",
            "/tmp/result-import/",
        ),
        ("branch-dotdot", "branch_ref", "refs/heads/../other"),
    ] {
        let candidate = import_candidate(&format!("result-import-corrupt-{label}")).await;
        candidate
            .prepared
            .db
            .prepare_task_board_remote_result_import(
                &TaskBoardWorkflowExecutionCas::from(&candidate.parent),
                &candidate.request,
            )
            .await
            .expect("prepare exact import journal");
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "UPDATE task_board_remote_result_imports SET {column} = ?1
             WHERE assignment_id = ?2 AND fencing_epoch = 1"
        )))
        .bind(value)
        .bind(&candidate.prepared.offer.binding.assignment_id)
        .execute(candidate.prepared.db.pool())
        .await
        .expect("corrupt result import path within the SQL storage shape");

        let error = candidate
            .prepared
            .db
            .task_board_remote_result_import(&candidate.prepared.offer.binding.assignment_id, 1)
            .await
            .expect_err("noncanonical durable import must not decode after restart");

        assert!(error.to_string().contains("coordinates are noncanonical"));
        assert_eq!(
            git(&candidate.git.controller, &["rev-parse", "HEAD"]),
            candidate.git.base
        );
    }
}

#[tokio::test]
async fn implementation_adoption_consumes_applied_journal_atomically() {
    let candidate = import_candidate("result-import-adoption").await;
    let applied = import_result(&candidate, &candidate.parent).await;
    let parent = load_parent(&candidate.prepared).await;

    let TaskBoardRemoteResultAdoptionOutcome::Updated(adopted) = candidate
        .prepared
        .db
        .adopt_task_board_remote_terminal_result(
            &TaskBoardWorkflowExecutionCas::from(&parent),
            &candidate.prepared.offer.binding.assignment_id,
            1,
        )
        .await
        .expect("adopt exact applied implementation result")
    else {
        panic!("applied implementation result was not adopted")
    };

    assert_eq!(adopted.transition.execution_state, TaskBoardExecutionState::Running);
    assert_eq!(adopted.attempts[0].state, TaskBoardAttemptState::Completed);
    assert!(!adopted
        .ownership
        .resources
        .contains_key(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE));
    let journal = candidate
        .prepared
        .db
        .task_board_remote_result_import(&candidate.prepared.offer.binding.assignment_id, 1)
        .await
        .expect("load adopted import journal")
        .expect("adopted import journal");
    assert_eq!(journal.state, TaskBoardRemoteResultImportState::Adopted);
    assert_eq!(journal.import_sha256, applied.import_sha256);
    assert!(matches!(
        candidate
            .prepared
            .db
            .adopt_task_board_remote_terminal_result(
                &TaskBoardWorkflowExecutionCas::from(&parent),
                &candidate.prepared.offer.binding.assignment_id,
                1,
            )
            .await
            .expect("replay adopted implementation after restart boundary"),
        TaskBoardRemoteResultAdoptionOutcome::Replayed(ref replayed) if replayed == &adopted
    ));
    let before_cleanup = candidate.prepared.db.reopen().await;
    crate::daemon::service::cleanup_task_board_remote_result_import(
        &before_cleanup,
        &candidate.prepared.offer.binding.assignment_id,
        1,
    )
    .await
    .expect("clean adopted private import ref after restart");
    assert!(
        !git_succeeds(&candidate.git.controller, &["rev-parse", "--verify", IMPORT_REF]),
        "adopted private import ref remained after exact cleanup"
    );
    let after_cleanup = candidate.prepared.db.reopen().await;
    crate::daemon::service::cleanup_task_board_remote_result_import(
        &after_cleanup,
        &candidate.prepared.offer.binding.assignment_id,
        1,
    )
    .await
    .expect("replay cleanup after a lost completion response");
    assert_eq!(
        after_cleanup
            .task_board_remote_result_import(
                &candidate.prepared.offer.binding.assignment_id,
                1,
            )
            .await
            .expect("load import journal after replayed cleanup")
            .expect("adopted import journal after replayed cleanup")
            .state,
        TaskBoardRemoteResultImportState::Adopted
    );
}

#[tokio::test]
async fn adopted_import_artifacts_survive_retention_until_the_workflow_concludes() {
    let candidate = import_candidate("result-import-retention").await;
    candidate
        .prepared
        .db
        .prepare_task_board_remote_result_import(
            &TaskBoardWorkflowExecutionCas::from(&candidate.parent),
            &candidate.request,
        )
        .await
        .expect("prepare exact import journal");

    assert_eq!(prune_old_artifacts(&candidate).await, 0);
    assert_eq!(artifact_count(&candidate).await, 2);

    let prepared_parent = load_parent(&candidate.prepared).await;
    let reopened = candidate.prepared.db.reopen().await;
    let applied = import_task_board_remote_implementation_result(
        &reopened,
        &TaskBoardWorkflowExecutionCas::from(&prepared_parent),
        &candidate.request,
    )
    .await
    .expect("apply retained implementation bundle after restart");
    assert_eq!(applied.state, TaskBoardRemoteResultImportState::Applied);
    assert_eq!(prune_old_artifacts(&candidate).await, 0);
    assert_eq!(artifact_count(&candidate).await, 2);

    let applied_parent = load_parent(&candidate.prepared).await;
    assert!(matches!(
        candidate
            .prepared
            .db
            .adopt_task_board_remote_terminal_result(
                &TaskBoardWorkflowExecutionCas::from(&applied_parent),
                &candidate.prepared.offer.binding.assignment_id,
                1,
            )
            .await
            .expect("adopt retained implementation evidence"),
        TaskBoardRemoteResultAdoptionOutcome::Updated(_)
    ));
    // Adoption advances the parent to Running for the next phase, which still sources
    // its bundle from this retained artifact, so the durable evidence is held past
    // adoption rather than released by it.
    assert_eq!(prune_old_artifacts(&candidate).await, 0);
    assert_eq!(artifact_count(&candidate).await, 2);

    // Once the workflow leaves the active phases the bundle has no remaining consumer
    // and the durable evidence is finally prunable.
    conclude_parent_workflow(&candidate).await;
    assert_eq!(prune_old_artifacts(&candidate).await, 2);
    assert_eq!(artifact_count(&candidate).await, 0);
}

async fn conclude_parent_workflow(candidate: &ImportCandidate) {
    let current = load_parent(&candidate.prepared).await;
    let mut concluded = current.clone();
    concluded.transition.execution_state = TaskBoardExecutionState::HumanRequired;
    concluded.blocked_reason = Some("attempt_outcome_unknown".into());
    concluded.available_at = None;
    concluded.updated_at = "2026-07-19T10:05:00Z".into();
    concluded.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::Unknown,
        summary: "await human review before the next phase".into(),
        recorded_at: "2026-07-19T10:05:00Z".into(),
    });
    candidate
        .prepared
        .db
        .compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &concluded,
        )
        .await
        .expect("conclude parent workflow to a terminal state");
}

#[tokio::test]
async fn manual_import_artifacts_remain_subject_to_bounded_retention() {
    let candidate = import_candidate("result-import-manual-retention").await;
    candidate
        .prepared
        .db
        .prepare_task_board_remote_result_import(
            &TaskBoardWorkflowExecutionCas::from(&candidate.parent),
            &candidate.request,
        )
        .await
        .expect("prepare exact import journal");
    fs::write(
        candidate.git.controller.join("preserve-user.txt"),
        "user-owned\n",
    )
    .expect("create unsafe user-owned worktree file");
    let prepared_parent = load_parent(&candidate.prepared).await;
    import_task_board_remote_implementation_result(
        &candidate.prepared.db,
        &TaskBoardWorkflowExecutionCas::from(&prepared_parent),
        &candidate.request,
    )
    .await
    .expect_err("unsafe import must require manual recovery");
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

    assert_eq!(prune_old_artifacts(&candidate).await, 2);
    assert_eq!(artifact_count(&candidate).await, 0);
    assert_eq!(
        fs::read_to_string(candidate.git.controller.join("preserve-user.txt"))
            .expect("read preserved user-owned file"),
        "user-owned\n"
    );
}

async fn prune_old_artifacts(candidate: &ImportCandidate) -> u64 {
    candidate
        .prepared
        .db
        .prune_task_board_remote_execution_evidence("2026-08-01T10:10:00Z")
        .await
        .expect("prune old remote evidence")
        .artifacts
}

async fn artifact_count(candidate: &ImportCandidate) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_remote_artifacts
         WHERE assignment_id = ?1 AND fencing_epoch = 1",
    )
    .bind(&candidate.prepared.offer.binding.assignment_id)
    .fetch_one(candidate.prepared.db.pool())
    .await
    .expect("count retained import artifacts")
}

fn git_succeeds(repository: &Path, args: &[&str]) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .output()
        .expect("run git status command")
        .status
        .success()
}
