//! REST or local-clone patch fetching for the inline-PR Files section.

use std::fmt;

use crate::errors::{CliError, CliErrorKind};
use crate::reviews::files::local_clone::{Sensitive, pat_clone_url};
use crate::reviews::files::local_clone_diff::compute_unified_patches;
use crate::reviews::files::local_clone_runtime::diff::LocalCloneFetchRef;
use crate::reviews::files::patch_rest;
use crate::reviews::files::service::FilesLargeDiffStrategy;
use crate::reviews::{
    ReviewsFilesPatchRequest, ReviewsFilesPatchResponse, ReviewsGitHubClient,
};
use crate::workspace::utc_now;

use super::token::github_token;
use super::{local_clone_runtime, progress_sink};

/// Fetch patches for selected paths in one pull request.
///
/// Uses the local-clone runtime when the request includes repository/ref
/// context and the selected strategy allows it. If that path is unavailable
/// or fails, falls back to GitHub REST when `repository_full_name` and the PR
/// number are present. Missing context returns an empty patch list so older
/// clients fail closed instead of making an unauthenticated GitHub call.
///
/// # Errors
/// Returns `CliError` for invalid requests.
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
    patch_review_files_inner(request, pull_request_id).await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_no_patch_context(pull_request_id: &str) {
    let msg = format!("patch_review_files surfaced empty patches (caller missing repo + number): pr={pull_request_id}");
    tracing::warn!(target = "harness::reviews::files", "{msg}");
}

async fn patch_review_files_inner(
    request: &ReviewsFilesPatchRequest,
    pull_request_id: String,
) -> Result<ReviewsFilesPatchResponse, CliError> {
    let strategy = request.large_diff_strategy.unwrap_or_default();
    let normalized_paths = request.normalized_paths();
    let repo_full_name = request.repository_full_name.as_deref();
    let base_oid = request.base_ref_oid_expected.as_deref();

    let allow_local_clone = strategy != FilesLargeDiffStrategy::ForceGitHubRest;
    if let Some(result) = try_local_clone_patch(
        allow_local_clone,
        &pull_request_id,
        request,
        repo_full_name,
        base_oid,
        &normalized_paths,
    )
    .await
    {
        return Ok(result);
    }

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

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_local_clone_fallback(pull_request_id: &str, repo: &str, error: &dyn fmt::Display) {
    let msg = format!("local-clone patch failed, falling back to REST: pr={pull_request_id} repo={repo} error={error}");
    tracing::warn!(target = "harness::reviews::files", "{msg}");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_rest_fallback(pull_request_id: &str, repo: &str, number: u64, error: &dyn fmt::Display) {
    let msg = format!("REST patch fetch failed: pr={pull_request_id} repo={repo} number={number} error={error}");
    tracing::warn!(target = "harness::reviews::files", "{msg}");
}

async fn try_local_clone_patch(
    allow_local_clone: bool,
    pull_request_id: &str,
    request: &ReviewsFilesPatchRequest,
    repo_full_name: Option<&str>,
    base_oid: Option<&str>,
    normalized_paths: &[String],
) -> Option<ReviewsFilesPatchResponse> {
    if !allow_local_clone {
        return None;
    }
    let (Some(repo_full_name), Some(base_oid)) = (repo_full_name, base_oid) else {
        return None;
    };
    let Some(token) = github_token(Some(repo_full_name)) else {
        return None;
    };
    match run_local_clone_patch(
        pull_request_id,
        repo_full_name,
        &token,
        &request.head_ref_oid_expected,
        base_oid,
        request.number,
        request.head_ref_name.as_deref(),
        request.base_ref_name.as_deref(),
        normalized_paths,
    )
    .await
    {
        Ok(response) => Some(response),
        Err(error) => {
            warn_local_clone_fallback(pull_request_id, repo_full_name, &error);
            None
        }
    }
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
    let Some(token) = github_token(Some(repo_full_name)) else {
        return None;
    };
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
        client.octocrab(),
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

async fn run_local_clone_patch(
    pull_request_id: &str,
    repo_full_name: &str,
    token: &str,
    head_ref_oid: &str,
    base_oid: &str,
    number: Option<u64>,
    head_ref_name: Option<&str>,
    base_ref_name: Option<&str>,
    paths: &[String],
) -> Result<ReviewsFilesPatchResponse, CliError> {
    let runtime = local_clone_runtime();
    let sink = progress_sink();
    let (fetch_refs, head_ref) =
        local_clone_fetch_context(number, head_ref_name, base_ref_name);
    let token = Sensitive::new(token);
    let clone_url = pat_clone_url(repo_full_name, &token);
    let ensured = runtime
        .ensure_clone_refs_with_url(
            repo_full_name,
            clone_url.expose(),
            &fetch_refs,
            &head_ref,
            sink,
        )
        .await
        .map_err(|error| -> CliError {
            CliErrorKind::workflow_io(format!("ensure local clone failed: {error}")).into()
        })?;

    let path_filter: Option<&[String]> = if paths.is_empty() { None } else { Some(paths) };
    let patches = compute_unified_patches(&ensured, base_oid, head_ref_oid, path_filter)
        .await
        .map_err(|error| -> CliError {
            CliErrorKind::workflow_io(format!("compute local-clone diff failed: {error}")).into()
        })?;

    Ok(ReviewsFilesPatchResponse {
        pull_request_id: pull_request_id.to_string(),
        patches,
        drifted: false,
        current_head_ref_oid: head_ref_oid.to_string(),
        fetched_at: utc_now(),
        rate_limit_snapshot: None,
    })
}

pub(super) fn local_clone_fetch_context(
    number: Option<u64>,
    head_ref_name: Option<&str>,
    base_ref_name: Option<&str>,
) -> (Vec<LocalCloneFetchRef>, String) {
    let mut refs = Vec::new();
    let head_ref = if let Some(number) = number {
        let pull_ref = LocalCloneFetchRef::github_pull_head(number);
        let local_ref = pull_ref.local_ref.clone();
        refs.push(pull_ref);
        local_ref
    } else if let Some(name) = head_ref_name {
        let head_ref = LocalCloneFetchRef::mirrored(branch_ref(name));
        let local_ref = head_ref.local_ref.clone();
        refs.push(head_ref);
        local_ref
    } else {
        format!("refs/heads/{}", default_head_ref_branch())
    };
    if let Some(name) = base_ref_name {
        refs.push(LocalCloneFetchRef::mirrored(branch_ref(name)));
    }
    (refs, head_ref)
}

fn branch_ref(name: &str) -> String {
    if name.starts_with("refs/") {
        name.to_string()
    } else {
        format!("refs/heads/{name}")
    }
}

/// The default branch name used to fabricate `refs/heads/<name>` when the
/// caller doesn't supply an explicit head ref. GitHub doesn't expose the
/// PR's branch name in the node id; the caller is encouraged to drift the
/// runtime by fetching the actual ref shortly afterward. For the initial
/// clone path we use `main` as a sensible default - the runtime's
/// subsequent fetch will pick up the head OID directly.
fn default_head_ref_branch() -> &'static str {
    "main"
}
