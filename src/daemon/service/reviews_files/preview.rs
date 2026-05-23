//! Bounded patch previews for the inline-PR Files section.

use crate::errors::{CliError, CliErrorKind};
use crate::reviews::files::service::FilesLargeDiffStrategy;
use crate::reviews::{
    ReviewsFilesPatchRequest, ReviewsFilesPreviewRequest, ReviewsFilesPreviewResponse,
    preview_from_patch,
};

use super::patch::patch_review_files;

/// Fetch bounded patch previews for selected paths in one pull request.
///
/// This reuses the same routing and drift logic as the full-patch endpoint,
/// then truncates each returned patch before it crosses into the Monitor's
/// render path.
pub async fn preview_review_files(
    request: &ReviewsFilesPreviewRequest,
) -> Result<ReviewsFilesPreviewResponse, CliError> {
    let pull_request_id = request.normalized_pull_request_id();
    if pull_request_id.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews files preview: pull_request_id must not be empty",
        )
        .into());
    }
    let line_limit = request.normalized_line_limit();
    let patch_request = patch_request_from_preview(request);
    let response = patch_review_files(&patch_request).await?;
    Ok(ReviewsFilesPreviewResponse {
        pull_request_id: response.pull_request_id,
        previews: response
            .patches
            .into_iter()
            .map(|patch| preview_from_patch(patch, line_limit))
            .collect(),
        drifted: response.drifted,
        current_head_ref_oid: response.current_head_ref_oid,
        fetched_at: response.fetched_at,
        rate_limit_snapshot: response.rate_limit_snapshot,
    })
}

fn patch_request_from_preview(request: &ReviewsFilesPreviewRequest) -> ReviewsFilesPatchRequest {
    ReviewsFilesPatchRequest {
        pull_request_id: request.pull_request_id.clone(),
        head_ref_oid_expected: request.head_ref_oid_expected.clone(),
        paths: request.normalized_paths(),
        number: request.number,
        repository_full_name: request.repository_full_name.clone(),
        base_ref_oid_expected: request.base_ref_oid_expected.clone(),
        head_ref_name: request.head_ref_name.clone(),
        base_ref_name: request.base_ref_name.clone(),
        large_diff_strategy: preview_patch_strategy(request),
    }
}

fn preview_patch_strategy(request: &ReviewsFilesPreviewRequest) -> Option<FilesLargeDiffStrategy> {
    if request.number.is_some()
        && request
            .repository_full_name
            .as_deref()
            .is_some_and(|name| !name.trim().is_empty())
    {
        Some(FilesLargeDiffStrategy::ForceGitHubRest)
    } else {
        request.large_diff_strategy
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn patch_request_from_preview_preserves_context() {
        let request = ReviewsFilesPreviewRequest {
            pull_request_id: "PR_1".into(),
            head_ref_oid_expected: "head".into(),
            paths: vec![" src/lib.rs ".into(), "".into()],
            number: Some(7),
            repository_full_name: Some("owner/repo".into()),
            base_ref_oid_expected: Some("base".into()),
            head_ref_name: Some("feature".into()),
            base_ref_name: Some("main".into()),
            large_diff_strategy: None,
            line_limit: 50,
        };
        let patch = patch_request_from_preview(&request);
        assert_eq!(patch.pull_request_id, "PR_1");
        assert_eq!(patch.head_ref_oid_expected, "head");
        assert_eq!(patch.paths, vec!["src/lib.rs"]);
        assert_eq!(patch.number, Some(7));
        assert_eq!(patch.repository_full_name.as_deref(), Some("owner/repo"));
        assert_eq!(patch.base_ref_oid_expected.as_deref(), Some("base"));
        assert_eq!(
            patch.large_diff_strategy,
            Some(FilesLargeDiffStrategy::ForceGitHubRest)
        );
    }

    #[test]
    fn patch_request_from_preview_preserves_strategy_without_rest_context() {
        let request = ReviewsFilesPreviewRequest {
            pull_request_id: "PR_1".into(),
            head_ref_oid_expected: "head".into(),
            paths: vec!["src/lib.rs".into()],
            number: None,
            repository_full_name: None,
            base_ref_oid_expected: Some("base".into()),
            head_ref_name: Some("feature".into()),
            base_ref_name: Some("main".into()),
            large_diff_strategy: Some(FilesLargeDiffStrategy::AutoLocalClone),
            line_limit: 50,
        };

        let patch = patch_request_from_preview(&request);

        assert_eq!(
            patch.large_diff_strategy,
            Some(FilesLargeDiffStrategy::AutoLocalClone)
        );
    }
}
