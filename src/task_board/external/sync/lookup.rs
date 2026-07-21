use std::collections::HashMap;

use crate::task_board::types::{ExternalRefProvider, TaskBoardItem};

use super::{
    ExternalProvider, ExternalSyncAction, ExternalSyncField, ExternalSyncOperation, ExternalTask,
    ExternalTaskRef, matching_ref,
};

pub(super) fn item_for_ref<'a>(
    board_items: &'a [TaskBoardItem],
    item_index: &HashMap<(ExternalRefProvider, String), usize>,
    reference: &ExternalTaskRef,
    project_id: Option<&str>,
) -> Option<&'a TaskBoardItem> {
    let key = (reference.provider.into(), reference.external_id.clone());
    if let Some(index) = item_index.get(&key)
        && let Some(item) = board_items.get(*index)
        && matching_ref(item, reference, project_id).is_some()
    {
        return Some(item);
    }
    board_items
        .iter()
        .find(|item| matching_ref(item, reference, project_id).is_some())
}

pub(super) fn build_external_ref_index(
    items: &[TaskBoardItem],
) -> HashMap<(ExternalRefProvider, String), usize> {
    let mut index = HashMap::with_capacity(items.len() * 2);
    for (offset, item) in items.iter().enumerate() {
        for reference in &item.external_refs {
            let key = (reference.provider, reference.external_id.clone());
            index.entry(key).or_insert(offset);
        }
    }
    index
}

/// Resolves the tracking issue a task names as its parent to an already
/// imported local item. Absence is not an error: the parent may not have
/// been imported yet, and the same lookup on a later sync links it up.
pub(super) fn resolve_parent_item_id(
    board_items: &[TaskBoardItem],
    item_index: &HashMap<(ExternalRefProvider, String), usize>,
    task: &ExternalTask,
) -> Option<String> {
    let reference = task.parent_reference.as_ref()?;
    // The legacy cross-repo fallback needs the *parent's* repository, which
    // for a cross-repo reference differs from the child's own task.project_id.
    let parent_project_id = reference
        .external_id
        .rsplit_once('#')
        .map(|(project_id, _)| project_id)
        .filter(|project_id| !project_id.is_empty())
        .or(task.project_id.as_deref());
    item_for_ref(board_items, item_index, reference, parent_project_id).map(|item| item.id.clone())
}

pub(super) fn provider_ref(
    item: &TaskBoardItem,
    provider: ExternalProvider,
) -> Option<ExternalTaskRef> {
    let core_provider = provider.into();
    item.external_refs
        .iter()
        .filter(|candidate| candidate.provider == core_provider)
        .find_map(|candidate| {
            let probe = ExternalTaskRef::new(provider, candidate.external_id.clone());
            matching_ref(item, &probe, item.project_id.as_deref())
                .map(|matched| ExternalTaskRef::from(matched.clone()))
        })
}

pub(super) struct OperationDraft {
    pub(super) provider: ExternalProvider,
    pub(super) action: ExternalSyncAction,
    pub(super) board_item_id: Option<String>,
    pub(super) reference: ExternalTaskRef,
    pub(super) dry_run: bool,
    pub(super) applied: bool,
    pub(super) changed_fields: Vec<ExternalSyncField>,
    pub(super) unsupported_fields: Vec<ExternalSyncField>,
}

pub(super) fn operation(draft: OperationDraft) -> ExternalSyncOperation {
    ExternalSyncOperation {
        provider: draft.provider,
        action: draft.action,
        board_item_id: draft.board_item_id,
        external_id: (!draft.reference.external_id.is_empty())
            .then_some(draft.reference.external_id),
        url: draft.reference.url,
        dry_run: draft.dry_run,
        applied: draft.applied,
        changed_fields: draft.changed_fields,
        unsupported_fields: draft.unsupported_fields,
    }
}

pub(super) fn provider_is_allowed(
    provider: ExternalProvider,
    filter: Option<ExternalProvider>,
) -> bool {
    filter.is_none_or(|target| target == provider)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::types::{ExternalRef, TaskBoardStatus};

    #[test]
    fn resolve_parent_item_id_matches_a_legacy_cross_repo_parent_by_its_own_repo() {
        let mut parent = TaskBoardItem::new(
            "legacy-parent".into(),
            "Parent issue".into(),
            String::new(),
            "2026-07-15T10:00:00Z".into(),
        );
        parent.execution_repository = Some("other-owner/other-repo".into());
        parent.external_refs = vec![ExternalRef {
            provider: ExternalRefProvider::GitHub,
            external_id: "42".into(),
            url: None,
            sync_state: None,
        }];
        let board_items = vec![parent];
        let item_index = build_external_ref_index(&board_items);
        let task = ExternalTask {
            reference: ExternalTaskRef::new(ExternalProvider::GitHub, "child-owner/child-repo#7"),
            title: "Child issue".into(),
            status: TaskBoardStatus::Backlog,
            project_id: Some("child-owner/child-repo".into()),
            parent_reference: Some(ExternalTaskRef::new(
                ExternalProvider::GitHub,
                "other-owner/other-repo#42",
            )),
            ..ExternalTask::default()
        };

        let resolved = resolve_parent_item_id(&board_items, &item_index, &task);

        assert_eq!(resolved, Some("legacy-parent".to_string()));
    }
}
