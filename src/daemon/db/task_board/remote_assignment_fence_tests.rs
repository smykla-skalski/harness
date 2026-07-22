use sqlx::{query, query_scalar};

use super::TaskBoardRemoteMutationOutcome;
use super::TaskBoardRemoteOfferOutcome;
use super::remote_assignment_test_support::{NOW, controller_fixture, offer_controller};
use super::workflow_execution_rows::{execution_json, label};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TaskBoardAttemptState, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptRecord, TaskBoardExecutionState, TaskBoardWorkflowExecutionCas,
};

#[tokio::test]
async fn selected_local_target_wins_before_remote_offer_without_remote_work() {
    let fixture = controller_fixture(1).await;
    assert!(
        fixture
            .db
            .select_task_board_local_execution_target(
                &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
                &TaskBoardExecutionAttemptCas::from(&fixture.attempt),
                NOW,
            )
            .await
            .expect("select local workflow target")
    );
    let selected = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load selected local execution")
        .expect("selected local execution exists");
    let selected_attempt = selected.attempts[0].clone();
    let claimed = local_claim(&selected_attempt);
    assert!(
        fixture
            .db
            .claim_task_board_workflow_side_effect(
                &TaskBoardWorkflowExecutionCas::from(&selected),
                &TaskBoardExecutionAttemptCas::from(&selected_attempt),
                &claimed,
                &claimed.updated_at,
            )
            .await
            .expect("claim local workflow start")
            .is_some()
    );

    assert!(matches!(
        offer_controller(&fixture).await,
        TaskBoardRemoteOfferOutcome::Stale
    ));
    assert!(
        fixture
            .db
            .task_board_remote_assignment(&fixture.request.binding.assignment_id)
            .await
            .expect("load remote assignment")
            .is_none()
    );
    assert_eq!(assignment_count(&fixture).await, 0);
    let execution = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load local execution")
        .expect("local execution exists");
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Running);
    assert_eq!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some("local")
    );
}

#[tokio::test]
async fn targetless_preparing_attempt_cannot_claim_local_runtime() {
    let fixture = controller_fixture(1).await;
    query("DELETE FROM task_board_execution_hosts WHERE host_role = 'controller_remote'")
        .execute(fixture.db.pool())
        .await
        .expect("remove configured host row");
    let claimed = local_claim(&fixture.attempt);
    let error = fixture
        .db
        .claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
            &TaskBoardExecutionAttemptCas::from(&fixture.attempt),
            &claimed,
            &claimed.updated_at,
        )
        .await
        .expect_err("target selection must precede local workflow start");
    assert!(error.to_string().contains("target selection is incomplete"));
    assert_eq!(assignment_count(&fixture).await, 0);
}

#[tokio::test]
async fn new_targetless_starting_attempt_has_no_legacy_local_authority() {
    let fixture = controller_fixture(1).await;
    restore_parent(&fixture, TaskBoardExecutionState::Starting).await;
    query(
        "UPDATE task_board_execution_attempts SET state = 'starting'
         WHERE execution_id = ?1 AND action_key = ?2 AND attempt = ?3",
    )
    .bind(&fixture.attempt.execution_id)
    .bind(&fixture.attempt.action_key)
    .bind(i64::from(fixture.attempt.attempt))
    .execute(fixture.db.pool())
    .await
    .expect("seed new targetless Starting attempt");
    let current = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load targetless Starting workflow")
        .expect("targetless Starting workflow exists");
    let attempt = current.attempts[0].clone();
    let claimed = local_claim(&attempt);
    let error = fixture
        .db
        .claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &TaskBoardExecutionAttemptCas::from(&attempt),
            &claimed,
            &claimed.updated_at,
        )
        .await
        .expect_err("fresh targetless Starting row is not migrated legacy evidence");
    assert!(error.to_string().contains("target selection is incomplete"));
    assert_eq!(codex_run_count(&fixture).await, 0);
}

#[tokio::test]
async fn remote_offer_wins_before_local_claim_without_local_work() {
    let fixture = controller_fixture(1).await;
    assert!(matches!(
        offer_controller(&fixture).await,
        TaskBoardRemoteOfferOutcome::Created(_)
    ));

    let claimed = local_claim(&fixture.attempt);
    let error = fixture
        .db
        .claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(&fixture.execution),
            &TaskBoardExecutionAttemptCas::from(&fixture.attempt),
            &claimed,
            &claimed.updated_at,
        )
        .await
        .expect_err("remote offer must fence the local workflow start");
    assert!(
        error
            .to_string()
            .contains("workflow execution changed before side-effect claim")
    );
    let assignment = fixture
        .db
        .task_board_remote_assignment(&fixture.request.binding.assignment_id)
        .await
        .expect("load remote assignment")
        .expect("remote assignment exists");
    let execution = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load remote execution")
        .expect("remote execution exists");
    let expected_target = format!("remote:{}", assignment.assignment_id);
    assert_eq!(assignment_count(&fixture).await, 1);
    assert_eq!(assignment.execution_id, fixture.execution.execution_id);
    assert_eq!(execution.attempts[0].state, TaskBoardAttemptState::Starting);
    assert_eq!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some(expected_target.as_str())
    );
}

#[tokio::test]
async fn unresolved_older_generation_blocks_selection_and_local_start() {
    let fixture = controller_fixture(1).await;
    offer_controller(&fixture).await;
    assert!(
        fixture
            .db
            .task_board_execution_generation_has_active_remote_assignment(
                &fixture.execution.execution_id,
                1,
            )
            .await
            .expect("load exact remote generation fence")
    );
    assert!(
        !fixture
            .db
            .task_board_execution_generation_has_active_remote_assignment(
                &fixture.execution.execution_id,
                2,
            )
            .await
            .expect("reject unrelated remote generation")
    );
    restore_parent(&fixture, TaskBoardExecutionState::Pending).await;

    assert!(
        fixture
            .db
            .ready_task_board_workflow_executions(NOW, 10)
            .await
            .expect("select ready workflows")
            .is_empty()
    );

    restore_parent(&fixture, TaskBoardExecutionState::Preparing).await;
    assert!(
        fixture
            .db
            .recoverable_task_board_workflow_executions(10)
            .await
            .expect("select recoverable workflows")
            .is_empty()
    );
    let current = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load restored execution")
        .expect("restored execution");
    let current_attempt = current.attempts[0].clone();
    let mut claimed = current_attempt.clone();
    claimed.state = TaskBoardAttemptState::Running;
    claimed.updated_at = "2026-07-19T10:00:01Z".into();
    let error = fixture
        .db
        .claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &TaskBoardExecutionAttemptCas::from(&current_attempt),
            &claimed,
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect_err("unresolved older remote generation must fence local start");
    assert!(
        error
            .to_string()
            .contains("active remote assignment fenced")
    );

    assert!(
        !fixture
            .db
            .select_task_board_local_execution_target(
                &TaskBoardWorkflowExecutionCas::from(&current),
                &TaskBoardExecutionAttemptCas::from(&current_attempt),
                "2026-07-19T10:00:02Z",
            )
            .await
            .expect("unresolved generation still fences local selection")
    );
    assert_eq!(codex_run_count(&fixture).await, 0);
}

#[tokio::test]
async fn raw_terminal_assignments_never_release_the_local_start_fence() {
    for state in ["completed", "failed", "cancelled", "superseded"] {
        let fixture = controller_fixture(1).await;
        offer_controller(&fixture).await;
        force_terminal_assignment(&fixture, state).await;
        restore_parent(&fixture, TaskBoardExecutionState::Preparing).await;
        let current = fixture
            .db
            .task_board_workflow_execution(&fixture.execution.execution_id)
            .await
            .expect("load divergent workflow")
            .expect("divergent workflow exists");
        let attempt = current.attempts[0].clone();
        assert!(
            !fixture
                .db
                .select_task_board_local_execution_target(
                    &TaskBoardWorkflowExecutionCas::from(&current),
                    &TaskBoardExecutionAttemptCas::from(&attempt),
                    "2026-07-19T10:00:03Z",
                )
                .await
                .expect("raw terminal generation remains unresolved"),
            "raw {state} generation selected local work"
        );
        let error = fixture
            .db
            .claim_task_board_workflow_side_effect(
                &TaskBoardWorkflowExecutionCas::from(&current),
                &TaskBoardExecutionAttemptCas::from(&attempt),
                &local_claim(&attempt),
                "2026-07-19T10:00:03Z",
            )
            .await
            .expect_err("raw terminal assignment must fence local claim");
        assert!(
            error
                .to_string()
                .contains("active remote assignment fenced")
        );
        assert_eq!(codex_run_count(&fixture).await, 0);
    }
}

#[tokio::test]
async fn exact_preclaim_fallback_marker_releases_one_distinct_local_attempt() {
    let fixture = controller_fixture(1).await;
    let assignment = match offer_controller(&fixture).await {
        TaskBoardRemoteOfferOutcome::Created(assignment) => assignment,
        other => panic!("expected created remote assignment, got {other:?}"),
    };
    let transaction = fixture
        .db
        .begin_immediate_transaction("test exact controller fallback")
        .await
        .expect("begin fallback transaction");
    assert!(matches!(
        super::remote_assignment_rejection::apply_unclaimable_offer(
            transaction,
            assignment,
            "executor_unavailable",
            "2026-07-19T10:00:02Z",
        )
        .await
        .expect("apply exact local fallback"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    assert!(
        !fixture
            .db
            .task_board_execution_has_active_remote_assignment(&fixture.execution.execution_id)
            .await
            .expect("load settled fallback fence")
    );
    let selected = fixture
        .db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load local fallback")
        .expect("local fallback exists");
    let selected_attempt = selected
        .attempts
        .iter()
        .find(|attempt| attempt.state == TaskBoardAttemptState::Starting)
        .expect("distinct local fallback attempt")
        .clone();
    assert!(
        fixture
            .db
            .claim_task_board_workflow_side_effect(
                &TaskBoardWorkflowExecutionCas::from(&selected),
                &TaskBoardExecutionAttemptCas::from(&selected_attempt),
                &local_claim(&selected_attempt),
                "2026-07-19T10:00:03Z",
            )
            .await
            .expect("claim exact local fallback once")
            .is_some()
    );
}

async fn force_terminal_assignment(
    fixture: &super::remote_assignment_test_support::ControllerFixture,
    state: &str,
) {
    let mut connection = fixture.db.pool().acquire().await.expect("acquire database");
    query("PRAGMA ignore_check_constraints = ON")
        .execute(&mut *connection)
        .await
        .expect("allow corrupt terminal fixture");
    query(
        "UPDATE task_board_remote_assignments
         SET state = ?2, completed_at = ?3, updated_at = ?3
         WHERE assignment_id = ?1",
    )
    .bind(&fixture.request.binding.assignment_id)
    .bind(state)
    .bind("2026-07-19T10:00:02Z")
    .execute(&mut *connection)
    .await
    .expect("force divergent terminal assignment");
    query("PRAGMA ignore_check_constraints = OFF")
        .execute(&mut *connection)
        .await
        .expect("restore strict constraints");
}

async fn restore_parent(
    fixture: &super::remote_assignment_test_support::ControllerFixture,
    state: TaskBoardExecutionState,
) {
    let mut restored = fixture.execution.clone();
    restored.transition.execution_state = state;
    let (_, _, diagnostics, ownership) = execution_json(&restored).expect("encode execution");
    query(
        "UPDATE task_board_workflow_executions
         SET state = ?2, diagnostics_json = ?3, host_id = NULL, fencing_epoch = 0,
             resource_ownership_json = ?4, available_at = NULL, blocked_reason = NULL,
             completed_at = NULL, updated_at = ?5
         WHERE execution_id = ?1",
    )
    .bind(&restored.execution_id)
    .bind(label(state, "workflow execution state").expect("encode execution state"))
    .bind(diagnostics)
    .bind(ownership)
    .bind(&restored.updated_at)
    .execute(fixture.db.pool())
    .await
    .expect("restore parent state");
    query(
        "UPDATE task_board_execution_attempts
         SET state = 'preparing', failure_class = NULL, available_at = NULL,
             error = NULL, artifact_json = NULL, completed_at = NULL, updated_at = ?4
         WHERE execution_id = ?1 AND action_key = ?2 AND attempt = ?3",
    )
    .bind(&fixture.attempt.execution_id)
    .bind(&fixture.attempt.action_key)
    .bind(i64::from(fixture.attempt.attempt))
    .bind(&fixture.attempt.updated_at)
    .execute(fixture.db.pool())
    .await
    .expect("restore attempt state");
}

fn local_claim(attempt: &TaskBoardExecutionAttemptRecord) -> TaskBoardExecutionAttemptRecord {
    let mut claimed = attempt.clone();
    claimed.state = TaskBoardAttemptState::Running;
    claimed.updated_at = "2026-07-19T10:00:03Z".into();
    claimed
}

async fn assignment_count(
    fixture: &super::remote_assignment_test_support::ControllerFixture,
) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_remote_assignments WHERE execution_id = ?1")
        .bind(&fixture.execution.execution_id)
        .fetch_one(fixture.db.pool())
        .await
        .expect("count execution assignments")
}

async fn codex_run_count(
    fixture: &super::remote_assignment_test_support::ControllerFixture,
) -> i64 {
    query_scalar("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(fixture.db.pool())
        .await
        .expect("count local Codex runs")
}
