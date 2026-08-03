//! GitHub REST patch fetching for the inline-PR Files section.

use crate::reviews::files::patch_rest;
use crate::reviews::{ReviewsFilesPatchRequest, ReviewsFilesPatchResponse, ReviewsGitHubClient};
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::token::github_token;

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

    let normalized_paths = request.normalized_paths();
    let repo_full_name = request.repository_full_name.as_deref();

    if let Some(result) =
        try_rest_patch(&pull_request_id, request, repo_full_name, &normalized_paths).await
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
) -> Option<ReviewsFilesPatchResponse> {
    let (Some(repo_full_name), Some(number)) = (repo_full_name, request.number) else {
        return None;
    };
    let token = github_token(Some(repo_full_name))?;
    match run_rest_patch(
        pull_request_id,
        repo_full_name,
        &token,
        number,
        &request.head_ref_oid_expected,
        normalized_paths,
    )
    .await
    {
        Ok(response) => Some(response),
        Err(error) => {
            warn_rest_fallback(pull_request_id, repo_full_name, number, &error);
            None
        }
    }
}

fn warn_rest_fallback(pull_request_id: &str, repo: &str, number: u64, error: &dyn std::fmt::Display) {
    tracing::warn!(
        target = "harness::daemon::reviews::files",
        "REST patch fetch failed: pr={pull_request_id} repo={repo} number={number} error={error}"
    );
}

async fn run_rest_patch(
    pull_request_id: &str,
    repo_full_name: &str,
    token: &str,
    number: u64,
    head_ref_oid: &str,
    paths: &[String],
) -> Result<ReviewsFilesPatchResponse, CliError> {
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
