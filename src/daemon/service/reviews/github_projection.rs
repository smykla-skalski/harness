use std::collections::HashSet;
use std::sync::{Mutex, OnceLock, PoisonError};

use chrono::SecondsFormat;
use tokio::task::spawn_blocking;

use crate::daemon::service::{broadcast_github_data_change, observe_sender};
use crate::errors::{CliError, CliErrorKind};
use crate::github_api::stable_data_revision_guard;
use crate::github_api::{GitHubDataChange, GitHubProtectedClient, GitHubPullRequestSnapshot};
use crate::reviews::{
    ReviewItem, ReviewPullRequestState, ReviewsPullRequestReference,
    ReviewsPullRequestResolveRequest,
};
use crate::task_board::{
    TaskBoardStore, default_board_root, imported_review_pull_request_references,
    reconcile_pull_request_snapshots,
};

static PROJECTION_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

pub(super) enum MissingReviewResolution {
    ExactActiveImports,
    ProvidedSnapshotsOnly,
}

impl MissingReviewResolution {
    const fn resolves_active_imports(&self) -> bool {
        matches!(self, Self::ExactActiveImports)
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "the projection boundary handles the changed, unchanged, and failed persistence outcomes"
)]
pub(super) async fn reconcile_task_board(
    items: &[ReviewItem],
    authoritative_viewer_keys: &HashSet<String>,
    missing_review_resolution: MissingReviewResolution,
    backport_detection_enabled: bool,
    backport_patterns: &[String],
    expected_revision: u64,
) -> bool {
    let Some(sender) = observe_sender() else {
        return true;
    };
    let mut snapshots = items
        .iter()
        .map(|item| snapshot_from_review(item, authoritative_viewer_keys))
        .collect::<Vec<_>>();
    if missing_review_resolution.resolves_active_imports() {
        match resolve_missing_review_snapshots(
            &snapshots,
            backport_detection_enabled,
            backport_patterns,
        )
        .await
        {
            Ok(resolved) => snapshots.extend(resolved),
            Err(error) => {
                tracing::warn!(%error, "resolve missing task-board review pull requests");
            }
        }
    }
    let result = reconcile_snapshots(snapshots, expected_revision).await;
    let changed = match result {
        Ok(Some(changed)) => changed,
        Ok(None) => return false,
        Err(error) => {
            tracing::warn!(%error, "reconcile reviews into task board");
            return true;
        }
    };
    let revision_stable = GitHubProtectedClient::data_revision() == expected_revision;
    if changed && revision_stable {
        broadcast_github_data_change(
            &sender,
            &GitHubDataChange {
                revision: GitHubProtectedClient::data_revision(),
                operation: "reviews.shared_pull_request_projection".to_string(),
            },
        );
    }
    revision_stable
}

async fn resolve_missing_review_snapshots(
    snapshots: &[GitHubPullRequestSnapshot],
    backport_detection_enabled: bool,
    backport_patterns: &[String],
) -> Result<Vec<GitHubPullRequestSnapshot>, CliError> {
    let imported = load_imported_review_references().await?;
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

async fn load_imported_review_references() -> Result<Vec<(String, u64)>, CliError> {
    spawn_blocking(|| {
        imported_review_pull_request_references(&TaskBoardStore::new(default_board_root()))
    })
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "join task-board review reference discovery: {error}"
        )))
    })?
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
    snapshots: Vec<GitHubPullRequestSnapshot>,
    expected_revision: u64,
) -> Result<Option<bool>, CliError> {
    let Some(_revision_guard) = stable_data_revision_guard(expected_revision).await else {
        return Ok(None);
    };
    spawn_blocking(move || {
        let _guard = PROJECTION_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let board = TaskBoardStore::new(default_board_root());
        reconcile_pull_request_snapshots(&board, &snapshots).map(Some)
    })
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "join reviews task-board reconciliation: {error}"
        )))
    })?
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
