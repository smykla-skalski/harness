use crate::reviews::{
    ReviewFile, ReviewFilePatch, ReviewItem, ReviewsActionResponse, ReviewsApproveRequest,
    ReviewsBodyRequest, ReviewsFilesListRequest, ReviewsFilesPatchRequest, ReviewsQueryRequest,
    ReviewsQueryResponse,
};
use harness_kernel::errors::{CliError, CliErrorKind};

const MAX_IMMUTABLE_REVIEW_CONTENT_BYTES: usize = 512 * 1024;

pub(crate) struct RepositoryReviewsSnapshot {
    pub(crate) response: ReviewsQueryResponse,
    pub(crate) github_data_revision: u64,
}

pub(crate) async fn query_repository_reviews(
    request: &ReviewsQueryRequest,
) -> Result<RepositoryReviewsSnapshot, CliError> {
    let (response, github_data_revision) =
        super::reviews::query_repository_reviews_snapshot_parts(request).await?;
    Ok(RepositoryReviewsSnapshot {
        response,
        github_data_revision,
    })
}

pub(crate) async fn resolve_exact_pull_request(
    repository: &str,
    number: u64,
) -> Result<ReviewItem, CliError> {
    super::reviews::resolve_exact_pull_request(repository, number).await
}

pub(crate) async fn immutable_pull_request_content(
    repository: &str,
    number: u64,
    expected_head: &str,
) -> Result<String, CliError> {
    let pull_request = resolve_exact_pull_request(repository, number).await?;
    if pull_request.head_sha != expected_head {
        return Err(source_changed(expected_head, &pull_request.head_sha));
    }
    let files = super::reviews_files::list_review_files(&ReviewsFilesListRequest {
        pull_request_id: pull_request.pull_request_id.clone(),
        force_refresh: true,
    })
    .await?;
    if files.head_ref_oid != expected_head {
        return Err(source_changed(expected_head, &files.head_ref_oid));
    }
    if !files.pagination_complete {
        return Err(
            CliErrorKind::invalid_transition("pull request file metadata is incomplete").into(),
        );
    }
    let description = super::reviews::fetch_review_body(&ReviewsBodyRequest {
        pull_request_id: pull_request.pull_request_id.clone(),
        force_refresh: true,
        cache_max_age_seconds: 0,
    })
    .await?;
    if description.pull_request_id != pull_request.pull_request_id {
        return Err(CliErrorKind::invalid_transition(
            "pull request description belongs to a different pull request",
        )
        .into());
    }
    let patches_response = super::reviews_files::patch_review_files(&ReviewsFilesPatchRequest {
        pull_request_id: pull_request.pull_request_id.clone(),
        head_ref_oid_expected: expected_head.to_string(),
        paths: files.files.iter().map(|file| file.path.clone()).collect(),
        number: Some(number),
        repository_full_name: Some(repository.to_string()),
    })
    .await?;
    let patches = &patches_response;
    if patches.drifted || patches.current_head_ref_oid != expected_head {
        return Err(source_changed(expected_head, &patches.current_head_ref_oid));
    }
    if !patches_exactly_match_files(&files.files, &patches.patches, expected_head) {
        return Err(
            CliErrorKind::invalid_transition("exact pull request diff is unavailable").into(),
        );
    }
    let final_pull_request = resolve_exact_pull_request(repository, number).await?;
    if final_pull_request.pull_request_id != pull_request.pull_request_id
        || final_pull_request.head_sha != expected_head
    {
        return Err(source_changed(expected_head, &final_pull_request.head_sha));
    }
    let content = serde_json::to_string(&serde_json::json!({
        "pull_request": pull_request,
        "description": description.body,
        "files": files.files,
        "patches": patches.patches,
    }))
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "could not encode immutable pull request content: {error}"
        )))
    })?;
    if content.len() > MAX_IMMUTABLE_REVIEW_CONTENT_BYTES {
        return Err(CliErrorKind::invalid_transition(format!(
            "immutable pull request content is {} bytes, exceeding the {} byte review limit",
            content.len(),
            MAX_IMMUTABLE_REVIEW_CONTENT_BYTES
        ))
        .into());
    }
    Ok(content)
}

fn patches_exactly_match_files(
    files: &[ReviewFile],
    patches: &[ReviewFilePatch],
    expected_head: &str,
) -> bool {
    patches.len() == files.len()
        && files.iter().all(|file| {
            patches.iter().any(|patch| {
                patch.path == file.path
                    && patch.status == file.change_type
                    && patch.additions == file.additions
                    && patch.deletions == file.deletions
                    && !patch.truncated
                    && patch.head_ref_oid == expected_head
                    && !patch.patch.trim().is_empty()
            })
        })
}

fn source_changed(expected: &str, actual: &str) -> CliError {
    CliErrorKind::invalid_transition(format!(
        "pull request head changed while freezing review input: expected '{expected}', found '{actual}'"
    ))
    .into()
}

pub(crate) async fn approve_pull_requests(
    request: &ReviewsApproveRequest,
) -> Result<ReviewsActionResponse, CliError> {
    super::reviews::approve_reviews(request).await
}

#[cfg(test)]
mod tests {
    use crate::reviews::{
        HarnessCodeLanguage, ReviewFile, ReviewFileChangeType, ReviewFilePatch,
        ReviewFileServedBy, ReviewFileViewedState,
    };

    use super::patches_exactly_match_files;

    #[test]
    fn truncated_patch_is_not_exact_immutable_review_content() {
        let files = vec![ReviewFile {
            path: "src/lib.rs".to_string(),
            previous_path: None,
            change_type: ReviewFileChangeType::Modified,
            additions: 2,
            deletions: 1,
            viewer_viewed_state: ReviewFileViewedState::Unviewed,
            is_binary: false,
            language_hint: HarnessCodeLanguage::Rust,
            mode_change: None,
        }];
        let patches = vec![ReviewFilePatch {
            path: "src/lib.rs".to_string(),
            patch: "@@ -1 +1 @@".to_string(),
            status: ReviewFileChangeType::Modified,
            additions: 2,
            deletions: 1,
            truncated: true,
            etag: None,
            served_by: ReviewFileServedBy::GithubRest,
            fetched_at: String::new(),
            head_ref_oid: "abc123".to_string(),
        }];

        assert!(!patches_exactly_match_files(&files, &patches, "abc123"));
    }
}
