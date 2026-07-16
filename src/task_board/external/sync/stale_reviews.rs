use crate::errors::CliError;
use crate::task_board::external::{
    ExternalProvider, ExternalSyncField, ExternalTask, ExternalTaskRef,
};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::{ExternalRefProvider, TaskBoardItem, TaskBoardStatus};
use crate::workspace::utc_now;

use super::super::github::reconciled_external_status;
use super::merge::{external_ref_matches, matching_ref};
use super::{ExternalSyncAction, ExternalSyncOperation, ExternalSyncOptions, TaskBoardSyncStore};

pub(super) async fn reconcile_stale_github_review_requests(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    board_items: &[TaskBoardItem],
    tasks: &[ExternalTask],
    authoritative_review_inbox: bool,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    if provider != ExternalProvider::GitHub
        || !authoritative_review_inbox
        || !allows_stale_review_reconcile(options)
    {
        return Ok(());
    }

    let stale_items = board_items
        .iter()
        .filter_map(|item| {
            let reference = provider_ref(item, provider)?;
            is_stale_github_review_request(item, &reference, tasks)
                .then_some((item.clone(), reference))
        })
        .collect::<Vec<_>>();

    for (item, reference) in stale_items {
        operations.push(stale_review_request_operation(
            provider, &item, &reference, options,
        ));
        if options.dry_run {
            continue;
        }
        let patch = stale_review_request_patch(&item, &reference);
        board.update_item(&item, patch).await?;
    }

    Ok(())
}

fn allows_stale_review_reconcile(options: ExternalSyncOptions) -> bool {
    options.status.is_none_or(|status| {
        matches!(
            status.canonical_persisted_status(),
            TaskBoardStatus::Backlog | TaskBoardStatus::Todo
        )
    })
}

fn stale_review_request_operation(
    provider: ExternalProvider,
    item: &TaskBoardItem,
    reference: &ExternalTaskRef,
    options: ExternalSyncOptions,
) -> ExternalSyncOperation {
    ExternalSyncOperation {
        provider,
        action: ExternalSyncAction::Pull,
        board_item_id: Some(item.id.clone()),
        external_id: (!reference.external_id.is_empty()).then_some(reference.external_id.clone()),
        url: reference.url.clone(),
        dry_run: options.dry_run,
        applied: !options.dry_run,
        changed_fields: vec![ExternalSyncField::Status],
        unsupported_fields: Vec::new(),
    }
}

fn stale_review_request_patch(
    item: &TaskBoardItem,
    reference: &ExternalTaskRef,
) -> TaskBoardItemPatch {
    let last_synced_status = matching_ref(item, reference, item.project_id.as_deref())
        .and_then(|reference| reference.sync_state.as_ref())
        .and_then(|state| state.status);
    let status = reconciled_external_status(item.status, last_synced_status, TaskBoardStatus::Done);
    let mut patch = TaskBoardItemPatch {
        status: (item.status != status).then_some(status),
        ..TaskBoardItemPatch::default()
    };
    patch.external_refs = Some(
        item.external_refs
            .iter()
            .map(|candidate| {
                if external_ref_matches(item, candidate, reference, item.project_id.as_deref()) {
                    let mut next = candidate.clone();
                    let mut state = next.sync_state.unwrap_or_default();
                    state.status = Some(TaskBoardStatus::Done);
                    state.synced_at = Some(utc_now());
                    next.sync_state = Some(state);
                    return next;
                }
                candidate.clone()
            })
            .collect(),
    );
    patch
}

fn provider_ref(item: &TaskBoardItem, provider: ExternalProvider) -> Option<ExternalTaskRef> {
    let provider = provider.into();
    item.external_refs
        .iter()
        .find(|reference| reference.provider == provider)
        .cloned()
        .map(ExternalTaskRef::from)
}

fn is_stale_github_review_request(
    item: &TaskBoardItem,
    reference: &ExternalTaskRef,
    tasks: &[ExternalTask],
) -> bool {
    item.imported_from_provider == Some(ExternalRefProvider::GitHub)
        && reference
            .url
            .as_deref()
            .is_some_and(|url| url.contains("/pull/"))
        && matching_ref(item, reference, item.project_id.as_deref())
            .and_then(|reference| reference.sync_state.as_ref())
            .and_then(|state| state.status)
            != Some(TaskBoardStatus::Done)
        && !tasks
            .iter()
            .any(|task| matching_ref(item, &task.reference, task.project_id.as_deref()).is_some())
}
