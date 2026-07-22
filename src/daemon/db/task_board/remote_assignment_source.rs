use sqlx::{Sqlite, Transaction, query_scalar};

use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferRequest, RemoteRepositorySelector, RemoteSourceMaterial,
};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardImplementationResult, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
};

pub(super) async fn source_binding_matches_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Result<bool, CliError> {
    if !source_binding_matches(request, parent) {
        return Ok(false);
    }
    let RemoteSourceMaterial::PriorPhaseBundle { repository, .. } = &request.source else {
        return Ok(true);
    };
    let Some((attempt, result)) = prior_implementation(parent) else {
        return Ok(false);
    };
    let repositories = query_scalar::<_, Option<String>>(
        "SELECT json_extract(origin.request_json, '$.source.repository')
         FROM task_board_remote_result_imports imported
         JOIN task_board_remote_assignments origin
           ON origin.assignment_id = imported.assignment_id
          AND origin.fencing_epoch = imported.fencing_epoch
         WHERE imported.execution_id = ?1 AND imported.action_key = ?2
           AND imported.attempt = ?3 AND imported.idempotency_key = ?4
           AND imported.base_revision = ?5 AND imported.result_revision = ?6
           AND imported.state = 'adopted'
         ORDER BY imported.assignment_id, imported.fencing_epoch",
    )
    .bind(&parent.execution_id)
    .bind(&attempt.action_key)
    .bind(i64::from(attempt.attempt))
    .bind(&attempt.idempotency_key)
    .bind(&result.base_head_revision)
    .bind(&result.head_revision)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify prior remote source repository: {error}")))?;
    Ok(matches!(repositories.as_slice(), [Some(origin)] if origin == repository))
}

pub(super) fn source_binding_matches(
    request: &RemoteOfferRequest,
    parent: &TaskBoardWorkflowExecutionRecord,
) -> bool {
    match &request.source {
        RemoteSourceMaterial::Repository {
            repository,
            selector,
            revision,
            ..
        } => repository_source_matches(parent, repository, selector, revision),
        RemoteSourceMaterial::PriorPhaseBundle {
            repository,
            base_revision,
            revision,
            ..
        } => bundle_source_matches(parent, repository, base_revision, revision),
        RemoteSourceMaterial::RepositorySnapshotBundle {
            repository,
            revision,
            ..
        } => {
            parent.snapshot.workflow_kind == TaskBoardWorkflowKind::DefaultTask
                && parent.transition.phase == Some(TaskBoardExecutionPhase::Implementation)
                && parent.artifacts.current_revision_cycle == 1
                && parent.snapshot.execution_repository.as_deref() == Some(repository)
                && initial_implementation_revision(parent) == Some(revision)
        }
    }
}

fn repository_source_matches(
    parent: &TaskBoardWorkflowExecutionRecord,
    repository: &str,
    selector: &RemoteRepositorySelector,
    revision: &str,
) -> bool {
    let expected_revision = initial_repository_revision(parent);
    if expected_revision != Some(revision) {
        return false;
    }
    let fork_head = parent
        .transition
        .pull_request
        .as_ref()
        .and_then(|pull_request| pull_request.head.as_ref())
        .filter(|_| {
            matches!(
                parent.snapshot.workflow_kind,
                TaskBoardWorkflowKind::PrFix | TaskBoardWorkflowKind::PrReview
            )
        });
    if let Some(head) = fork_head {
        return repository == head.repository.as_str()
            && matches!(
                selector,
                RemoteRepositorySelector::Branch { branch, reference }
                    if branch == &head.branch
                        && reference == &format!("refs/heads/{}", head.branch)
            );
    }
    parent.snapshot.execution_repository.as_deref() == Some(repository)
        && *selector == RemoteRepositorySelector::ExactRevision
}

fn initial_repository_revision(parent: &TaskBoardWorkflowExecutionRecord) -> Option<&str> {
    match parent.transition.phase {
        Some(TaskBoardExecutionPhase::Implementation)
            if parent.artifacts.current_revision_cycle == 1 =>
        {
            initial_implementation_revision(parent)
        }
        Some(TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate) => {
            if matches!(
                parent.snapshot.workflow_kind,
                TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
            ) {
                None
            } else {
                parent.transition.exact_head_revision.as_deref()
            }
        }
        _ => None,
    }
}

fn initial_implementation_revision(parent: &TaskBoardWorkflowExecutionRecord) -> Option<&str> {
    if parent.snapshot.workflow_kind == TaskBoardWorkflowKind::PrFix {
        return parent
            .transition
            .pull_request
            .as_ref()?
            .head
            .as_ref()
            .map(|head| head.revision.as_str());
    }
    parent.transition.exact_head_revision.as_deref()
}

fn bundle_source_matches(
    parent: &TaskBoardWorkflowExecutionRecord,
    _repository: &str,
    base_revision: &str,
    revision: &str,
) -> bool {
    let cycle = match parent.transition.phase {
        Some(TaskBoardExecutionPhase::Implementation) => {
            parent.artifacts.current_revision_cycle.checked_sub(1)
        }
        Some(TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate) => {
            Some(parent.artifacts.current_revision_cycle)
        }
        _ => None,
    };
    let Some(result) = cycle.and_then(|cycle| implementation_result(parent, cycle)) else {
        return false;
    };
    result.base_head_revision == base_revision
        && result.head_revision == revision
        && parent.transition.exact_head_revision.as_deref() == Some(revision)
}

fn prior_implementation(
    parent: &TaskBoardWorkflowExecutionRecord,
) -> Option<(&TaskBoardExecutionAttemptRecord, &TaskBoardImplementationResult)> {
    let cycle = match parent.transition.phase {
        Some(TaskBoardExecutionPhase::Implementation) => {
            parent.artifacts.current_revision_cycle.checked_sub(1)
        }
        Some(TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate) => {
            Some(parent.artifacts.current_revision_cycle)
        }
        _ => None,
    }?;
    let matches = parent.attempts.iter().filter_map(|attempt| {
        let Some(TaskBoardAttemptResultArtifact::Implementation(result)) = &attempt.artifact else {
            return None;
        };
        (result.revision_cycle == cycle).then_some((attempt, result))
    });
    let collected = matches.collect::<Vec<_>>();
    match collected.as_slice() {
        [one] => Some(*one),
        _ => None,
    }
}

fn implementation_result(
    parent: &TaskBoardWorkflowExecutionRecord,
    cycle: u32,
) -> Option<&TaskBoardImplementationResult> {
    parent.attempts.iter().find_map(|attempt| {
        let Some(TaskBoardAttemptResultArtifact::Implementation(result)) = &attempt.artifact else {
            return None;
        };
        (result.revision_cycle == cycle).then_some(result)
    })
}
