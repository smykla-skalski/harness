use super::ITEMS_CHANGE_SCOPE;
use super::admission_lifecycle::{
    ensure_item_admission_can_terminate_in_tx, release_managed_worker_admission_in_tx,
};
use super::items::{bump_change_in_tx, load_item_in_tx, replace_item_in_tx};
use super::workflow_executions::load_execution_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::TaskBoardItem;

#[path = "workflow_terminal_projection.rs"]
mod projection;
use projection::{
    apply_terminal_target, item_identity_matches, terminal_target, validate_terminal_execution,
};

#[derive(Debug)]
pub(crate) struct TaskBoardWorkflowTerminalProjection {
    pub(crate) item: TaskBoardItem,
    pub(crate) item_revision: i64,
    pub(crate) item_changed: bool,
    pub(crate) admission_released: bool,
}

impl AsyncDaemonDb {
    pub(crate) async fn recover_orphaned_task_board_read_only_workflow_admissions(
        &self,
    ) -> Result<Vec<String>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("read-only workflow admission recovery")
            .await?;
        let owners = sqlx::query_scalar::<_, String>(
            "SELECT DISTINCT managed_worker_id
             FROM task_board_dispatch_admission_ledger
             WHERE kind = 'concurrency' AND state = 'committed'
               AND managed_worker_id LIKE 'workflow-%'
             ORDER BY managed_worker_id",
        )
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load read-only workflow admissions: {error}")))?;
        let mut released = Vec::new();
        for owner in owners {
            let Some(execution_id) = owner
                .strip_prefix("workflow-")
                .filter(|value| !value.is_empty())
            else {
                continue;
            };
            let retained = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(
                     SELECT 1 FROM task_board_workflow_executions WHERE execution_id = ?1
                 )",
            )
            .bind(execution_id)
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("check read-only workflow admission: {error}")))?;
            if !retained && release_managed_worker_admission_in_tx(&mut transaction, &owner).await?
            {
                released.push(owner);
            }
        }
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit read-only workflow admission recovery: {error}"
            ))
        })?;
        Ok(released)
    }

    pub(crate) async fn project_task_board_read_only_workflow_terminal(
        &self,
        execution_id: &str,
    ) -> Result<TaskBoardWorkflowTerminalProjection, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("read-only workflow terminal projection")
            .await?;
        let execution = load_execution_in_tx(&mut transaction, execution_id)
            .await?
            .ok_or_else(|| db_error(format!("workflow execution '{execution_id}' not found")))?;
        let owner = validate_terminal_execution(&execution)?;
        let (mut item, item_revision) = load_item_in_tx(&mut transaction, &execution.item_id)
            .await?
            .ok_or_else(|| {
                db_error(format!("task-board item '{}' not found", execution.item_id))
            })?;
        if !item_identity_matches(&item, &execution) {
            let admission_released =
                release_managed_worker_admission_in_tx(&mut transaction, &owner).await?;
            transaction.commit().await.map_err(|error| {
                db_error(format!(
                    "commit detached read-only workflow admission release: {error}"
                ))
            })?;
            return Ok(TaskBoardWorkflowTerminalProjection {
                item,
                item_revision,
                item_changed: false,
                admission_released,
            });
        }
        let target = terminal_target(&execution)?;
        let item_changed = apply_terminal_target(&mut item, &target);
        let admission_released =
            release_managed_worker_admission_in_tx(&mut transaction, &owner).await?;
        ensure_item_admission_can_terminate_in_tx(&mut transaction, &execution.item_id).await?;
        let projected_revision = if item_changed {
            item.updated_at = utc_now();
            let projected_revision = item_revision.saturating_add(1);
            replace_item_in_tx(&mut transaction, &item, projected_revision).await?;
            if !admission_released {
                bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
            }
            projected_revision
        } else {
            item_revision
        };
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit read-only workflow terminal projection: {error}"
            ))
        })?;
        Ok(TaskBoardWorkflowTerminalProjection {
            item,
            item_revision: projected_revision,
            item_changed,
            admission_released,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use tempfile::tempdir;

    use super::super::workflow_dispatch::workflow_owner;
    use super::*;
    use crate::task_board::{
        TaskBoardExecutionOwnership, TaskBoardExecutionPhase, TaskBoardExecutionState,
        TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind,
        TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowExecutionCas,
        TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
        TaskBoardWorkflowStatus, TaskBoardWorkflowTransitionState, resolve_task_board_reviewers,
    };

    const NOW: &str = "2026-07-17T10:00:00Z";

    #[tokio::test]
    async fn terminal_projection_updates_item_and_releases_admission_once() {
        let (db, execution_id) = seeded_terminal_execution(true).await;

        let projected = db
            .project_task_board_read_only_workflow_terminal(&execution_id)
            .await
            .expect("project terminal execution");

        assert!(projected.item_changed);
        assert!(projected.admission_released);
        assert_eq!(projected.item_revision, 2);
        assert_eq!(
            projected.item.status,
            crate::task_board::TaskBoardStatus::Done
        );
        assert_eq!(
            projected.item.workflow.status,
            TaskBoardWorkflowStatus::Completed
        );
        assert!(projected.item.workflow.current_step_id.is_none());
        assert!(projected.item.workflow.last_error.is_none());
        assert_eq!(ledger_state(&db, &execution_id).await, "released");
        let sequence = db.current_change_sequence().await.expect("change sequence");

        let duplicate = db
            .project_task_board_read_only_workflow_terminal(&execution_id)
            .await
            .expect("repeat terminal projection");

        assert!(!duplicate.item_changed);
        assert!(!duplicate.admission_released);
        assert_eq!(duplicate.item_revision, 2);
        assert_eq!(
            db.current_change_sequence().await.expect("change sequence"),
            sequence
        );
    }

    #[tokio::test]
    async fn item_identity_mismatch_releases_only_the_old_workflow_admission() {
        let (db, execution_id) = seeded_terminal_execution(false).await;

        let projected = db
            .project_task_board_read_only_workflow_terminal(&execution_id)
            .await
            .expect("release detached workflow admission");

        assert!(!projected.item_changed);
        assert!(projected.admission_released);
        assert_eq!(ledger_state(&db, &execution_id).await, "released");
        let item = db
            .task_board_item("terminal-item")
            .await
            .expect("load item");
        assert_eq!(item.status, crate::task_board::TaskBoardStatus::InProgress);
        assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Running);
    }

    #[tokio::test]
    async fn completed_projection_preserves_an_item_revision_change() {
        let (db, execution_id) = seeded_terminal_execution(true).await;
        sqlx::query("UPDATE task_board_items SET title = 'Edited', revision = 2 WHERE item_id = 'terminal-item'")
            .execute(db.pool())
            .await
            .expect("model an edit after workflow completion");

        let projected = db
            .project_task_board_read_only_workflow_terminal(&execution_id)
            .await
            .expect("project completed outcome");

        assert!(projected.item_changed);
        assert!(projected.admission_released);
        assert_eq!(projected.item_revision, 3);
        assert_eq!(projected.item.title, "Edited");
        assert_eq!(
            projected.item.status,
            crate::task_board::TaskBoardStatus::Done
        );
        assert_eq!(ledger_state(&db, &execution_id).await, "released");
    }

    #[tokio::test]
    async fn human_required_projection_survives_an_item_revision_change() {
        let (db, execution_id) = seeded_terminal_execution(true).await;
        let current = db
            .task_board_workflow_execution(&execution_id)
            .await
            .expect("load execution")
            .expect("execution exists");
        let mut updated = current.clone();
        updated.transition.execution_state = TaskBoardExecutionState::HumanRequired;
        updated.blocked_reason = Some("attempt_outcome_unknown".into());
        updated.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
            kind: TaskBoardTerminalOutcomeKind::Unknown,
            summary: "attempt outcome is unknown".into(),
            recorded_at: NOW.into(),
        });
        db.compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&current),
            &updated,
        )
        .await
        .expect("require human review");
        sqlx::query("UPDATE task_board_items SET revision = 2 WHERE item_id = 'terminal-item'")
            .execute(db.pool())
            .await
            .expect("model a concurrent item edit");

        let projected = db
            .project_task_board_read_only_workflow_terminal(&execution_id)
            .await
            .expect("project human-required outcome");

        assert!(projected.item_changed);
        assert!(projected.admission_released);
        assert_eq!(projected.item_revision, 3);
        assert_eq!(
            projected.item.status,
            crate::task_board::TaskBoardStatus::HumanRequired
        );
        assert_eq!(ledger_state(&db, &execution_id).await, "released");
    }

    #[tokio::test]
    async fn startup_recovery_releases_only_owners_without_an_execution() {
        let (db, execution_id) = seeded_active_execution().await;

        let retained = db
            .recover_orphaned_task_board_read_only_workflow_admissions()
            .await
            .expect("retain active workflow admission");

        assert!(retained.is_empty());
        assert_eq!(ledger_state(&db, &execution_id).await, "committed");

        sqlx::query("DELETE FROM task_board_workflow_executions WHERE execution_id = ?1")
            .bind(&execution_id)
            .execute(db.pool())
            .await
            .expect("remove execution to model orphaned admission");
        let owner = workflow_owner(&execution_id);

        let released = db
            .recover_orphaned_task_board_read_only_workflow_admissions()
            .await
            .expect("release orphaned workflow admission");

        assert_eq!(released, vec![owner]);
        assert_eq!(ledger_state(&db, &execution_id).await, "released");
    }

    #[test]
    fn terminal_states_have_explicit_item_projections() {
        let mut execution = terminal_execution("execution", "terminal-item", 1);
        for (state, item_status, workflow_status) in [
            (
                TaskBoardExecutionState::Completed,
                crate::task_board::TaskBoardStatus::Done,
                TaskBoardWorkflowStatus::Completed,
            ),
            (
                TaskBoardExecutionState::HumanRequired,
                crate::task_board::TaskBoardStatus::HumanRequired,
                TaskBoardWorkflowStatus::Paused,
            ),
            (
                TaskBoardExecutionState::Failed,
                crate::task_board::TaskBoardStatus::Failed,
                TaskBoardWorkflowStatus::Failed,
            ),
            (
                TaskBoardExecutionState::Cancelled,
                crate::task_board::TaskBoardStatus::Failed,
                TaskBoardWorkflowStatus::Cancelled,
            ),
        ] {
            execution.transition.execution_state = state;
            let target = terminal_target(&execution).expect("terminal target");
            assert_eq!(target.item_status, item_status);
            assert_eq!(target.workflow_status, workflow_status);
        }
    }

    async fn seeded_terminal_execution(correct_identity: bool) -> (AsyncDaemonDb, String) {
        seeded_execution(correct_identity, true).await
    }

    async fn seeded_active_execution() -> (AsyncDaemonDb, String) {
        seeded_execution(true, false).await
    }

    async fn seeded_execution(correct_identity: bool, terminal: bool) -> (AsyncDaemonDb, String) {
        let directory = tempdir().expect("tempdir").keep();
        let db = AsyncDaemonDb::connect(&directory.join("harness.db"))
            .await
            .expect("open database");
        let execution_id = "execution-terminal".to_string();
        let mut item = TaskBoardItem::new(
            "terminal-item".into(),
            "Read-only review".into(),
            String::new(),
            NOW.into(),
        );
        item.status = crate::task_board::TaskBoardStatus::InProgress;
        item.workflow_kind = TaskBoardWorkflowKind::Review;
        item.workflow.execution_id = Some(if correct_identity {
            execution_id.clone()
        } else {
            "execution-other".into()
        });
        item.workflow.status = TaskBoardWorkflowStatus::Running;
        item.workflow.current_step_id = Some("review".into());
        db.create_task_board_item(item)
            .await
            .expect("create task-board item");
        let mut execution = terminal_execution(&execution_id, "terminal-item", 1);
        if !terminal {
            execution.transition.phase = Some(TaskBoardExecutionPhase::Review);
            execution.transition.execution_state = TaskBoardExecutionState::Running;
            execution.artifacts.terminal_outcome = None;
            execution.completed_at = None;
        }
        db.create_or_load_task_board_workflow_execution(&execution)
            .await
            .expect("create workflow execution");
        insert_committed_admission(&db, &execution_id).await;
        (db, execution_id)
    }

    fn terminal_execution(
        execution_id: &str,
        item_id: &str,
        item_revision: i64,
    ) -> TaskBoardWorkflowExecutionRecord {
        let reviewers = resolve_task_board_reviewers(
            &crate::task_board::TaskBoardReviewerSettings::default(),
            TaskBoardWorkflowKind::Review,
            None,
        )
        .expect("resolve reviewers");
        TaskBoardWorkflowExecutionRecord {
            execution_id: execution_id.into(),
            item_id: item_id.into(),
            snapshot: TaskBoardWorkflowSnapshot {
                workflow_kind: TaskBoardWorkflowKind::Review,
                execution_repository: None,
                item_revision,
                configuration_revision: 1,
                policy_version: crate::task_board::policy::POLICY_VERSION.into(),
                reviewer: reviewers.clone(),
                read_only_run_context: Some(crate::task_board::TaskBoardReadOnlyRunContext {
                    schema_version: crate::task_board::TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
                    session_id: format!("session-{item_id}"),
                    title: "Terminal workflow".into(),
                    body: "Terminal projection fixture".into(),
                    tags: Vec::new(),
                    worktree: "/tmp/read-only-worktree".into(),
                }),
                provider_revision: None,
            },
            resolved_reviewers: reviewers,
            transition: TaskBoardWorkflowTransitionState {
                workflow_kind: TaskBoardWorkflowKind::Review,
                phase: Some(TaskBoardExecutionPhase::Terminal),
                execution_state: TaskBoardExecutionState::Completed,
                pull_request: None,
                exact_head_revision: Some("head-frozen".into()),
            },
            artifacts: TaskBoardWorkflowExecutionArtifacts {
                terminal_outcome: Some(TaskBoardTerminalOutcome {
                    kind: TaskBoardTerminalOutcomeKind::Succeeded,
                    summary: "review completed".into(),
                    recorded_at: NOW.into(),
                }),
                ..TaskBoardWorkflowExecutionArtifacts::default()
            },
            ownership: TaskBoardExecutionOwnership {
                host_id: None,
                fencing_epoch: 0,
                resources: BTreeMap::from([(
                    "admission_owner".into(),
                    workflow_owner(execution_id),
                )]),
            },
            available_at: None,
            blocked_reason: None,
            created_at: NOW.into(),
            updated_at: NOW.into(),
            completed_at: Some(NOW.into()),
            attempts: Vec::new(),
        }
    }

    async fn insert_committed_admission(db: &AsyncDaemonDb, execution_id: &str) {
        sqlx::query(
            "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, attempts, available_at, created_at, updated_at, completed_at
             ) VALUES ('intent-terminal', 'terminal-item', 'session-terminal', 'work-terminal',
                       ?1, '{}', 'completed', 1, ?2, ?2, ?2, ?2)",
        )
        .bind(execution_id)
        .bind(NOW)
        .execute(db.pool())
        .await
        .expect("insert completed dispatch intent");
        sqlx::query(
            "INSERT INTO task_board_dispatch_admission_decisions (
             decision_id, intent_id, generation, item_id, item_revision, settings_revision,
             decision, policy_json, context_json, requirements_json, blockers_json,
             launch_profile, evaluated_at, is_current, created_at
             ) VALUES ('decision-terminal', 'intent-terminal', 1, 'terminal-item', 1, 1,
                       'allowed', '{}', '{}', '[]', '[]', 'read_only', ?1, 1, ?1)",
        )
        .bind(NOW)
        .execute(db.pool())
        .await
        .expect("insert admission decision");
        sqlx::query(
            "INSERT INTO task_board_dispatch_admission_ledger (
             ledger_id, decision_id, decision, intent_id, generation, item_id,
             canonical_key, kind, scope, amount, limit_value, state, managed_worker_id,
             reserved_at, committed_at
             ) VALUES (?1, 'decision-terminal', 'allowed', 'intent-terminal', 1,
                       'terminal-item', 'concurrency:global', 'concurrency', 'global', 1, 1,
                       'committed', ?2, ?3, ?3)",
        )
        .bind(format!("ledger-{execution_id}"))
        .bind(workflow_owner(execution_id))
        .bind(NOW)
        .execute(db.pool())
        .await
        .expect("insert committed admission");
    }

    async fn ledger_state(db: &AsyncDaemonDb, execution_id: &str) -> String {
        sqlx::query_scalar(
            "SELECT state FROM task_board_dispatch_admission_ledger WHERE ledger_id = ?1",
        )
        .bind(format!("ledger-{execution_id}"))
        .fetch_one(db.pool())
        .await
        .expect("load admission state")
    }
}
