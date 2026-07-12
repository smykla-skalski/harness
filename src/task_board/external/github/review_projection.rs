use std::collections::{BTreeMap, BTreeSet};

#[cfg(test)]
use crate::errors::CliError;
use crate::github_api::GitHubPullRequestSnapshot;
use crate::task_board::store::TaskBoardItemPatch;
#[cfg(test)]
use crate::task_board::store::TaskBoardStore;
use crate::task_board::types::{ExternalRef, ExternalRefProvider, TaskBoardItem, TaskBoardStatus};
use crate::workspace::utc_now;

#[cfg(test)]
pub(crate) fn reconcile_pull_request_snapshots(
    board: &TaskBoardStore,
    snapshots: &[GitHubPullRequestSnapshot],
) -> Result<bool, CliError> {
    let snapshots = snapshots
        .iter()
        .map(|snapshot| {
            (
                snapshot_key(&snapshot.repository, snapshot.number),
                snapshot,
            )
        })
        .collect::<BTreeMap<_, _>>();
    let candidates = board
        .list(None)?
        .into_iter()
        .filter(is_imported_review)
        .map(|item| item.id)
        .collect::<Vec<_>>();
    let mut changed = false;
    for item_id in candidates {
        changed |= reconcile_candidate(board, &item_id, &snapshots)?;
    }
    Ok(changed)
}

#[cfg(test)]
pub(crate) fn imported_review_pull_request_references(
    board: &TaskBoardStore,
) -> Result<Vec<(String, u64)>, CliError> {
    Ok(board
        .list(None)?
        .into_iter()
        .filter(|item| is_imported_review(item) && is_review_inbox_status(item.status))
        .flat_map(|item| {
            item.external_refs
                .clone()
                .into_iter()
                .filter(is_github_pull_request)
                .filter_map(move |reference| normalized_reference(&item, &reference))
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect())
}

pub(crate) fn imported_review_references_from_items(items: &[TaskBoardItem]) -> Vec<(String, u64)> {
    items
        .iter()
        .filter(|item| is_imported_review(item) && is_review_inbox_status(item.status))
        .flat_map(|item| {
            item.external_refs
                .iter()
                .filter(|reference| is_github_pull_request(reference))
                .filter_map(|reference| normalized_reference(item, reference))
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

pub(crate) fn reconcile_review_item_from_snapshots(
    item: &mut TaskBoardItem,
    snapshots: &[GitHubPullRequestSnapshot],
) -> bool {
    let snapshots = snapshots
        .iter()
        .map(|snapshot| {
            (
                snapshot_key(&snapshot.repository, snapshot.number),
                snapshot,
            )
        })
        .collect::<BTreeMap<_, _>>();
    let Some(patch) = projection_patch(item, &snapshots) else {
        return false;
    };
    if let Some(status) = patch.status {
        item.status = status;
    }
    if let Some(external_refs) = patch.external_refs {
        item.external_refs = external_refs;
    }
    true
}

#[cfg(test)]
fn reconcile_candidate(
    board: &TaskBoardStore,
    item_id: &str,
    snapshots: &BTreeMap<String, &GitHubPullRequestSnapshot>,
) -> Result<bool, CliError> {
    board
        .update_if(item_id, |item| projection_patch(item, snapshots))
        .map(|updated| updated.is_some())
}

fn projection_patch(
    item: &TaskBoardItem,
    snapshots: &BTreeMap<String, &GitHubPullRequestSnapshot>,
) -> Option<TaskBoardItemPatch> {
    let (reference_index, snapshot) = matching_imported_review(item, snapshots)?;
    let status = projected_status(snapshot, item.status);
    if item.status == status {
        return None;
    }
    let mut external_refs = item.external_refs.clone();
    update_sync_state(&mut external_refs[reference_index], snapshot, status);
    Some(TaskBoardItemPatch {
        status: Some(status),
        external_refs: Some(external_refs),
        ..TaskBoardItemPatch::default()
    })
}

fn matching_imported_review<'a>(
    item: &TaskBoardItem,
    snapshots: &'a BTreeMap<String, &GitHubPullRequestSnapshot>,
) -> Option<(usize, &'a GitHubPullRequestSnapshot)> {
    if !is_imported_review(item) {
        return None;
    }
    item.external_refs
        .iter()
        .enumerate()
        .filter(|(_, reference)| is_github_pull_request(reference))
        .find_map(|(index, reference)| {
            let key = normalized_reference_key(item, reference)?;
            snapshots.get(&key).map(|snapshot| (index, *snapshot))
        })
}

fn normalized_reference_key(item: &TaskBoardItem, reference: &ExternalRef) -> Option<String> {
    normalized_reference(item, reference)
        .map(|(repository, number)| snapshot_key(&repository, number))
}

fn normalized_reference(item: &TaskBoardItem, reference: &ExternalRef) -> Option<(String, u64)> {
    if let Some((repository, number)) = reference.external_id.rsplit_once('#') {
        return number
            .parse::<u64>()
            .ok()
            .map(|number| (repository.trim().to_ascii_lowercase(), number));
    }
    let number = reference.external_id.parse::<u64>().ok()?;
    item.project_id
        .as_deref()
        .map(|repository| (repository.trim().to_ascii_lowercase(), number))
}

fn snapshot_key(repository: &str, number: u64) -> String {
    format!("{}#{number}", repository.trim().to_ascii_lowercase())
}

fn is_github_pull_request(reference: &ExternalRef) -> bool {
    reference.provider == ExternalRefProvider::GitHub
        && reference
            .url
            .as_deref()
            .is_some_and(|url| url.contains("/pull/"))
}

fn is_imported_review(item: &TaskBoardItem) -> bool {
    item.imported_from_provider == Some(ExternalRefProvider::GitHub)
        && item.planning.summary.is_none()
}

fn projected_status(
    snapshot: &GitHubPullRequestSnapshot,
    current: TaskBoardStatus,
) -> TaskBoardStatus {
    if snapshot.is_open == Some(false) || snapshot.viewer_review_requested == Some(false) {
        return if is_review_inbox_status(current) {
            TaskBoardStatus::Done
        } else {
            current
        };
    }
    if snapshot.viewer_review_requested == Some(true) && current == TaskBoardStatus::Done {
        return TaskBoardStatus::HumanRequired;
    }
    current
}

fn is_review_inbox_status(status: TaskBoardStatus) -> bool {
    matches!(
        status,
        TaskBoardStatus::HumanRequired
            | TaskBoardStatus::AgenticReview
            | TaskBoardStatus::NeedsYou
            | TaskBoardStatus::PlanReview
    )
}

fn update_sync_state(
    reference: &mut ExternalRef,
    snapshot: &GitHubPullRequestSnapshot,
    status: TaskBoardStatus,
) {
    let state = reference.sync_state.get_or_insert_default();
    state.status = Some(status);
    state.updated_at = Some(snapshot.updated_at.clone());
    state.synced_at = Some(utc_now());
}

#[cfg(test)]
mod tests;
