use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    TaskBoardWorkflowRevisionGuard, validate_plan_approval,
};

use super::attempts::invalid_transition;

pub(super) async fn current_revisions(
    db: &AsyncDaemonDb,
    item_revision: i64,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<(TaskBoardWorkflowRevisionGuard, String), CliError> {
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let configuration_revision = u64::try_from(settings.row_revision)
        .map_err(|_| invalid_transition("orchestrator settings revision is out of range"))?;
    Ok((
        TaskBoardWorkflowRevisionGuard {
            item_revision,
            configuration_revision,
            provider_revision: execution.snapshot.provider_revision.clone(),
        },
        settings.settings.policy_version,
    ))
}

pub(super) fn revisions_match(
    execution: &TaskBoardWorkflowExecutionRecord,
    revisions: &TaskBoardWorkflowRevisionGuard,
    policy_version: &str,
) -> bool {
    revisions == &TaskBoardWorkflowRevisionGuard::from(&execution.snapshot)
        && policy_version == execution.snapshot.policy_version
}

pub(super) async fn invalidate_revisions(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    revisions: &TaskBoardWorkflowRevisionGuard,
    policy_version: &str,
    now: &str,
) -> Result<(), CliError> {
    let mut updated = execution.clone();
    if matches!(
        execution.snapshot.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    ) {
        let mut current_snapshot = execution.snapshot.clone();
        current_snapshot.item_revision = revisions.item_revision;
        current_snapshot.configuration_revision = revisions.configuration_revision;
        current_snapshot
            .provider_revision
            .clone_from(&revisions.provider_revision);
        current_snapshot.policy_version = policy_version.to_string();
        if let (Some(result), Some(binding)) = (
            execution.artifacts.planning_result.as_ref(),
            execution.artifacts.plan_approval.as_ref(),
        ) {
            updated.artifacts.approval_invalidations =
                validate_plan_approval(binding, result, &current_snapshot, &execution.execution_id)
                    .invalidations;
        }
        super::super::task_board_workflow_execution::require_human(
            &mut updated,
            "plan_approval_invalidated",
            now,
        );
    } else {
        super::super::task_board_workflow_execution::require_human(
            &mut updated,
            "frozen_revision_changed",
            now,
        );
    }
    db.compare_and_set_task_board_workflow_execution(
        &TaskBoardWorkflowExecutionCas::from(execution),
        &updated,
    )
    .await?;
    Ok(())
}
