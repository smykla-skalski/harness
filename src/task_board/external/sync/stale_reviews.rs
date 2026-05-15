use crate::errors::CliError;
use crate::task_board::external::{
    ExternalProvider, ExternalSyncField, ExternalTask, ExternalTaskRef,
};
use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};
use crate::workspace::utc_now;

use super::merge::{external_ref_matches, matching_ref};
use super::{ExternalSyncAction, ExternalSyncOperation, ExternalSyncOptions};

pub(super) fn reconcile_stale_github_review_requests(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    tasks: &[ExternalTask],
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    if provider != ExternalProvider::GitHub || !allows_stale_review_reconcile(options) {
        return Ok(());
    }

    let stale_items = board
        .list(None)?
        .into_iter()
        .filter_map(|item| {
            let reference = provider_ref(&item, provider)?;
            is_stale_github_review_request(&item, &reference, tasks).then_some((item, reference))
        })
        .collect::<Vec<_>>();

    for (item, reference) in stale_items {
        operations.push(stale_review_request_operation(
            provider, &item, &reference, options,
        ));
        if options.dry_run {
            continue;
        }
        board.update(&item.id, stale_review_request_patch(&item, &reference))?;
    }

    Ok(())
}

fn allows_stale_review_reconcile(options: ExternalSyncOptions) -> bool {
    options.status.is_none_or(|status| {
        matches!(
            status,
            TaskBoardStatus::NeedsYou | TaskBoardStatus::PlanReview
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
    let mut patch = TaskBoardItemPatch {
        status: Some(TaskBoardStatus::Done),
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
    item.id.starts_with("github-")
        && item.planning.summary.is_none()
        && matches!(
            item.status,
            TaskBoardStatus::NeedsYou | TaskBoardStatus::PlanReview
        )
        && reference
            .url
            .as_deref()
            .is_some_and(|url| url.contains("/pull/"))
        && !tasks
            .iter()
            .any(|task| matching_ref(item, &task.reference, task.project_id.as_deref()).is_some())
}
