use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::types::{
    ExternalRef, ExternalRefProvider, ExternalRefSyncState, TaskBoardItem, TaskBoardStatus,
};
use crate::workspace::utc_now;

use crate::task_board::external::targeting::provider_project_maps_to_board;
use crate::task_board::external::{
    ExternalProvider, ExternalProviderCapabilities, ExternalRevisionUpdate, ExternalSyncAction,
    ExternalSyncField, ExternalSyncOperation, ExternalTask, ExternalTaskRef,
    canonical_external_status, local_external_status,
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
            let local = local_fields_changed_since_sync(item, state, task.reference.provider);
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
            |state| local_fields_changed_since_sync(item, state, reference.provider),
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
    changed_fields: &[ExternalSyncField],
    provider_revision: &ExternalRevisionUpdate,
) -> Vec<ExternalRef> {
    let provider = current.provider.into();
    item.external_refs
        .iter()
        .map(|candidate| {
            if candidate.provider == provider && candidate.external_id == current.external_id {
                synced_ref_from_update(
                    candidate,
                    updated.clone(),
                    item,
                    changed_fields,
                    provider_revision,
                )
            } else {
                candidate.clone()
            }
        })
        .collect()
}

pub(super) fn sync_state_from_task(task: &ExternalTask) -> ExternalRefSyncState {
    ExternalRefSyncState {
        title: Some(task.title.clone()),
        body: Some(task.body.clone()),
        status: Some(canonical_external_status(task.status)),
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
    if provider_project_maps_to_board(task.reference.provider) && task.project_id.is_some() {
        fields.push(ExternalSyncField::Project);
    }
    if task.reference.url.is_some() {
        fields.push(ExternalSyncField::Url);
    }
    fields
}

pub(super) fn pull_resolution_fields(task: &ExternalTask) -> Vec<ExternalSyncField> {
    let mut fields = vec![
        ExternalSyncField::Title,
        ExternalSyncField::Body,
        ExternalSyncField::Status,
        ExternalSyncField::Url,
    ];
    if provider_project_maps_to_board(task.reference.provider) {
        fields.push(ExternalSyncField::Project);
    }
    fields
}

pub(super) fn push_create_fields(
    item: &TaskBoardItem,
    provider: ExternalProvider,
) -> Vec<ExternalSyncField> {
    let mut fields = vec![ExternalSyncField::Title, ExternalSyncField::Body];
    if canonical_external_status(item.status) != TaskBoardStatus::Done {
        fields.push(ExternalSyncField::Status);
    }
    if provider_project_maps_to_board(provider) && item.project_id.is_some() {
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

fn synced_ref_from_update(
    current: &ExternalRef,
    updated: ExternalTaskRef,
    item: &TaskBoardItem,
    changed_fields: &[ExternalSyncField],
    provider_revision: &ExternalRevisionUpdate,
) -> ExternalRef {
    let mut reference = updated.into_core_ref();
    let mut state = current.sync_state.clone().unwrap_or_default();
    state.status = state.status.map(canonical_external_status);
    if changed_fields.contains(&ExternalSyncField::Title) {
        state.title = Some(item.title.clone());
    }
    if changed_fields.contains(&ExternalSyncField::Body) {
        state.body = Some(item.body.clone());
    }
    if changed_fields.contains(&ExternalSyncField::Status) {
        state.status = Some(canonical_external_status(item.status));
    }
    if changed_fields.contains(&ExternalSyncField::Project) {
        state.project_id.clone_from(&item.project_id);
    }
    state.updated_at = provider_revision.resolve(state.updated_at.as_deref());
    state.synced_at = Some(utc_now());
    reference.sync_state = Some(state);
    reference
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
        local_status_differs_from_remote(item.status, task.status),
        ExternalSyncField::Status,
    );
    push_if(
        &mut fields,
        provider_project_maps_to_board(task.reference.provider)
            && item.project_id != task.project_id,
        ExternalSyncField::Project,
    );
    fields
}

fn local_fields_changed_since_sync(
    item: &TaskBoardItem,
    state: &ExternalRefSyncState,
    provider: ExternalProvider,
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
        local_status_changed(item.status, state.status),
        ExternalSyncField::Status,
    );
    push_if(
        &mut fields,
        provider_project_maps_to_board(provider) && state.project_id != item.project_id,
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
        remote_status_changed(task.status, state.status),
        ExternalSyncField::Status,
    );
    push_if(
        &mut fields,
        provider_project_maps_to_board(task.reference.provider)
            && state.project_id != task.project_id,
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

fn local_status_differs_from_remote(local: TaskBoardStatus, remote: TaskBoardStatus) -> bool {
    local_external_status(local).is_some_and(|local| local != canonical_external_status(remote))
}

fn local_status_changed(local: TaskBoardStatus, last_synced: Option<TaskBoardStatus>) -> bool {
    local_external_status(local).is_some_and(|local| {
        last_synced
            .map(canonical_external_status)
            .is_none_or(|last_synced| local != last_synced)
    })
}

fn remote_status_changed(remote: TaskBoardStatus, last_synced: Option<TaskBoardStatus>) -> bool {
    last_synced
        .map(canonical_external_status)
        .is_none_or(|last_synced| canonical_external_status(remote) != last_synced)
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
    provider == ExternalRefProvider::GitHub
        && project_id.is_some_and(|project_id| project_matches(item, candidate, project_id))
        && github_legacy_external_id(reference.external_id.as_str())
            .is_some_and(|legacy_id| candidate.external_id == legacy_id)
}

fn project_matches(item: &TaskBoardItem, candidate: &ExternalRef, project_id: &str) -> bool {
    item.execution_repository
        .as_deref()
        .or_else(|| {
            candidate
                .sync_state
                .as_ref()
                .and_then(|state| state.project_id.as_deref())
        })
        .or(item.project_id.as_deref())
        .is_some_and(|candidate_project| candidate_project.eq_ignore_ascii_case(project_id))
}

fn github_legacy_external_id(external_id: &str) -> Option<&str> {
    let (_, legacy_id) = external_id.rsplit_once('#')?;
    (!legacy_id.trim().is_empty()).then_some(legacy_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn revision_update_distinguishes_preserve_set_and_clear() {
        let mut item = TaskBoardItem::new(
            "task-1".into(),
            "Title".into(),
            "Body".into(),
            "2026-07-16T10:00:00Z".into(),
        );
        item.status = TaskBoardStatus::Done;
        let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
        let mut core_reference = reference.clone().into_core_ref();
        core_reference.sync_state = Some(ExternalRefSyncState {
            title: Some("Title".into()),
            body: Some("Body".into()),
            status: Some(TaskBoardStatus::Backlog),
            project_id: None,
            updated_at: Some("provider-revision-1".into()),
            synced_at: Some("2026-07-16T10:00:00Z".into()),
        });
        item.external_refs = vec![core_reference];

        let preserved = replace_synced_ref(
            &item,
            &reference,
            &reference,
            &[],
            &ExternalRevisionUpdate::Preserve,
        );
        assert_eq!(
            preserved[0]
                .sync_state
                .as_ref()
                .and_then(|state| state.updated_at.as_deref()),
            Some("provider-revision-1")
        );

        let set = replace_synced_ref(
            &item,
            &reference,
            &reference,
            &[ExternalSyncField::Status],
            &ExternalRevisionUpdate::Set("provider-revision-2".into()),
        );
        assert_eq!(
            set[0]
                .sync_state
                .as_ref()
                .and_then(|state| state.updated_at.as_deref()),
            Some("provider-revision-2")
        );

        let cleared = replace_synced_ref(
            &item,
            &reference,
            &reference,
            &[ExternalSyncField::Status],
            &ExternalRevisionUpdate::Clear,
        );
        assert_eq!(
            cleared[0]
                .sync_state
                .as_ref()
                .and_then(|state| state.updated_at.as_deref()),
            None
        );
    }
}
