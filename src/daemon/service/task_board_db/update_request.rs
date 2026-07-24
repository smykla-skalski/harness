use crate::daemon::protocol::TaskBoardUpdateItemRequest;
use crate::errors::CliError;
use crate::task_board::{ExternalRef, PlanningState, TaskBoardItem, TaskBoardWorkflowState};

use super::estimate_validation::validate_update_estimates;

pub(super) fn apply_update_request(
    item: &mut TaskBoardItem,
    request: &TaskBoardUpdateItemRequest,
) -> Result<(), CliError> {
    validate_update_estimates(request)?;
    assign_if_some(&mut item.title, request.title.as_ref());
    assign_if_some(&mut item.body, request.body.as_ref());
    assign_copy_if_some(&mut item.status, request.status);
    assign_copy_if_some(&mut item.priority, request.priority);
    assign_copy_if_some(&mut item.agent_mode, request.agent_mode);
    assign_copy_if_some(&mut item.workflow_kind, request.workflow_kind);
    assign_if_some(&mut item.kind, request.kind.as_ref());
    assign_if_some(&mut item.tags, request.tags.as_ref());
    assign_if_some(
        &mut item.target_project_types,
        request.target_project_types.as_ref(),
    );
    if let Some(replacements) = request.external_refs.as_deref() {
        item.external_refs = replacement_external_refs(&item.external_refs, replacements);
    }
    apply_optional_string(
        &mut item.project_id,
        request.project_id.as_ref(),
        request.clear_identity.clear_project_id,
    );
    apply_optional_string(
        &mut item.execution_repository,
        request.execution_repository.as_ref(),
        request.clear_identity.clear_execution_repository,
    );
    apply_optional_copy(
        &mut item.estimated_tokens,
        request.estimated_tokens,
        request.clear_estimates.clear_estimated_tokens,
    );
    apply_optional_copy(
        &mut item.estimated_cost_microusd,
        request.estimated_cost_microusd,
        request.clear_estimates.clear_estimated_cost_microusd,
    );
    apply_optional_string(
        &mut item.session_id,
        request.session_id.as_ref(),
        request.clear_identity.clear_session_id,
    );
    apply_optional_string(
        &mut item.work_item_id,
        request.work_item_id.as_ref(),
        request.clear_identity.clear_work_item_id,
    );
    apply_optional_string(
        &mut item.parent_item_id,
        request.parent_item_id.as_ref(),
        request.clear_identity.clear_parent_item_id,
    );
    apply_update_state(item, request);
    Ok(())
}

pub(super) fn replacement_external_refs(
    current: &[ExternalRef],
    replacements: &[ExternalRef],
) -> Vec<ExternalRef> {
    replacements
        .iter()
        .map(|replacement| ExternalRef {
            provider: replacement.provider,
            external_id: replacement.external_id.clone(),
            url: replacement.url.clone(),
            sync_state: current
                .iter()
                .find(|candidate| {
                    candidate.provider == replacement.provider
                        && candidate.external_id == replacement.external_id
                })
                .and_then(|candidate| candidate.sync_state.clone()),
        })
        .collect()
}

fn apply_update_state(item: &mut TaskBoardItem, request: &TaskBoardUpdateItemRequest) {
    if request.clear_state.clear_planning {
        item.planning = PlanningState::default();
    } else if let Some(planning) = &request.planning {
        if planning.summary.is_some() {
            item.planning.clone_from(planning);
        } else if planning.approved_by.is_some() {
            item.planning.approved_by.clone_from(&planning.approved_by);
            item.planning.approved_at.clone_from(&planning.approved_at);
        }
    }
    if request.clear_state.clear_workflow {
        item.workflow = TaskBoardWorkflowState::default();
    } else if let Some(workflow) = &request.workflow {
        item.workflow.clone_from(workflow);
    }
}

fn assign_if_some<T: Clone>(target: &mut T, value: Option<&T>) {
    if let Some(value) = value {
        target.clone_from(value);
    }
}

fn assign_copy_if_some<T: Copy>(target: &mut T, value: Option<T>) {
    if let Some(value) = value {
        *target = value;
    }
}

fn apply_optional_copy<T: Copy>(target: &mut Option<T>, value: Option<T>, clear: bool) {
    if clear {
        *target = None;
    } else if let Some(value) = value {
        *target = Some(value);
    }
}

fn apply_optional_string(target: &mut Option<String>, value: Option<&String>, clear: bool) {
    if clear {
        *target = None;
    } else if let Some(value) = value {
        *target = Some(value.clone());
    }
}
