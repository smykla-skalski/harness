use sqlx::query;

use super::completion_evidence_tests::intent_status;
use super::ledger_kind_state;
use crate::daemon::db::task_board::TaskBoardRemoteResultAdoptionOutcome;
use crate::daemon::task_board_remote_transport::wire::RemoteTypedResult;
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionDiagnostic,
    TaskBoardExecutionState, TaskBoardFailureClass, TaskBoardWorkflowExecutionCas,
};

#[path = "admission_dispatch_remote_result_adoption_support.rs"]
mod support;
use support::*;

#[tokio::test]
async fn completed_result_adopts_once_and_settles_prepared_start_before_target_clear() {
    let candidate = completed_candidate("remote-result-completed", None).await;
    store_result(&candidate).await;
    let expected = TaskBoardWorkflowExecutionCas::from(&candidate.parent);

    let TaskBoardRemoteResultAdoptionOutcome::Updated(adopted) = candidate
        .prepared
        .db
        .adopt_task_board_remote_terminal_result(
            &expected,
            &candidate.prepared.offer.binding.assignment_id,
            1,
        )
        .await
        .expect("adopt fetched remote result")
    else {
        panic!("completed result was not adopted")
    };
    assert_eq!(
        adopted.transition.execution_state,
        TaskBoardExecutionState::Running
    );
    assert_eq!(adopted.attempts[0].state, TaskBoardAttemptState::Completed);
    assert_eq!(
        adopted.attempts[0].artifact.as_ref(),
        candidate
            .response
            .result
            .as_ref()
            .map(|result| &result.result.artifact)
    );
    assert!(adopted.ownership.host_id.is_none());
    assert!(
        !adopted
            .ownership
            .resources
            .contains_key(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
    );
    assert_eq!(
        intent_status(&candidate.prepared.db, &candidate.prepared.intent).await,
        "completed"
    );
    assert_eq!(
        ledger_kind_state(&candidate.prepared.db, &candidate.prepared.intent, "rate").await,
        "committed"
    );
    assert_eq!(
        ledger_kind_state(
            &candidate.prepared.db,
            &candidate.prepared.intent,
            "concurrency"
        )
        .await,
        "committed"
    );
    let sequence = candidate
        .prepared
        .db
        .current_change_sequence()
        .await
        .expect("load adopted sequence");
    assert!(matches!(
        candidate
            .prepared
            .db
            .adopt_task_board_remote_terminal_result(
                &expected,
                &candidate.prepared.offer.binding.assignment_id,
                1,
            )
            .await
            .expect("replay remote result adoption"),
        TaskBoardRemoteResultAdoptionOutcome::Replayed(ref replayed) if replayed == &adopted
    ));
    assert!(matches!(
        candidate
            .prepared
            .db
            .adopt_task_board_remote_terminal_result(
                &TaskBoardWorkflowExecutionCas::from(&adopted),
                &candidate.prepared.offer.binding.assignment_id,
                2,
            )
            .await
            .expect("reject adoption replay from another fencing epoch"),
        TaskBoardRemoteResultAdoptionOutcome::Stale(ref current) if current == &adopted
    ));
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

#[tokio::test]
async fn stale_parent_epoch_and_divergent_target_mutate_nothing() {
    let candidate = completed_candidate("remote-result-stale", None).await;
    store_result(&candidate).await;
    let expected = TaskBoardWorkflowExecutionCas::from(&candidate.parent);
    let mut sibling_changed = candidate.parent.clone();
    sibling_changed
        .artifacts
        .diagnostics
        .push(TaskBoardExecutionDiagnostic {
            code: "concurrent_evidence".into(),
            message: "sibling evidence changed before adoption".into(),
            recorded_at: "2026-07-19T10:00:06Z".into(),
        });
    sibling_changed.updated_at = "2026-07-19T10:00:06Z".into();
    candidate
        .prepared
        .db
        .compare_and_set_task_board_workflow_execution(&expected, &sibling_changed)
        .await
        .expect("persist concurrent sibling evidence");
    assert!(matches!(
        candidate
            .prepared
            .db
            .adopt_task_board_remote_terminal_result(
                &expected,
                &candidate.prepared.offer.binding.assignment_id,
                1,
            )
            .await
            .expect("stale parent is a no-op"),
        TaskBoardRemoteResultAdoptionOutcome::Stale(ref current) if current == &sibling_changed
    ));
    assert!(matches!(
        candidate
            .prepared
            .db
            .adopt_task_board_remote_terminal_result(
                &TaskBoardWorkflowExecutionCas::from(&sibling_changed),
                &candidate.prepared.offer.binding.assignment_id,
                2,
            )
            .await
            .expect("stale epoch is a no-op"),
        TaskBoardRemoteResultAdoptionOutcome::Stale(ref current) if current == &sibling_changed
    ));
    let mut divergent = sibling_changed.clone();
    divergent.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(),
        "remote:other-assignment".into(),
    );
    query(
        "UPDATE task_board_workflow_executions SET resource_ownership_json = ?2
         WHERE execution_id = ?1",
    )
    .bind(&divergent.execution_id)
    .bind(serde_json::to_string(&divergent.ownership).expect("serialize divergent ownership"))
    .execute(candidate.prepared.db.pool())
    .await
    .expect("seed divergent target");
    let divergent = load_parent(&candidate.prepared).await;
    candidate
        .prepared
        .db
        .adopt_task_board_remote_terminal_result(
            &TaskBoardWorkflowExecutionCas::from(&divergent),
            &candidate.prepared.offer.binding.assignment_id,
            1,
        )
        .await
        .expect_err("divergent target must fail closed");
    assert_eq!(load_parent(&candidate.prepared).await, divergent);
}

#[tokio::test]
async fn missing_extra_tampered_and_mismatched_result_artifacts_fail_closed() {
    let missing = completed_candidate("remote-result-missing", None).await;
    assert_adoption_rejected_unchanged(&missing).await;

    let extra = completed_candidate("remote-result-extra", None).await;
    store_result(&extra).await;
    insert_extra_artifact(&extra).await;
    assert_adoption_rejected_unchanged(&extra).await;

    let tampered = completed_candidate("remote-result-tampered", None).await;
    store_result(&tampered).await;
    query(
        "UPDATE task_board_remote_artifacts SET content = zeroblob(size_bytes)
         WHERE assignment_id = ?1 AND relative_path = ?2",
    )
    .bind(&tampered.prepared.offer.binding.assignment_id)
    .bind(RESULT_PATH)
    .execute(tampered.prepared.db.pool())
    .await
    .expect("tamper fetched result bytes");
    assert_adoption_rejected_unchanged(&tampered).await;

    for (label, mutate) in [
        ("schema", wrong_schema as fn(&mut RemoteTypedResult)),
        ("action", wrong_action),
        ("attempt", wrong_attempt),
        ("profile", wrong_profile),
        ("head", wrong_head),
    ] {
        let candidate = completed_candidate(&format!("remote-result-{label}"), Some(mutate)).await;
        store_result(&candidate).await;
        assert_adoption_rejected_unchanged(&candidate).await;
    }
}

#[tokio::test]
async fn failed_result_adopts_retry_and_all_nontransient_terminal_classes_once() {
    let retry = failed_candidate(
        "remote-result-retry",
        TaskBoardFailureClass::Transient,
        Some(2),
    )
    .await;
    let expected = TaskBoardWorkflowExecutionCas::from(&retry.parent);
    let TaskBoardRemoteResultAdoptionOutcome::Updated(retrying) = retry
        .prepared
        .db
        .adopt_task_board_remote_terminal_result(
            &expected,
            &retry.prepared.offer.binding.assignment_id,
            1,
        )
        .await
        .expect("adopt transient failure")
    else {
        panic!("transient failure was not adopted")
    };
    assert_eq!(
        retrying.transition.execution_state,
        TaskBoardExecutionState::RetryWait
    );
    assert_eq!(retrying.attempts[0].state, TaskBoardAttemptState::RetryWait);
    assert!(retrying.ownership.host_id.is_none());
    let reopened = retry.prepared.db.reopen().await;
    assert!(matches!(
        reopened
            .adopt_task_board_remote_terminal_result(
                &expected,
                &retry.prepared.offer.binding.assignment_id,
                1,
            )
            .await
            .expect("replay retry adoption after restart"),
        TaskBoardRemoteResultAdoptionOutcome::Replayed(_)
    ));

    for failure_class in [
        TaskBoardFailureClass::Permanent,
        TaskBoardFailureClass::Authentication,
        TaskBoardFailureClass::Configuration,
        TaskBoardFailureClass::Policy,
        TaskBoardFailureClass::Conflict,
    ] {
        let label = format!("remote-result-{failure_class:?}").to_lowercase();
        let candidate = failed_candidate(&label, failure_class, Some(3)).await;
        let expected = TaskBoardWorkflowExecutionCas::from(&candidate.parent);
        let TaskBoardRemoteResultAdoptionOutcome::Updated(stopped) = candidate
            .prepared
            .db
            .adopt_task_board_remote_terminal_result(
                &expected,
                &candidate.prepared.offer.binding.assignment_id,
                1,
            )
            .await
            .expect("adopt nontransient failure")
        else {
            panic!("nontransient failure was not adopted")
        };
        assert_eq!(
            stopped.transition.execution_state,
            TaskBoardExecutionState::HumanRequired
        );
        assert_eq!(stopped.attempts[0].state, TaskBoardAttemptState::Failed);
        assert_eq!(
            stopped.blocked_reason.as_deref(),
            Some("remote_attempt_non_retryable")
        );
        assert_eq!(
            ledger_kind_state(
                &candidate.prepared.db,
                &candidate.prepared.intent,
                "concurrency"
            )
            .await,
            "released"
        );
    }
}
