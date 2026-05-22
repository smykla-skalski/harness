//! Service handlers for the inline-PR Files section.
//!
//! Five endpoints back the Monitor's `Dependencies > Files` flow:
//!
//! - `list_dependency_update_files`        - GraphQL metadata fetch.
//! - `patch_dependency_update_files`       - REST or local-clone patches.
//! - `mark_dependency_update_files_viewed` - hash-guarded mark-viewed batch.
//! - `fetch_dependency_update_file_blob`   - image-preview blob fetch.
//! - `list_dependency_update_local_clones` - Settings-panel listing.
//!
//! The list endpoint goes live with this commit (it composes the existing
//! `Octocrab` client + the GraphQL `LIST_PR_FILES_QUERY`). The patch,
//! viewed, blob, and local-clones endpoints return shaped placeholders so
//! the Monitor side (B/C/D phases) can wire UI against the type contracts.
//! Each placeholder is annotated with a TODO and surfaces a warning log
//! when called so the operator can see traffic before the implementation
//! lands.

use crate::dependency_updates::{
    DependencyUpdateFilesViewedResult, DependencyUpdateFileViewedOutcome, DependencyUpdateImageMime,
    DependencyUpdatesFilesBlobRequest, DependencyUpdatesFilesBlobResponse,
    DependencyUpdatesFilesListRequest, DependencyUpdatesFilesListResponse,
    DependencyUpdatesFilesPatchRequest, DependencyUpdatesFilesPatchResponse,
    DependencyUpdatesFilesViewedRequest, DependencyUpdatesFilesViewedResponse,
    DependencyUpdatesGitHubClient, LocalCloneListEntry,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::ExternalProvider;
use crate::workspace::utc_now;

use super::task_board_runtime::external_sync_config_for_repository;

/// List the changed files for one pull request.
///
/// # Errors
/// Returns `CliError` when the GitHub token is missing or the GraphQL fetch
/// fails.
pub async fn list_dependency_update_files(
    request: &DependencyUpdatesFilesListRequest,
) -> Result<DependencyUpdatesFilesListResponse, CliError> {
    let pull_request_id = request.normalized_pull_request_id();
    if pull_request_id.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "dependency-updates files list: pull_request_id must not be empty",
        )
        .into());
    }
    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = DependencyUpdatesGitHubClient::new(&token)?;
    client.fetch_pull_request_files(request).await
}

/// Fetch patches for selected paths in one pull request.
///
/// # Errors
/// Returns `CliError` for invalid requests; the placeholder body does not
/// reach the network so token resolution is deferred.
pub async fn patch_dependency_update_files(
    request: &DependencyUpdatesFilesPatchRequest,
) -> Result<DependencyUpdatesFilesPatchResponse, CliError> {
    let pull_request_id = request.normalized_pull_request_id();
    if pull_request_id.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "dependency-updates files patch: pull_request_id must not be empty",
        )
        .into());
    }
    tracing::warn!(
        target = "harness::dependency_updates::files",
        pull_request_id = pull_request_id,
        "patch_dependency_update_files placeholder: REST/local-clone strategy not yet wired"
    );
    Ok(DependencyUpdatesFilesPatchResponse {
        pull_request_id,
        patches: Vec::new(),
        drifted: false,
        current_head_ref_oid: request.head_ref_oid_expected.clone(),
        fetched_at: utc_now(),
        rate_limit_snapshot: None,
    })
}

/// Apply hash-guarded mark-viewed mutations across one or more paths.
///
/// # Errors
/// Returns `CliError` for empty payloads.
pub async fn mark_dependency_update_files_viewed(
    request: &DependencyUpdatesFilesViewedRequest,
) -> Result<DependencyUpdatesFilesViewedResponse, CliError> {
    let pull_request_id = request.normalized_pull_request_id();
    if pull_request_id.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "dependency-updates files viewed: pull_request_id must not be empty",
        )
        .into());
    }
    let normalized = request.normalized_paths();
    if normalized.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "dependency-updates files viewed: at least one path is required",
        )
        .into());
    }
    tracing::warn!(
        target = "harness::dependency_updates::files",
        pull_request_id = pull_request_id,
        paths = normalized.len(),
        "mark_dependency_update_files_viewed placeholder: GraphQL mutations not yet wired"
    );
    // Shape-faithful placeholder so the Monitor can render the round-trip:
    // we report `Failed` per path which the Monitor reconciles by reverting
    // its optimistic flip. Real implementation lands in a follow-up commit.
    let results = normalized
        .into_iter()
        .map(|target| DependencyUpdateFilesViewedResult {
            path: target.path,
            outcome: DependencyUpdateFileViewedOutcome::Failed,
            viewer_viewed_state: target.expected_prior_state,
        })
        .collect();
    Ok(DependencyUpdatesFilesViewedResponse {
        pull_request_id,
        results,
        fetched_at: utc_now(),
    })
}

/// Fetch an image blob's bytes for inline preview.
///
/// # Errors
/// Returns `CliError` for invalid requests.
pub async fn fetch_dependency_update_file_blob(
    request: &DependencyUpdatesFilesBlobRequest,
) -> Result<DependencyUpdatesFilesBlobResponse, CliError> {
    let oid = request.normalized_oid();
    if oid.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "dependency-updates files blob: oid must not be empty",
        )
        .into());
    }
    tracing::warn!(
        target = "harness::dependency_updates::files",
        oid = oid,
        path = request.path,
        "fetch_dependency_update_file_blob placeholder: GraphQL/REST blob fetch not yet wired"
    );
    let mime = crate::dependency_updates::image_mime_for_path(&request.path)
        .unwrap_or(DependencyUpdateImageMime::Png);
    Ok(DependencyUpdatesFilesBlobResponse {
        path: request.path.clone(),
        oid,
        mime,
        content_base64: String::new(),
        byte_size: 0,
        is_truncated: false,
        is_too_large: false,
        fetched_at: utc_now(),
        rate_limit_snapshot: None,
    })
}

/// List the local clones the daemon is currently maintaining.
///
/// # Errors
/// Currently infallible - returns an empty list until A.7's registry is
/// wired to a runtime path resolver.
pub async fn list_dependency_update_local_clones() -> Result<Vec<LocalCloneListEntry>, CliError> {
    tracing::warn!(
        target = "harness::dependency_updates::files",
        "list_dependency_update_local_clones placeholder: registry not yet wired to runtime path"
    );
    Ok(Vec::new())
}

fn github_token(repository: Option<&str>) -> Option<String> {
    external_sync_config_for_repository(repository, &[])
        .token_for(ExternalProvider::GitHub)
        .map(ToString::to_string)
}

fn missing_token_error(repository: Option<&str>) -> CliError {
    match repository {
        Some(repository) => CliErrorKind::workflow_io(format!(
            "dependency-updates files requires a GitHub token for '{repository}'. \
             Configure one in Settings > Secrets."
        ))
        .into(),
        None => CliErrorKind::workflow_io(
            "dependency-updates files requires a GitHub token. \
             Configure one in Settings > Secrets.",
        )
        .into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn list_request_rejects_empty_pull_request_id() {
        let request = DependencyUpdatesFilesListRequest {
            pull_request_id: "   ".into(),
            force_refresh: false,
        };
        let err = list_dependency_update_files(&request).await.unwrap_err();
        assert!(err.to_string().to_lowercase().contains("pull_request_id"));
    }

    #[tokio::test]
    async fn patch_request_rejects_empty_pull_request_id() {
        let request = DependencyUpdatesFilesPatchRequest {
            pull_request_id: "".into(),
            head_ref_oid_expected: "abc".into(),
            paths: vec!["src/lib.rs".into()],
        };
        let err = patch_dependency_update_files(&request).await.unwrap_err();
        assert!(err.to_string().to_lowercase().contains("pull_request_id"));
    }

    #[tokio::test]
    async fn patch_placeholder_returns_empty_patches_under_drift() {
        let request = DependencyUpdatesFilesPatchRequest {
            pull_request_id: "PR_1".into(),
            head_ref_oid_expected: "abc".into(),
            paths: vec!["src/lib.rs".into()],
        };
        let response = patch_dependency_update_files(&request).await.expect("ok");
        assert_eq!(response.pull_request_id, "PR_1");
        assert!(response.patches.is_empty());
        assert!(!response.drifted);
        assert_eq!(response.current_head_ref_oid, "abc");
    }

    #[tokio::test]
    async fn viewed_request_rejects_empty_paths() {
        let request = DependencyUpdatesFilesViewedRequest {
            pull_request_id: "PR_1".into(),
            paths: vec![],
        };
        let err = mark_dependency_update_files_viewed(&request)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("path"));
    }

    #[tokio::test]
    async fn viewed_request_drops_blank_paths_before_processing() {
        use crate::dependency_updates::DependencyUpdateFilesViewedTarget;
        use crate::dependency_updates::DependencyUpdateFileViewedState;
        let request = DependencyUpdatesFilesViewedRequest {
            pull_request_id: "PR_1".into(),
            paths: vec![
                DependencyUpdateFilesViewedTarget {
                    path: "  ".into(),
                    expected_prior_state: DependencyUpdateFileViewedState::Unviewed,
                    mark_viewed: true,
                },
                DependencyUpdateFilesViewedTarget {
                    path: "src/lib.rs".into(),
                    expected_prior_state: DependencyUpdateFileViewedState::Unviewed,
                    mark_viewed: true,
                },
            ],
        };
        let response = mark_dependency_update_files_viewed(&request)
            .await
            .expect("ok");
        assert_eq!(response.results.len(), 1);
        assert_eq!(response.results[0].path, "src/lib.rs");
    }

    #[tokio::test]
    async fn blob_request_rejects_empty_oid() {
        let request = DependencyUpdatesFilesBlobRequest {
            repository_id: "MDEwOlJlcG9zaXRvcnk".into(),
            oid: "".into(),
            path: "logo.png".into(),
        };
        let err = fetch_dependency_update_file_blob(&request)
            .await
            .unwrap_err();
        assert!(err.to_string().to_lowercase().contains("oid"));
    }

    #[tokio::test]
    async fn blob_placeholder_returns_mime_inferred_from_path() {
        let request = DependencyUpdatesFilesBlobRequest {
            repository_id: "MDEwOlJlcG9zaXRvcnk".into(),
            oid: "abc123".into(),
            path: "vector.svg".into(),
        };
        let response = fetch_dependency_update_file_blob(&request)
            .await
            .expect("ok");
        assert_eq!(response.mime, DependencyUpdateImageMime::Svg);
        assert!(response.content_base64.is_empty());
    }

    #[tokio::test]
    async fn local_clones_placeholder_returns_empty_list() {
        let response = list_dependency_update_local_clones().await.expect("ok");
        assert!(response.is_empty());
    }
}
