//! Obtain (clone-or-reuse) a task-board working copy.

use harness_kernel::errors::{CliError, CliErrorKind};
use crate::task_board::external::ExternalProvider;
use crate::task_board::runtime_config::normalize_repository_slug;
use crate::task_board::working_copy::{WorkingCopyKey, WorkingCopyListEntry};

use super::super::task_board_runtime::external_sync_config_for_repository;
use super::{progress_sink, store, working_copy_runtime};

/// Obtain a working copy for `repository`. When `allow_clone` is false a
/// missing copy yields `Ok(None)` (delivery must not trigger a surprise
/// clone); when true a missing copy is cloned. A present copy is reused and
/// its `last_used_at` bumped. Returns the registry projection (carrying the
/// checkout `path`) on success.
///
/// # Errors
/// Returns `CliError` for an empty/invalid slug, a missing GitHub token when a
/// clone is required, or clone/registry failures.
pub async fn obtain_task_board_working_copy(
    repository: &str,
    allow_clone: bool,
) -> Result<Option<WorkingCopyListEntry>, CliError> {
    let Some(repository) = normalize_repository_slug(Some(repository)) else {
        return Err(CliErrorKind::workflow_parse(
            "task-board working-copy obtain: repository must be an owner/name slug",
        )
        .into());
    };

    let token = github_token_for_repository(&repository);
    if allow_clone && token.is_none() {
        return Err(CliErrorKind::workflow_io(format!(
            "task-board working-copy obtain: no GitHub token available for {repository}; sync a token from the Monitor first"
        ))
        .into());
    }

    let runtime = working_copy_runtime();
    let sink = progress_sink();
    let obtained = runtime
        .obtain(&repository, token.as_deref().unwrap_or(""), allow_clone, sink)
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("task-board working-copy obtain failed: {error}"))
        })?;

    if obtained.is_none() {
        return Ok(None);
    }
    // The runtime already persisted the registry row; re-read the projection
    // so the caller sees the freshest path/size/timestamps.
    let segment = WorkingCopyKey::new(&repository).safe_segment();
    let entry = store::list_task_board_working_copies()
        .await?
        .into_iter()
        .find(|entry| entry.repo_key_segment == segment);
    Ok(entry)
}

fn github_token_for_repository(repository: &str) -> Option<String> {
    external_sync_config_for_repository(Some(repository), &[])
        .token_for(ExternalProvider::GitHub)
        .map(str::to_owned)
}
