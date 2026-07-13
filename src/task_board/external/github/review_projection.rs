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
        .filter(is_imported_review)
        .flat_map(|item| {
            item.external_refs
                .clone()
                .into_iter()
                .filter(is_active_github_review_reference)
                .filter_map(move |reference| normalized_reference(&item, &reference))
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect())
}

pub(crate) fn imported_review_references_from_items(items: &[TaskBoardItem]) -> Vec<(String, u64)> {
    items
        .iter()
        .filter(|item| is_imported_review(item))
        .flat_map(|item| {
            item.external_refs
                .iter()
                .filter(|reference| is_active_github_review_reference(reference))
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
    let observed_status = observed_review_status(snapshot)?;
    let last_synced_status = item.external_refs[reference_index]
        .sync_state
        .as_ref()
        .and_then(|state| state.status);
    let status = reconciled_review_status(item.status, last_synced_status, observed_status);
    let mut external_refs = item.external_refs.clone();
    let sync_state_changed = update_sync_state(
        &mut external_refs[reference_index],
        snapshot,
        observed_status,
    );
    if item.status == status && !sync_state_changed {
        return None;
    }
    Some(TaskBoardItemPatch {
        status: (item.status != status).then_some(status),
        external_refs: sync_state_changed.then_some(external_refs),
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
        && item.external_refs.iter().any(is_github_pull_request)
}

fn observed_review_status(snapshot: &GitHubPullRequestSnapshot) -> Option<TaskBoardStatus> {
    if snapshot.is_open == Some(false) || snapshot.viewer_review_requested == Some(false) {
        return Some(TaskBoardStatus::Done);
    }
    if snapshot.viewer_review_requested == Some(true) {
        return Some(TaskBoardStatus::Todo);
    }
    None
}

pub(crate) fn reconciled_review_status(
    current: TaskBoardStatus,
    last_synced: Option<TaskBoardStatus>,
    observed: TaskBoardStatus,
) -> TaskBoardStatus {
    last_synced.map_or(current, |last_synced| {
        if current == last_synced {
            observed
        } else {
            current
        }
    })
}

fn is_active_github_review_reference(reference: &ExternalRef) -> bool {
    is_github_pull_request(reference)
        && reference
            .sync_state
            .as_ref()
            .and_then(|state| state.status)
            != Some(TaskBoardStatus::Done)
}

fn update_sync_state(
    reference: &mut ExternalRef,
    snapshot: &GitHubPullRequestSnapshot,
    status: TaskBoardStatus,
) -> bool {
    if reference.sync_state.as_ref().is_some_and(|state| {
        state.status == Some(status)
            && state.updated_at.as_deref() == Some(snapshot.updated_at.as_str())
    }) {
        return false;
    }
    let state = reference.sync_state.get_or_insert_default();
    state.status = Some(status);
    state.updated_at = Some(snapshot.updated_at.clone());
    state.synced_at = Some(utc_now());
    true
}

#[cfg(test)]
mod tests;
