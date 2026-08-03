//! GitHub REST patch fetching for the inline-PR Files section.

use crate::reviews::files::patch_rest;
use crate::reviews::{ReviewsFilesPatchRequest, ReviewsFilesPatchResponse, ReviewsGitHubClient};
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::token::{github_token, missing_token_error};

/// Fetch patches for selected paths in one pull request via GitHub REST.
///
/// # Errors
/// Returns `CliError` for invalid requests or when repository context is
/// missing (no token or no repo name + PR number).
pub async fn patch_review_files(
    request: &ReviewsFilesPatchRequest,
) -> Result<ReviewsFilesPatchResponse, CliError> {
    let pull_request_id = request.normalized_pull_request_id();
    if pull_request_id.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews files patch: pull_request_id must not be empty",
        )
        .into());
    }
    if request.head_ref_oid_expected.trim().is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews files patch: head_ref_oid_expected must not be empty",
        )
        .into());
    }

    let normalized_paths = request.normalized_paths();
    let repo_full_name = request.repository_full_name.as_deref();

    if let Some(result) =
        try_rest_patch(&pull_request_id, request, repo_full_name, &normalized_paths).await?
    {
        return Ok(result);
    }

    warn_no_patch_context(&pull_request_id);
    Ok(ReviewsFilesPatchResponse {
        pull_request_id,
        patches: Vec::new(),
        drifted: false,
        current_head_ref_oid: request.head_ref_oid_expected.clone(),
        fetched_at: utc_now(),
        rate_limit_snapshot: None,
    })
}

fn warn_no_patch_context(pull_request_id: &str) {
    tracing::warn!(
        target = "harness::daemon::reviews::files",
        "patch_review_files surfaced empty patches (caller missing repo + number): pr={pull_request_id}"
    );
}

async fn try_rest_patch(
    pull_request_id: &str,
    request: &ReviewsFilesPatchRequest,
    repo_full_name: Option<&str>,
    normalized_paths: &[String],
) -> Result<Option<ReviewsFilesPatchResponse>, CliError> {
    let (Some(repo_full_name), Some(number)) = (repo_full_name, request.number) else {
        return Ok(None);
    };
    let token = github_token(Some(repo_full_name))
        .ok_or_else(|| missing_token_error(Some(repo_full_name)))?;
    run_rest_patch(
        pull_request_id,
        repo_full_name,
        &token,
        number,
        &request.head_ref_oid_expected,
        normalized_paths,
    )
    .await
    .map(Some)
}

async fn run_rest_patch(
    pull_request_id: &str,
    repo_full_name: &str,
    token: &str,
    number: u64,
    head_ref_oid: &str,
    paths: &[String],
) -> Result<ReviewsFilesPatchResponse, CliError> {
    let current_head = resolve_patch_head(pull_request_id, repo_full_name, number).await?;
    if head_drifted(head_ref_oid, &current_head) {
        return Ok(drifted_response(pull_request_id, current_head));
    }
    let client = ReviewsGitHubClient::new(token)?;
    let patches = patch_rest::fetch_patches(
        client.protected(),
        repo_full_name,
        number,
        head_ref_oid,
        paths,
    )
    .await
    .map_err(|error| -> CliError {
        CliErrorKind::workflow_io(format!("rest patch fetch failed: {error}")).into()
    })?;
    let current_head = resolve_patch_head(pull_request_id, repo_full_name, number).await?;
    if head_drifted(head_ref_oid, &current_head) {
        return Ok(drifted_response(pull_request_id, current_head));
    }
    let fetched_at = utc_now();
    let patches = patches
        .into_iter()
        .map(|mut p| {
            if p.fetched_at.is_empty() {
                p.fetched_at.clone_from(&fetched_at);
            }
            p
        })
        .collect();
    Ok(ReviewsFilesPatchResponse {
        pull_request_id: pull_request_id.to_string(),
        patches,
        drifted: false,
        current_head_ref_oid: head_ref_oid.to_string(),
        fetched_at,
        rate_limit_snapshot: None,
    })
}

async fn resolve_patch_head(
    pull_request_id: &str,
    repository: &str,
    number: u64,
) -> Result<String, CliError> {
    let pull_request = super::super::reviews::resolve_exact_pull_request(repository, number).await?;
    if pull_request.pull_request_id != pull_request_id {
        return Err(CliErrorKind::invalid_transition(format!(
            "reviews files patch target mismatch: expected '{pull_request_id}', found '{}'",
            pull_request.pull_request_id
        ))
        .into());
    }
    Ok(pull_request.head_sha)
}

fn head_drifted(expected: &str, current: &str) -> bool {
    !expected.trim().eq_ignore_ascii_case(current.trim())
}

fn drifted_response(pull_request_id: &str, current_head_ref_oid: String) -> ReviewsFilesPatchResponse {
    ReviewsFilesPatchResponse {
        pull_request_id: pull_request_id.to_string(),
        patches: Vec::new(),
        drifted: true,
        current_head_ref_oid,
        fetched_at: utc_now(),
        rate_limit_snapshot: None,
    }
}

#[cfg(test)]
mod tests {
    use super::{drifted_response, head_drifted};

    #[test]
    fn head_drift_comparison_ignores_whitespace_and_hex_case() {
        assert!(!head_drifted(" ABC123 ", "abc123"));
        assert!(head_drifted("abc123", "def456"));
    }

    #[test]
    fn drift_response_never_returns_revision_mislabeled_patches() {
        let response = drifted_response("PR_1", "def456".to_string());

        assert!(response.drifted);
        assert_eq!(response.current_head_ref_oid, "def456");
        assert!(response.patches.is_empty());
    }
}
