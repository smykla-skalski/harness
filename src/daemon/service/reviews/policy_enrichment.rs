use crate::reviews::files::patch_rest::fetch_patches;
use crate::reviews::{ReviewTarget, ReviewsGitHubClient, ReviewsRefreshRequest};

use super::token::github_token;

pub(super) async fn enrich_policy_target_for_execution(target: &ReviewTarget) -> ReviewTarget {
    let Some(token) = github_token(Some(&target.repository)).or_else(|| github_token(None)) else {
        return target.clone();
    };
    let Ok(client) = ReviewsGitHubClient::new(&token) else {
        return target.clone();
    };
    let mut enriched = refresh_policy_target(&client, target)
        .await
        .unwrap_or_else(|| target.clone());
    if let Some(has_conflict_markers) = scan_conflict_markers(&client, &enriched).await {
        enriched.has_conflict_markers = Some(has_conflict_markers);
    }
    enriched
}

async fn refresh_policy_target(
    client: &ReviewsGitHubClient,
    target: &ReviewTarget,
) -> Option<ReviewTarget> {
    let viewer_login = client.fetch_viewer_login().await;
    let request = ReviewsRefreshRequest {
        targets: vec![target.clone()],
        backport_detection_enabled: false,
        backport_patterns: Vec::new(),
    };
    client
        .fetch_by_ids(
            &[target.pull_request_id.clone()],
            &request,
            viewer_login.as_deref(),
        )
        .await
        .ok()?
        .items
        .into_iter()
        .next()
        .map(|item| item.target())
}

async fn scan_conflict_markers(
    client: &ReviewsGitHubClient,
    target: &ReviewTarget,
) -> Option<bool> {
    fetch_patches(
        client.protected(),
        &target.repository,
        target.number,
        &target.head_sha,
        &[],
    )
    .await
    .ok()
    .map(|patches| {
        patches
            .iter()
            .any(|patch| patch_has_added_conflict_marker(&patch.patch))
    })
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
    use super::patch_has_added_conflict_marker;

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
}
