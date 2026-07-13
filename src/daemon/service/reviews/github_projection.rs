use std::collections::HashSet;

use chrono::SecondsFormat;

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::github_api::stable_data_revision_guard;
use crate::github_api::{GitHubProtectedClient, GitHubPullRequestSnapshot};
use crate::reviews::{
    ReviewItem, ReviewPullRequestState, ReviewsPullRequestReference,
    ReviewsPullRequestResolveRequest, ReviewsQueryRequest,
};
use crate::task_board::{
    imported_review_references_from_items, reconcile_review_item_from_snapshots,
};

use super::super::task_board_db::{
    ReviewsProjectionAuditSummary, record_reviews_projection_result,
};

pub(super) enum MissingReviewResolution {
    ExactActiveImports(ReviewsQueryRequest),
    ProvidedSnapshotsOnly,
}

impl MissingReviewResolution {
    const fn query_scope(&self) -> Option<&ReviewsQueryRequest> {
        match self {
            Self::ExactActiveImports(scope) => Some(scope),
            Self::ProvidedSnapshotsOnly => None,
        }
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
    let result = reconcile_task_board_inner(
        database,
        items,
        authoritative_viewer_keys,
        missing_review_resolution,
        backport_detection_enabled,
        backport_patterns,
        expected_revision,
    )
    .await;
    if let Some(database) = database {
        record_reviews_projection_result(database, &result).await;
    }
    result.map(|summary| summary.is_stable())
}

async fn reconcile_task_board_inner(
    database: Option<&AsyncDaemonDb>,
    items: &[ReviewItem],
    authoritative_viewer_keys: &HashSet<String>,
    missing_review_resolution: MissingReviewResolution,
    backport_detection_enabled: bool,
    backport_patterns: &[String],
    expected_revision: u64,
) -> Result<ReviewsProjectionAuditSummary, CliError> {
    let Some(database) = database else {
        return Ok(ReviewsProjectionAuditSummary::new(true, &[], 0));
    };
    let mut observed_items = items.to_vec();
    let mut observed_authoritative_viewer_keys = authoritative_viewer_keys.clone();
    let initial_snapshots = items
        .iter()
        .map(|item| snapshot_from_review(item, authoritative_viewer_keys))
        .collect::<Vec<_>>();
    if let Some(query_scope) = missing_review_resolution.query_scope() {
        let resolved = resolve_missing_review_items(
            database,
            &initial_snapshots,
            query_scope,
            backport_detection_enabled,
            backport_patterns,
        )
        .await?;
        let (resolved_items, resolved_authoritative_viewer_keys) = resolved;
        observed_authoritative_viewer_keys.extend(resolved_authoritative_viewer_keys);
        observed_items.extend(resolved_items);
    }
    let Some(_revision_guard) = stable_data_revision_guard(expected_revision).await else {
        return Ok(ReviewsProjectionAuditSummary::new(false, &[], 0));
    };
    let (configured_keys, operations) =
        super::super::task_board_db::reconcile_shared_review_items_db(database, &observed_items)
            .await?;
    let mut snapshots = observed_items
        .iter()
        .map(|item| snapshot_from_review(item, &observed_authoritative_viewer_keys))
        .collect::<Vec<_>>();
    mark_ineligible_snapshots(&mut snapshots, &configured_keys);
    let snapshot_update_count = reconcile_snapshots(database, snapshots).await?;
    Ok(ReviewsProjectionAuditSummary::new(
        GitHubProtectedClient::data_revision() == expected_revision,
        &operations,
        snapshot_update_count,
    ))
}

async fn resolve_missing_review_items(
    database: &AsyncDaemonDb,
    snapshots: &[GitHubPullRequestSnapshot],
    query_scope: &ReviewsQueryRequest,
    backport_detection_enabled: bool,
    backport_patterns: &[String],
) -> Result<(Vec<ReviewItem>, HashSet<String>), CliError> {
    let imported = load_imported_review_references(database).await?;
    let references = references_missing_from_snapshots(imported, snapshots, query_scope);
    if references.is_empty() {
        return Ok((Vec::new(), HashSet::new()));
    }
    let request = ReviewsPullRequestResolveRequest {
        references,
        backport_detection_enabled,
        backport_patterns: backport_patterns.to_vec(),
    };
    let resolved = super::resolve::fetch_pull_requests_by_reference(&request).await?;
    Ok((resolved.items, resolved.authoritative_viewer_keys))
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
    query_scope: &ReviewsQueryRequest,
) -> Vec<ReviewsPullRequestReference> {
    let covered = snapshots
        .iter()
        .map(|snapshot| snapshot_key(&snapshot.repository, snapshot.number))
        .collect::<HashSet<_>>();
    imported
        .into_iter()
        .filter(|(repository, _)| repository_is_in_query_scope(repository, query_scope))
        .filter(|(repository, number)| !covered.contains(&snapshot_key(repository, *number)))
        .map(|(repository, number)| ReviewsPullRequestReference { repository, number })
        .collect()
}

fn repository_is_in_query_scope(repository: &str, query_scope: &ReviewsQueryRequest) -> bool {
    let repository = repository.trim();
    if query_scope
        .normalized_exclude_repositories()
        .iter()
        .any(|excluded| excluded.eq_ignore_ascii_case(repository))
    {
        return false;
    }
    if query_scope
        .normalized_repositories()
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(repository))
    {
        return true;
    }
    let Some((owner, _)) = repository.split_once('/') else {
        return false;
    };
    query_scope
        .normalized_organizations()
        .iter()
        .any(|organization| organization.eq_ignore_ascii_case(owner))
}

fn mark_ineligible_snapshots(
    snapshots: &mut [GitHubPullRequestSnapshot],
    configured_keys: &HashSet<String>,
) {
    for snapshot in snapshots {
        if !configured_keys.contains(&snapshot_key(&snapshot.repository, snapshot.number)) {
            snapshot.viewer_review_requested = Some(false);
        }
    }
}

fn snapshot_key(repository: &str, number: u64) -> String {
    format!("{}#{number}", repository.trim().to_ascii_lowercase())
}

async fn reconcile_snapshots(
    database: &AsyncDaemonDb,
    snapshots: Vec<GitHubPullRequestSnapshot>,
) -> Result<usize, CliError> {
    let items = database.list_task_board_items(None).await?;
    let mut update_count = 0;
    for item in items {
        let mutation = database
            .update_task_board_item(&item.id, |current| {
                Ok(reconcile_review_item_from_snapshots(current, &snapshots))
            })
            .await?;
        update_count += usize::from(mutation.is_some());
    }
    Ok(update_count)
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
        let query_scope = ReviewsQueryRequest {
            repositories: vec!["example/repo".into(), "example/other".into()],
            ..ReviewsQueryRequest::default()
        };
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
            &query_scope,
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
    fn per_repository_query_resolves_only_imports_in_its_scope() {
        let query_scope = ReviewsQueryRequest {
            repositories: vec!["acme/api".into()],
            ..ReviewsQueryRequest::default()
        };

        let missing = references_missing_from_snapshots(
            vec![("acme/api".into(), 1), ("acme/web".into(), 2)],
            &[],
            &query_scope,
        );

        assert_eq!(
            missing,
            vec![ReviewsPullRequestReference {
                repository: "acme/api".into(),
                number: 1,
            }]
        );
    }

    #[test]
    fn organization_query_respects_owner_scope_and_exclusions() {
        let query_scope = ReviewsQueryRequest {
            organizations: vec!["Acme".into()],
            exclude_repositories: vec!["acme/legacy".into()],
            ..ReviewsQueryRequest::default()
        };

        let missing = references_missing_from_snapshots(
            vec![
                ("acme/api".into(), 1),
                ("acme/legacy".into(), 2),
                ("other/api".into(), 3),
            ],
            &[],
            &query_scope,
        );

        assert_eq!(
            missing,
            vec![ReviewsPullRequestReference {
                repository: "acme/api".into(),
                number: 1,
            }]
        );
    }

    #[test]
    fn targeted_refresh_uses_only_its_provided_snapshots() {
        let scoped = MissingReviewResolution::ExactActiveImports(ReviewsQueryRequest::default());
        assert!(scoped.query_scope().is_some());
        assert!(
            MissingReviewResolution::ProvidedSnapshotsOnly
                .query_scope()
                .is_none()
        );
    }
}
