use tokio::task::spawn_blocking;

use super::super::super::db::{
    AsyncDaemonDb, REMOTE_IMPLEMENTATION_BUNDLE_PATH, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteResultAdoptionOutcome, TaskBoardRemoteResultImportRequest,
};
use super::super::super::task_board_remote_transport::wire::RemoteAssignmentWireState;
use crate::errors::{CliError, CliErrorKind};
use crate::git::bundle::{GitBundleImportEvidence, GitBundleImportPlan};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardExecutionPhase, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

pub(crate) async fn import_and_adopt_task_board_remote_implementation_result(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<TaskBoardRemoteResultAdoptionOutcome, CliError> {
    let (expected, request, execution_id) =
        import_request(db, assignment_id, fencing_epoch).await?;
    Box::pin(super::import_task_board_remote_implementation_result(
        db, &expected, &request,
    ))
    .await?;
    let parent = db
        .task_board_workflow_execution(&execution_id)
        .await?
        .ok_or_else(|| concurrent("remote implementation execution disappeared before adoption"))?;
    let outcome = db
        .adopt_task_board_remote_terminal_result(
            &TaskBoardWorkflowExecutionCas::from(&parent),
            assignment_id,
            fencing_epoch,
        )
        .await?;
    if matches!(
        outcome,
        TaskBoardRemoteResultAdoptionOutcome::Updated(_)
            | TaskBoardRemoteResultAdoptionOutcome::Replayed(_)
    ) {
        super::cleanup_task_board_remote_result_import(db, assignment_id, fencing_epoch).await?;
    }
    Ok(outcome)
}

async fn import_request(
    db: &AsyncDaemonDb,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<
    (
        TaskBoardWorkflowExecutionCas,
        TaskBoardRemoteResultImportRequest,
        String,
    ),
    CliError,
> {
    let assignment = db
        .task_board_remote_assignment(assignment_id)
        .await?
        .ok_or_else(|| concurrent("remote implementation assignment disappeared"))?;
    if assignment.fencing_epoch != fencing_epoch
        || assignment.phase != TaskBoardExecutionPhase::Implementation
        || assignment.wire_state() != RemoteAssignmentWireState::Completed
    {
        return Err(concurrent(
            "remote implementation result changed before import",
        ));
    }
    let parent = db
        .task_board_workflow_execution(&assignment.execution_id)
        .await?
        .ok_or_else(|| concurrent("remote implementation execution disappeared"))?;
    let plan = import_plan_evidence(import_plan_input(&assignment, &parent)?).await?;
    let request = TaskBoardRemoteResultImportRequest {
        assignment_id: assignment.assignment_id,
        fencing_epoch: assignment.fencing_epoch,
        worktree_path: plan.worktree_path,
        git_dir: plan.git_dir,
        common_git_dir: plan.common_git_dir,
        branch_ref: plan.branch_ref,
        base_revision: plan.base_revision,
        result_revision: plan.result_revision,
        advertised_ref: plan.advertised_ref,
        import_ref: plan.import_ref,
        object_format: plan.object_format,
        prepared_at: crate::workspace::utc_now(),
    };
    Ok((
        TaskBoardWorkflowExecutionCas::from(&parent),
        request,
        assignment.execution_id,
    ))
}

struct ImportPlanInput {
    worktree_path: String,
    branch_ref: String,
    base_revision: String,
    result_revision: String,
    advertised_ref: String,
    import_ref: String,
}

fn import_plan_input(
    assignment: &TaskBoardRemoteAssignmentRecord,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<ImportPlanInput, CliError> {
    let status = assignment
        .status_response
        .as_ref()
        .ok_or_else(|| concurrent("remote implementation terminal status disappeared"))?;
    let typed = status
        .result
        .as_ref()
        .ok_or_else(|| concurrent("remote implementation typed result disappeared"))?;
    let TaskBoardAttemptResultArtifact::Implementation(result) = &typed.result.artifact else {
        return Err(concurrent(
            "remote implementation terminal result has the wrong artifact kind",
        ));
    };
    let bundle = status
        .output_artifacts
        .entries
        .iter()
        .find(|entry| entry.relative_path == REMOTE_IMPLEMENTATION_BUNDLE_PATH)
        .ok_or_else(|| concurrent("remote implementation bundle manifest disappeared"))?;
    let context = parent
        .snapshot
        .read_only_run_context
        .as_ref()
        .ok_or_else(|| concurrent("remote implementation has no frozen run context"))?;
    let offer = assignment.require_offer()?;
    Ok(ImportPlanInput {
        worktree_path: context.worktree.clone(),
        branch_ref: format!("refs/heads/harness/{}", context.session_id),
        base_revision: result.base_head_revision.clone(),
        result_revision: result.head_revision.clone(),
        advertised_ref: format!("refs/harness/task-board/results/{}", result.head_revision),
        import_ref: format!(
            "refs/harness/task-board/imports/{}/{}",
            offer.request_sha256, bundle.sha256
        ),
    })
}

async fn import_plan_evidence(input: ImportPlanInput) -> Result<GitBundleImportEvidence, CliError> {
    spawn_blocking(move || {
        GitBundleImportPlan::new(
            std::path::Path::new(&input.worktree_path),
            input.branch_ref,
            input.base_revision,
            input.result_revision,
            input.advertised_ref,
            input.import_ref,
        )
        .and_then(|plan| plan.evidence())
    })
    .await
    .map_err(|error| {
        CliErrorKind::workflow_io(format!("remote import request worker failed: {error}"))
    })?
    .map_err(|error| CliError::from(CliErrorKind::workflow_io(error.to_string())))
}

fn concurrent(detail: &str) -> CliError {
    CliErrorKind::concurrent_modification(detail.to_string()).into()
}
