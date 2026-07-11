use std::collections::HashSet;

use chrono::SecondsFormat;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::github_api::stable_data_revision_guard;
use crate::github_api::{GitHubProtectedClient, GitHubPullRequestSnapshot};
use crate::reviews::{
    ReviewItem, ReviewPullRequestState, ReviewsPullRequestReference,
    ReviewsPullRequestResolveRequest,
};
use crate::task_board::{
    imported_review_references_from_items, reconcile_review_item_from_snapshots,
};

pub(super) enum MissingReviewResolution {
    ExactActiveImports,
    ProvidedSnapshotsOnly,
}

impl MissingReviewResolution {
    const fn resolves_active_imports(&self) -> bool {
        matches!(self, Self::ExactActiveImports)
    }
}

pub(super) async fn reconcile_task_board(
    database: Option<&AsyncDaemonDb>,
    items: &[ReviewItem],
    authoritative_viewer_keys: &HashSet<String>,
    missing_review_resolution: MissingReviewResolution,
    backport_detection_enabled: bool,
    backport_patterns: &[String],
    expected_revision: u64,
) -> Result<bool, CliError> {
    let Some(database) = database else {
        return Ok(true);
    };
    let mut snapshots = items
        .iter()
        .map(|item| snapshot_from_review(item, authoritative_viewer_keys))
        .collect::<Vec<_>>();
    if missing_review_resolution.resolves_active_imports() {
        let resolved = resolve_missing_review_snapshots(
            database,
            &snapshots,
            backport_detection_enabled,
            backport_patterns,
        )
        .await?;
        snapshots.extend(resolved);
    }
    let Some(_revision_guard) = stable_data_revision_guard(expected_revision).await else {
        return Ok(false);
    };
    super::super::task_board_db::reconcile_shared_review_items_db(database, items).await?;
    reconcile_snapshots(database, snapshots).await?;
    Ok(GitHubProtectedClient::data_revision() == expected_revision)
}

async fn resolve_missing_review_snapshots(
    database: &AsyncDaemonDb,
    snapshots: &[GitHubPullRequestSnapshot],
    backport_detection_enabled: bool,
    backport_patterns: &[String],
) -> Result<Vec<GitHubPullRequestSnapshot>, CliError> {
    let imported = load_imported_review_references(database).await?;
    let references = references_missing_from_snapshots(imported, snapshots);
    if references.is_empty() {
        return Ok(Vec::new());
    }
    let request = ReviewsPullRequestResolveRequest {
        references,
        backport_detection_enabled,
        backport_patterns: backport_patterns.to_vec(),
    };
    let resolved = super::resolve::fetch_pull_requests_by_reference(&request).await?;
    Ok(resolved
        .items
        .iter()
        .map(|item| snapshot_from_review(item, &resolved.authoritative_viewer_keys))
        .collect())
}

async fn load_imported_review_references(
    database: &AsyncDaemonDb,
) -> Result<Vec<(String, u64)>, CliError> {
    database
        .list_task_board_items(None)
        .await
        .map(|items| imported_review_references_from_items(&items))
}

fn references_missing_from_snapshots(
    imported: Vec<(String, u64)>,
    snapshots: &[GitHubPullRequestSnapshot],
) -> Vec<ReviewsPullRequestReference> {
    let covered = snapshots
        .iter()
        .map(|snapshot| snapshot_key(&snapshot.repository, snapshot.number))
        .collect::<HashSet<_>>();
    imported
        .into_iter()
        .filter(|(repository, number)| !covered.contains(&snapshot_key(repository, *number)))
        .map(|(repository, number)| ReviewsPullRequestReference { repository, number })
        .collect()
}

fn snapshot_key(repository: &str, number: u64) -> String {
    format!("{}#{number}", repository.trim().to_ascii_lowercase())
}

async fn reconcile_snapshots(
    database: &AsyncDaemonDb,
    snapshots: Vec<GitHubPullRequestSnapshot>,
) -> Result<bool, CliError> {
    let items = database.list_task_board_items(None).await?;
    let mut changed = false;
    for item in items {
        let mutation = database
            .update_task_board_item(&item.id, |current| {
                Ok(reconcile_review_item_from_snapshots(current, &snapshots))
            })
            .await?;
        changed |= mutation.is_some();
    }
    Ok(changed)
}

fn snapshot_from_review(
    item: &ReviewItem,
    authoritative_viewer_keys: &HashSet<String>,
) -> GitHubPullRequestSnapshot {
    let key = format!("{}#{}", item.repository.to_ascii_lowercase(), item.number);
    GitHubPullRequestSnapshot {
        repository: item.repository.clone(),
        number: item.number,
        is_open: match item.state {
            ReviewPullRequestState::Open => Some(true),
            ReviewPullRequestState::Closed | ReviewPullRequestState::Merged => Some(false),
            ReviewPullRequestState::Unknown => None,
        },
        viewer_review_requested: authoritative_viewer_keys
            .contains(&key)
            .then_some(item.flags.viewer_is_requested_reviewer),
        updated_at: item.updated_at.to_rfc3339_opts(SecondsFormat::Secs, true),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_imported_references_absent_from_the_aggregate_are_resolved() {
        let snapshots = vec![GitHubPullRequestSnapshot {
            repository: "example/repo".into(),
            number: 42,
            is_open: Some(true),
            viewer_review_requested: Some(true),
            updated_at: "2026-07-11T11:00:00Z".into(),
        }];

        let missing = references_missing_from_snapshots(
            vec![("Example/Repo".into(), 42), ("example/other".into(), 7)],
            &snapshots,
        );

        assert_eq!(
            missing,
            vec![ReviewsPullRequestReference {
                repository: "example/other".into(),
                number: 7,
            }]
        );
    }

    #[test]
    fn targeted_refresh_uses_only_its_provided_snapshots() {
        assert!(MissingReviewResolution::ExactActiveImports.resolves_active_imports());
        assert!(!MissingReviewResolution::ProvidedSnapshotsOnly.resolves_active_imports());
    }
}
