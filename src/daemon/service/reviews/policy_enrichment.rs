use std::collections::BTreeMap;

use crate::reviews::files::patch_rest::any_patch_matches;
use crate::reviews::{
    ReviewMergeableState, ReviewTarget, ReviewsGitHubClient, ReviewsRefreshRequest,
};

use super::token::github_token;

pub(super) async fn enrich_policy_target_for_execution(target: &ReviewTarget) -> ReviewTarget {
    enrich_policy_targets_for_execution(std::slice::from_ref(target))
        .await
        .into_iter()
        .next()
        .unwrap_or_else(|| target.clone())
}

pub(super) async fn enrich_policy_targets_for_execution(
    targets: &[ReviewTarget],
) -> Vec<ReviewTarget> {
    let mut enriched = targets.to_vec();
    for (token, indexed_targets) in token_indexed_targets(targets) {
        let Ok(client) = ReviewsGitHubClient::new(&token) else {
            continue;
        };
        for (index, target) in refresh_policy_targets(&client, indexed_targets).await {
            enriched[index] = target;
        }
    }
    enriched
}

fn should_scan_conflict_markers(
    mergeable: ReviewMergeableState,
    has_conflict_markers: Option<bool>,
) -> bool {
    mergeable != ReviewMergeableState::Conflicting && has_conflict_markers.is_none()
}

fn token_indexed_targets(targets: &[ReviewTarget]) -> BTreeMap<String, Vec<(usize, ReviewTarget)>> {
    let global_token = github_token(None);
    let mut grouped = BTreeMap::<String, Vec<(usize, ReviewTarget)>>::new();
    for (index, target) in targets.iter().enumerate() {
        let Some(token) =
            github_token(Some(target.repository.as_str())).or_else(|| global_token.clone())
        else {
            continue;
        };
        grouped
            .entry(token)
            .or_default()
            .push((index, target.clone()));
    }
    grouped
}

async fn refresh_policy_targets(
    client: &ReviewsGitHubClient,
    indexed_targets: Vec<(usize, ReviewTarget)>,
) -> Vec<(usize, ReviewTarget)> {
    let viewer_login = client.fetch_viewer_login().await;
    let targets = indexed_targets
        .iter()
        .map(|(_, target)| target.clone())
        .collect::<Vec<_>>();
    let ids = targets
        .iter()
        .map(|target| target.pull_request_id.clone())
        .collect::<Vec<_>>();
    let request = ReviewsRefreshRequest {
        targets,
        backport_detection_enabled: false,
        backport_patterns: Vec::new(),
    };
    let Ok(fetch) = client
        .fetch_by_ids(&ids, &request, viewer_login.as_deref())
        .await
    else {
        return Vec::new();
    };
    let mut refreshed = fetch
        .items
        .into_iter()
        .map(|item| (item.pull_request_id.clone(), item.target()))
        .collect::<BTreeMap<_, _>>();
    let mut results = Vec::with_capacity(indexed_targets.len());
    for (index, original) in indexed_targets {
        let target = refreshed
            .remove(&original.pull_request_id)
            .unwrap_or(original);
        results.push((
            index,
            refresh_conflict_marker_evidence(client, target).await,
        ));
    }
    results
}

async fn refresh_conflict_marker_evidence(
    client: &ReviewsGitHubClient,
    mut target: ReviewTarget,
) -> ReviewTarget {
    if should_scan_conflict_markers(target.mergeable, target.has_conflict_markers)
        && let Some(has_conflict_markers) = scan_conflict_markers(client, &target).await
    {
        target.has_conflict_markers = Some(has_conflict_markers);
    }
    target
}

async fn scan_conflict_markers(
    client: &ReviewsGitHubClient,
    target: &ReviewTarget,
) -> Option<bool> {
    match any_patch_matches(
        client.protected(),
        &target.repository,
        target.number,
        patch_has_added_conflict_marker,
    )
    .await
    {
        Ok(has_conflict_markers) => Some(has_conflict_markers),
        Err(error) => {
            tracing::warn!(
                repository = %target.repository,
                pull_request = target.number,
                head_sha = %target.head_sha,
                %error,
                "failed to scan pull request patches for conflict markers"
            );
            None
        }
    }
}

fn patch_has_added_conflict_marker(patch: &str) -> bool {
    patch.lines().any(added_line_is_conflict_marker)
}

fn added_line_is_conflict_marker(line: &str) -> bool {
    let Some(added) = line.strip_prefix('+') else {
        return false;
    };
    if added.starts_with("+++") {
        return false;
    }
    let trimmed = added.trim_start();
    trimmed.starts_with("<<<<<<<") || trimmed == "=======" || trimmed.starts_with(">>>>>>>")
}

#[cfg(test)]
mod tests {
    use crate::reviews::ReviewMergeableState;

    use super::{patch_has_added_conflict_marker, should_scan_conflict_markers};

    #[test]
    fn detects_added_conflict_marker_lines() {
        let patch = "@@ -1 +1 @@\n+<<<<<<< HEAD\n+body\n+=======\n+other\n+>>>>>>> branch\n";
        assert!(patch_has_added_conflict_marker(patch));
    }

    #[test]
    fn ignores_patch_headers_and_removed_markers() {
        let patch = "+++ b/src/lib.rs\n-<<<<<<< HEAD\n context\n";
        assert!(!patch_has_added_conflict_marker(patch));
    }

    #[test]
    fn skips_marker_scan_when_conflicts_or_marker_evidence_are_known() {
        assert!(should_scan_conflict_markers(
            ReviewMergeableState::Mergeable,
            None
        ));
        assert!(should_scan_conflict_markers(
            ReviewMergeableState::Unknown,
            None
        ));
        assert!(!should_scan_conflict_markers(
            ReviewMergeableState::Conflicting,
            None
        ));
        assert!(!should_scan_conflict_markers(
            ReviewMergeableState::Mergeable,
            Some(false)
        ));
        assert!(!should_scan_conflict_markers(
            ReviewMergeableState::Mergeable,
            Some(true)
        ));
    }
}
