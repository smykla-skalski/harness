use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::types::{ExternalRef, ExternalRefSyncState, TaskBoardItem};
use crate::workspace::utc_now;

use crate::task_board::external::{
    ExternalProvider, ExternalProviderCapabilities, ExternalSyncAction, ExternalSyncField,
    ExternalSyncOperation, ExternalTask, ExternalTaskRef,
};

pub(super) fn has_reported_conflict(
    operations: &[ExternalSyncOperation],
    provider: ExternalProvider,
    item_id: &str,
) -> bool {
    operations.iter().any(|operation| {
        operation.provider == provider
            && matches!(operation.action, ExternalSyncAction::Conflict)
            && operation.board_item_id.as_deref() == Some(item_id)
    })
}

pub(super) fn pull_conflict_fields(
    item: &TaskBoardItem,
    task: &ExternalTask,
) -> Vec<ExternalSyncField> {
    let Some(reference) = matching_ref(item, &task.reference, task.project_id.as_deref()) else {
        return Vec::new();
    };
    match &reference.sync_state {
        Some(state) => {
            let local = local_fields_changed_since_sync(item, state);
            let remote = remote_fields_changed_since_sync(task, state);
            intersect_fields(local, &remote)
        }
        None => item_remote_diff_fields(item, task),
    }
}

pub(super) fn local_update_fields(
    item: &TaskBoardItem,
    reference: &ExternalTaskRef,
    capabilities: &ExternalProviderCapabilities,
) -> Vec<ExternalSyncField> {
    matching_ref(item, reference, item.project_id.as_deref())
        .and_then(|reference| reference.sync_state.as_ref())
        .map_or_else(
            || capabilities.update_fields.clone(),
            |state| local_fields_changed_since_sync(item, state),
        )
}

pub(super) fn split_supported_fields(
    fields: &[ExternalSyncField],
    capabilities: &ExternalProviderCapabilities,
) -> (Vec<ExternalSyncField>, Vec<ExternalSyncField>) {
    fields
        .iter()
        .copied()
        .partition(|field| capabilities.supports_update(*field))
}

pub(super) fn replace_synced_ref(
    item: &TaskBoardItem,
    current: &ExternalTaskRef,
    updated: &ExternalTaskRef,
) -> Vec<ExternalRef> {
    let provider = current.provider.into();
    item.external_refs
        .iter()
        .map(|candidate| {
            if candidate.provider == provider && candidate.external_id == current.external_id {
                synced_ref_from_item(updated.clone(), item)
            } else {
                candidate.clone()
            }
        })
        .collect()
}

pub(super) fn synced_ref_from_item(
    reference: ExternalTaskRef,
    item: &TaskBoardItem,
) -> ExternalRef {
    let mut reference = reference.into_core_ref();
    reference.sync_state = Some(sync_state_from_item(item));
    reference
}

pub(super) fn sync_state_from_task(task: &ExternalTask) -> ExternalRefSyncState {
    ExternalRefSyncState {
        title: Some(task.title.clone()),
        body: Some(task.body.clone()),
        status: Some(task.status),
        project_id: task.project_id.clone(),
        updated_at: task.updated_at.clone(),
        synced_at: Some(utc_now()),
    }
}

pub(super) fn pull_create_fields(task: &ExternalTask) -> Vec<ExternalSyncField> {
    let mut fields = vec![
        ExternalSyncField::Title,
        ExternalSyncField::Body,
        ExternalSyncField::Status,
    ];
    if task.project_id.is_some() {
        fields.push(ExternalSyncField::Project);
    }
    if task.reference.url.is_some() {
        fields.push(ExternalSyncField::Url);
    }
    fields
}

pub(super) fn push_create_fields(item: &TaskBoardItem) -> Vec<ExternalSyncField> {
    let mut fields = vec![
        ExternalSyncField::Title,
        ExternalSyncField::Body,
        ExternalSyncField::Status,
    ];
    if item.project_id.is_some() {
        fields.push(ExternalSyncField::Project);
    }
    fields
}

pub(super) fn changed_fields(patch: &TaskBoardItemPatch) -> Vec<ExternalSyncField> {
    let mut fields = Vec::new();
    push_if(&mut fields, patch.title.is_some(), ExternalSyncField::Title);
    push_if(&mut fields, patch.body.is_some(), ExternalSyncField::Body);
    push_if(
        &mut fields,
        patch.status.is_some(),
        ExternalSyncField::Status,
    );
    push_if(
        &mut fields,
        !matches!(patch.project_id, OptionalFieldPatch::Unchanged),
        ExternalSyncField::Project,
    );
    fields
}

fn sync_state_from_item(item: &TaskBoardItem) -> ExternalRefSyncState {
    ExternalRefSyncState {
        title: Some(item.title.clone()),
        body: Some(item.body.clone()),
        status: Some(item.status),
        project_id: item.project_id.clone(),
        updated_at: None,
        synced_at: Some(utc_now()),
    }
}

fn item_remote_diff_fields(item: &TaskBoardItem, task: &ExternalTask) -> Vec<ExternalSyncField> {
    let mut fields = Vec::new();
    push_if(
        &mut fields,
        item.title != task.title,
        ExternalSyncField::Title,
    );
    push_if(&mut fields, item.body != task.body, ExternalSyncField::Body);
    push_if(
        &mut fields,
        item.status != task.status,
        ExternalSyncField::Status,
    );
    push_if(
        &mut fields,
        item.project_id != task.project_id,
        ExternalSyncField::Project,
    );
    fields
}

fn local_fields_changed_since_sync(
    item: &TaskBoardItem,
    state: &ExternalRefSyncState,
) -> Vec<ExternalSyncField> {
    let mut fields = Vec::new();
    push_if(
        &mut fields,
        state.title.as_ref() != Some(&item.title),
        ExternalSyncField::Title,
    );
    push_if(
        &mut fields,
        state.body.as_ref() != Some(&item.body),
        ExternalSyncField::Body,
    );
    push_if(
        &mut fields,
        state.status != Some(item.status),
        ExternalSyncField::Status,
    );
    push_if(
        &mut fields,
        state.project_id != item.project_id,
        ExternalSyncField::Project,
    );
    fields
}

fn remote_fields_changed_since_sync(
    task: &ExternalTask,
    state: &ExternalRefSyncState,
) -> Vec<ExternalSyncField> {
    let mut fields = Vec::new();
    push_if(
        &mut fields,
        state.title.as_ref() != Some(&task.title),
        ExternalSyncField::Title,
    );
    push_if(
        &mut fields,
        state.body.as_ref() != Some(&task.body),
        ExternalSyncField::Body,
    );
    push_if(
        &mut fields,
        state.status != Some(task.status),
        ExternalSyncField::Status,
    );
    push_if(
        &mut fields,
        state.project_id != task.project_id,
        ExternalSyncField::Project,
    );
    fields
}

fn intersect_fields(
    left: Vec<ExternalSyncField>,
    right: &[ExternalSyncField],
) -> Vec<ExternalSyncField> {
    left.into_iter()
        .filter(|field| right.contains(field))
        .collect()
}

fn push_if(fields: &mut Vec<ExternalSyncField>, condition: bool, field: ExternalSyncField) {
    if condition {
        fields.push(field);
    }
}

pub(super) fn matching_ref<'a>(
    item: &'a TaskBoardItem,
    reference: &ExternalTaskRef,
    project_id: Option<&str>,
) -> Option<&'a ExternalRef> {
    item.external_refs
        .iter()
        .find(|candidate| external_ref_matches(item, candidate, reference, project_id))
}

pub(super) fn external_ref_matches(
    item: &TaskBoardItem,
    candidate: &ExternalRef,
    reference: &ExternalTaskRef,
    project_id: Option<&str>,
) -> bool {
    let provider = reference.provider.into();
    if candidate.provider != provider {
        return false;
    }
    if candidate.external_id == reference.external_id {
        return true;
    }
    provider == crate::task_board::types::ExternalRefProvider::GitHub
        && project_id.is_some_and(|project_id| project_matches(item, candidate, project_id))
        && github_legacy_external_id(reference.external_id.as_str())
            .is_some_and(|legacy_id| candidate.external_id == legacy_id)
}

fn project_matches(item: &TaskBoardItem, candidate: &ExternalRef, project_id: &str) -> bool {
    candidate
        .sync_state
        .as_ref()
        .and_then(|state| state.project_id.as_deref())
        .or(item.project_id.as_deref())
        .is_some_and(|candidate_project| candidate_project.eq_ignore_ascii_case(project_id))
}

fn github_legacy_external_id(external_id: &str) -> Option<&str> {
    let (_, legacy_id) = external_id.rsplit_once('#')?;
    (!legacy_id.trim().is_empty()).then_some(legacy_id)
}
