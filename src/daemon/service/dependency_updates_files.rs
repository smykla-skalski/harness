//! Service handlers for the inline-PR Files section.
//!
//! Six endpoints back the Monitor's `Dependencies > Files` flow:
//!
//! - `list_dependency_update_files`        - GraphQL metadata fetch.
//! - `patch_dependency_update_files`       - REST or local-clone patches.
//! - `mark_dependency_update_files_viewed` - hash-guarded mark-viewed batch.
//! - `fetch_dependency_update_file_blob`   - image-preview blob fetch.
//! - `list_dependency_update_local_clones` - Settings-panel listing.
//! - `delete_dependency_update_local_clone` - Settings-panel deletion.
//!
//! The list, viewed, local-clones-list, and local-clones-delete endpoints
//! are real implementations. The patch and blob endpoints remain shape-
//! faithful placeholders pending the local-clone git shell-out work +
//! REST adapter that resolves `(owner, repo, number)` from a node id; both
//! follow-ups are tracked in the project plan.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use serde::Deserialize;
use tokio::sync::broadcast;

use crate::daemon::protocol::StreamEvent;
use crate::daemon::state::daemon_root;
use crate::dependency_updates::files::local_clone::{Sensitive, pat_clone_url};
use crate::dependency_updates::files::local_clone_diff::compute_unified_patches;
use crate::dependency_updates::files::local_clone_progress_event::BroadcastProgressSink;
use crate::dependency_updates::files::local_clone_runtime::{
    DiscardProgressSink, LocalCloneProgressSink, LocalCloneRuntime, diff::LocalCloneFetchRef,
};
use crate::dependency_updates::files::patch_rest;
use crate::dependency_updates::files::service::FilesLargeDiffStrategy;
use crate::dependency_updates::{
    DependencyUpdateFileViewedOutcome, DependencyUpdateFileViewedState,
    DependencyUpdateFilesViewedResult, DependencyUpdateImageMime,
    DependencyUpdatesFilesBlobRequest, DependencyUpdatesFilesBlobResponse,
    DependencyUpdatesFilesListRequest, DependencyUpdatesFilesListResponse,
    DependencyUpdatesFilesPatchRequest, DependencyUpdatesFilesPatchResponse,
    DependencyUpdatesFilesViewedRequest, DependencyUpdatesFilesViewedResponse,
    DependencyUpdatesGitHubClient, LocalCloneListEntry, LocalCloneRegistry, LocalCloneRoot,
    ViewedMutation, classify_outcome,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::ExternalProvider;
use crate::workspace::utc_now;

use super::task_board_runtime::external_sync_config_for_repository;

const CLONES_SUBDIR: &str = "dependency_updates/clones";

/// Process-wide singletons for the local-clone runtime + progress sender.
///
/// `LOCAL_CLONE_RUNTIME` is constructed on first use; the registry path is
/// derived from `daemon_root() + CLONES_SUBDIR` and only resolved once.
///
/// `PROGRESS_SENDER` is registered explicitly by the daemon HTTP/WS setup
/// so progress events surface on the same broadcast channel the
/// `dependency_updates_local_clone_progress` WS push event flows over.
/// When unset (CLI dry-runs, tests), the handler uses `DiscardProgressSink`
/// and progress events are silently dropped.
static LOCAL_CLONE_RUNTIME: OnceLock<Arc<LocalCloneRuntime>> = OnceLock::new();
static PROGRESS_SENDER: OnceLock<broadcast::Sender<StreamEvent>> = OnceLock::new();

fn local_clone_runtime() -> Arc<LocalCloneRuntime> {
    LOCAL_CLONE_RUNTIME
        .get_or_init(|| Arc::new(LocalCloneRuntime::new(clones_root())))
        .clone()
}

fn progress_sink() -> Arc<dyn LocalCloneProgressSink> {
    if let Some(sender) = PROGRESS_SENDER.get() {
        BroadcastProgressSink::new(sender.clone())
    } else {
        Arc::new(DiscardProgressSink)
    }
}

/// Register the daemon's broadcast sender so the local-clone runtime can
/// fire `dependency_updates_local_clone_progress` push events. Idempotent
/// (first call wins; subsequent calls are no-ops via `OnceLock`).
pub fn register_local_clone_progress_sender(sender: broadcast::Sender<StreamEvent>) {
    let _ = PROGRESS_SENDER.set(sender);
}

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
/// The current implementation does not yet drive the REST pulls-list-files
/// path or the local-clone shell-out (both require owner/repo resolution
/// from the node id and a git binary respectively). Until those land the
/// handler is a shape-faithful placeholder that surfaces a warning so the
/// operator can see traffic before the implementation lands.
///
/// # Errors
/// Returns `CliError` for invalid requests.
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

    let strategy = request.large_diff_strategy.unwrap_or_default();
    let normalized_paths = request.normalized_paths();
    let repo_full_name = request.repository_full_name.as_deref();
    let base_oid = request.base_ref_oid_expected.as_deref();

    // Route through the local-clone runtime when the strategy allows it
    // AND the caller supplied enough context (repo full-name + base OID)
    // AND a token is available for the repo. ForceGitHubRest skips the
    // runtime entirely.
    let allow_local_clone = strategy != FilesLargeDiffStrategy::ForceGitHubRest;
    if allow_local_clone
        && let (Some(repo_full_name), Some(base_oid)) = (repo_full_name, base_oid)
        && let Some(token) = github_token(Some(repo_full_name))
    {
        match run_local_clone_patch(
            &pull_request_id,
            repo_full_name,
            &token,
            &request.head_ref_oid_expected,
            base_oid,
            request.number,
            request.head_ref_name.as_deref(),
            request.base_ref_name.as_deref(),
            &normalized_paths,
        )
        .await
        {
            Ok(response) => return Ok(response),
            Err(error) => {
                tracing::warn!(
                    target = "harness::dependency_updates::files",
                    pull_request_id = pull_request_id,
                    repo = repo_full_name,
                    error = %error,
                    "local-clone patch failed, falling back to REST"
                );
            }
        }
    }

    // REST path: requires repo_full_name + PR number + token. When any
    // are missing we surface an empty patches list (the Monitor renders
    // a "no patches available" affordance).
    if let (Some(repo_full_name), Some(number)) = (repo_full_name, request.number)
        && let Some(token) = github_token(Some(repo_full_name))
    {
        match run_rest_patch(
            &pull_request_id,
            repo_full_name,
            &token,
            number,
            &request.head_ref_oid_expected,
            &normalized_paths,
        )
        .await
        {
            Ok(response) => return Ok(response),
            Err(error) => {
                tracing::warn!(
                    target = "harness::dependency_updates::files",
                    pull_request_id = pull_request_id,
                    repo = repo_full_name,
                    number = number,
                    error = %error,
                    "REST patch fetch failed"
                );
            }
        }
    }

    tracing::warn!(
        target = "harness::dependency_updates::files",
        pull_request_id = pull_request_id,
        "patch_dependency_update_files surfaced empty patches (caller missing repo + number)"
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

async fn run_rest_patch(
    pull_request_id: &str,
    repo_full_name: &str,
    token: &str,
    number: u64,
    head_ref_oid: &str,
    paths: &[String],
) -> Result<DependencyUpdatesFilesPatchResponse, CliError> {
    let client = DependencyUpdatesGitHubClient::new(token)?;
    let patches =
        patch_rest::fetch_patches(client.octocrab(), repo_full_name, number, head_ref_oid, paths)
            .await
            .map_err(|error| -> CliError {
                CliErrorKind::workflow_io(format!("rest patch fetch failed: {error}")).into()
            })?;
    let fetched_at = utc_now();
    let patches = patches
        .into_iter()
        .map(|mut p| {
            if p.fetched_at.is_empty() {
                p.fetched_at = fetched_at.clone();
            }
            p
        })
        .collect();
    Ok(DependencyUpdatesFilesPatchResponse {
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
) -> Result<DependencyUpdatesFilesPatchResponse, CliError> {
    let runtime = local_clone_runtime();
    let sink = progress_sink();
    let (fetch_refs, head_ref) = local_clone_fetch_context(number, head_ref_name, base_ref_name);
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

    Ok(DependencyUpdatesFilesPatchResponse {
        pull_request_id: pull_request_id.to_string(),
        patches,
        drifted: false,
        current_head_ref_oid: head_ref_oid.to_string(),
        fetched_at: utc_now(),
        rate_limit_snapshot: None,
    })
}

fn local_clone_fetch_context(
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

/// Apply hash-guarded mark-viewed mutations across one or more paths.
///
/// Each path is hash-guarded: the daemon first refetches the file list,
/// compares the caller's `expected_prior_state` against the daemon-fresh
/// `viewer_viewed_state`, and either runs the mutation (states match) or
/// reports `Drifted` with the daemon-fresh state so the Monitor can
/// reconcile its optimistic UI.
///
/// # Errors
/// Returns `CliError` for empty payloads or when the GitHub token is
/// missing.
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

    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = DependencyUpdatesGitHubClient::new(&token)?;

    // Refetch the file list once so we have a fresh per-path viewer state
    // and can drift-check every requested target without a round-trip per
    // path.
    let current_list = client
        .fetch_pull_request_files(&DependencyUpdatesFilesListRequest {
            pull_request_id: pull_request_id.clone(),
            force_refresh: true,
        })
        .await?;
    let current_states: BTreeMap<String, DependencyUpdateFileViewedState> = current_list
        .files
        .iter()
        .map(|file| (file.path.clone(), file.viewer_viewed_state))
        .collect();

    let mut results = Vec::with_capacity(normalized.len());
    for target in normalized {
        let current = current_states
            .get(&target.path)
            .copied()
            .unwrap_or(DependencyUpdateFileViewedState::Unviewed);
        let outcome = classify_outcome(target.expected_prior_state, current)
            .unwrap_or(DependencyUpdateFileViewedOutcome::Drifted);
        if matches!(outcome, DependencyUpdateFileViewedOutcome::Drifted) {
            results.push(DependencyUpdateFilesViewedResult {
                path: target.path,
                outcome: DependencyUpdateFileViewedOutcome::Drifted,
                viewer_viewed_state: current,
            });
            continue;
        }
        match ViewedMutation::decide(current, target.mark_viewed) {
            ViewedMutation::Skip => {
                results.push(DependencyUpdateFilesViewedResult {
                    path: target.path,
                    outcome: DependencyUpdateFileViewedOutcome::Updated,
                    viewer_viewed_state: current,
                });
            }
            ViewedMutation::Mark | ViewedMutation::Unmark => {
                let next_state = if target.mark_viewed {
                    DependencyUpdateFileViewedState::Viewed
                } else {
                    DependencyUpdateFileViewedState::Unviewed
                };
                let mutation_result = client
                    .toggle_pull_request_file_viewed(
                        &pull_request_id,
                        &target.path,
                        target.mark_viewed,
                    )
                    .await;
                match mutation_result {
                    Ok(()) => results.push(DependencyUpdateFilesViewedResult {
                        path: target.path,
                        outcome: DependencyUpdateFileViewedOutcome::Updated,
                        viewer_viewed_state: next_state,
                    }),
                    Err(error) => {
                        tracing::warn!(
                            target = "harness::dependency_updates::files",
                            pull_request_id = pull_request_id,
                            path = target.path,
                            error = %error,
                            "mark_dependency_update_files_viewed mutation failed"
                        );
                        results.push(DependencyUpdateFilesViewedResult {
                            path: target.path,
                            outcome: DependencyUpdateFileViewedOutcome::Failed,
                            viewer_viewed_state: current,
                        });
                    }
                }
            }
        }
    }

    Ok(DependencyUpdatesFilesViewedResponse {
        pull_request_id,
        results,
        fetched_at: utc_now(),
    })
}

/// Fetch an image blob's bytes for inline preview.
///
/// The real REST adapter that resolves owner/repo from the node id and
/// fetches `Accept: application/vnd.github.raw` bytes is a follow-up; the
/// current implementation queries the GraphQL `text` field which covers
/// SVG and other text-encodable previews. Binary PNG/JPG/GIF bytes return
/// empty content with `is_too_large = false` and a logged warning.
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
    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = DependencyUpdatesGitHubClient::new(&token)?;
    let response = client
        .fetch_repository_blob_text(&request.repository_id, &oid)
        .await;
    let mime = crate::dependency_updates::image_mime_for_path(&request.path)
        .unwrap_or(DependencyUpdateImageMime::Png);
    match response {
        Ok(blob) => Ok(DependencyUpdatesFilesBlobResponse {
            path: request.path.clone(),
            oid,
            mime,
            content_base64: blob.content_base64,
            byte_size: blob.byte_size,
            is_truncated: blob.is_truncated,
            is_too_large: blob.is_too_large,
            fetched_at: utc_now(),
            rate_limit_snapshot: None,
        }),
        Err(error) => {
            tracing::warn!(
                target = "harness::dependency_updates::files",
                oid = oid,
                path = request.path,
                error = %error,
                "fetch_dependency_update_file_blob graphql fetch failed - returning empty body"
            );
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
    }
}

/// List the local clones the daemon is currently maintaining.
///
/// Loads `<daemon-root>/dependency_updates/clones/registry.json` and
/// projects each entry to the Settings-panel shape. Returns an empty list
/// when the registry file is absent (no clones yet).
///
/// # Errors
/// Returns `CliError` when the registry file exists but cannot be parsed.
pub async fn list_dependency_update_local_clones() -> Result<Vec<LocalCloneListEntry>, CliError> {
    let root = clones_root();
    let registry = load_registry(&root)?;
    Ok(registry
        .entries
        .iter()
        .map(|(key, entry)| LocalCloneListEntry::from_registry_entry(key, entry))
        .collect())
}

/// Delete one local clone identified by its `repo_key_segment` (the
/// "<sha-prefix>__<safe-owner>_<safe-name>" string projected by the
/// registry). Removes the bare clone directory and the registry entry.
/// Returns the post-delete listing so the Settings panel can refresh
/// without a follow-up round-trip.
///
/// # Errors
/// Returns `CliError` for empty segments or filesystem errors during
/// registry persistence.
pub async fn delete_dependency_update_local_clone(
    repo_key_segment: &str,
) -> Result<Vec<LocalCloneListEntry>, CliError> {
    let segment = repo_key_segment.trim();
    if segment.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "dependency-updates files local-clone delete: repo_key_segment must not be empty",
        )
        .into());
    }
    let root = clones_root();
    let mut registry = load_registry(&root)?;
    let matching_key = registry
        .entries
        .keys()
        .find(|key| key.safe_segment() == segment)
        .cloned();
    if let Some(key) = matching_key {
        if let Some(entry) = registry.remove(&key) {
            if entry.bare_path.exists() {
                if let Err(error) = fs::remove_dir_all(&entry.bare_path) {
                    tracing::warn!(
                        target = "harness::dependency_updates::files",
                        path = ?entry.bare_path,
                        error = %error,
                        "failed to remove local clone directory"
                    );
                }
            }
        }
        save_registry(&root, &registry)?;
    }
    Ok(registry
        .entries
        .iter()
        .map(|(key, entry)| LocalCloneListEntry::from_registry_entry(key, entry))
        .collect())
}

// MARK: - Internals

fn clones_root() -> LocalCloneRoot {
    LocalCloneRoot::new(daemon_root().join(CLONES_SUBDIR))
}

fn load_registry(root: &LocalCloneRoot) -> Result<LocalCloneRegistry, CliError> {
    let path = root.registry_path();
    if !path.exists() {
        return Ok(LocalCloneRegistry::default());
    }
    let raw = fs::read_to_string(&path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "dependency-updates clones registry read failed: {error}"
        ))
    })?;
    serde_json::from_str::<LocalCloneRegistry>(&raw).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "dependency-updates clones registry parse failed: {error}"
        ))
        .into()
    })
}

fn save_registry(root: &LocalCloneRoot, registry: &LocalCloneRegistry) -> Result<(), CliError> {
    let path = root.registry_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "dependency-updates clones registry parent create failed: {error}"
            ))
        })?;
    }
    let raw = serde_json::to_string_pretty(registry).map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "dependency-updates clones registry serialize failed: {error}"
        ))
    })?;
    fs::write(&path, raw).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "dependency-updates clones registry write failed: {error}"
        ))
        .into()
    })
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

/// Lightweight projection of one GraphQL blob fetch. Lives here (not on
/// the client) so the handler can decode both text and base64-text bodies
/// uniformly.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct BlobTextProjection {
    pub content_base64: String,
    pub byte_size: u64,
    pub is_truncated: bool,
    pub is_too_large: bool,
}

#[allow(dead_code)] // Used by the new client method below; kept here to share imports.
#[derive(Debug, Clone)]
pub(crate) struct LocalCloneRootResolver;

#[allow(dead_code)] // resolver placeholder for the local-clone shell-out follow-up
impl LocalCloneRootResolver {
    pub(crate) fn root() -> PathBuf {
        daemon_root().join(CLONES_SUBDIR)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dependency_updates::DependencyUpdateFilesViewedTarget;

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
            number: None,
            repository_full_name: None,
            base_ref_oid_expected: None,
            head_ref_name: None,
            base_ref_name: None,
            large_diff_strategy: None,
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
            number: None,
            repository_full_name: None,
            base_ref_oid_expected: None,
            head_ref_name: None,
            base_ref_name: None,
            large_diff_strategy: None,
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
    async fn local_clones_returns_empty_when_registry_missing() {
        // The daemon_root() in test mode points at a tmp dir so the registry
        // file is absent until something writes it; the handler must return
        // Ok(vec![]) rather than an error.
        let response = list_dependency_update_local_clones().await.expect("ok");
        assert!(response.is_empty());
    }

    #[test]
    fn local_clone_fetch_context_prefers_github_pull_ref() {
        let (refs, head_ref) =
            local_clone_fetch_context(Some(7), Some("renovate/foo"), Some("main"));

        assert_eq!(head_ref, "refs/harness/dependency-updates/pull/7/head");
        assert!(refs.iter().any(|r| r.remote_ref == "refs/pull/7/head"));
        assert!(refs.iter().any(|r| r.remote_ref == "refs/heads/main"));
    }

    #[test]
    fn local_clone_fetch_context_uses_branch_when_number_missing() {
        let (refs, head_ref) = local_clone_fetch_context(None, Some("renovate/foo"), None);

        assert_eq!(
            head_ref,
            "refs/harness/dependency-updates/heads/renovate/foo"
        );
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].remote_ref, "refs/heads/renovate/foo");
    }

    #[test]
    fn viewed_target_helper_constructs_normalized_payload() {
        // Sanity check that the viewed-target struct is constructible from
        // the public type re-export so the service compiles against the
        // protocol surface as well as the file-module internal one.
        let target = DependencyUpdateFilesViewedTarget {
            path: "src/lib.rs".into(),
            expected_prior_state: DependencyUpdateFileViewedState::Unviewed,
            mark_viewed: true,
        };
        assert_eq!(target.path, "src/lib.rs");
        assert!(target.mark_viewed);
    }

    #[tokio::test]
    async fn delete_local_clone_rejects_empty_segment() {
        let err = delete_dependency_update_local_clone("   ")
            .await
            .unwrap_err();
        assert!(err.to_string().to_lowercase().contains("repo_key_segment"));
    }

    #[test]
    fn clones_root_is_under_daemon_root() {
        let root = clones_root();
        assert!(
            root.registry_path()
                .to_string_lossy()
                .ends_with("dependency_updates/clones/registry.json")
        );
    }

    #[test]
    fn save_then_load_registry_round_trips() {
        let tmp = tempfile::tempdir().expect("tmpdir");
        let root = LocalCloneRoot::new(tmp.path().to_path_buf());
        let mut registry = LocalCloneRegistry::default();
        registry.insert_or_update(
            crate::dependency_updates::RepoKey::new("owner/repo"),
            crate::dependency_updates::RegistryEntry {
                repo_full_name: "owner/repo".into(),
                bare_path: tmp.path().join("owner__repo.git"),
                size_bytes: 1024,
                created_at: chrono::Utc::now(),
                last_used_at: chrono::Utc::now(),
                last_fetched_at: chrono::Utc::now(),
                last_known_head_ref_oid_by_pr: BTreeMap::new(),
            },
        );
        save_registry(&root, &registry).expect("save");
        let loaded = load_registry(&root).expect("load");
        assert_eq!(loaded.entries.len(), 1);
    }
}
