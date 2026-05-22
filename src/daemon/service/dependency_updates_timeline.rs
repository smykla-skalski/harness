use std::time::Instant;

use crate::daemon::service::task_board_runtime::external_sync_config_for_repository;
use crate::dependency_updates::timeline::{
    self, DependencyUpdatesTimelineRequest, DependencyUpdatesTimelineResponse, TimelineError,
    TimelineGitHubClient,
};
use crate::dependency_updates::DependencyUpdatesCacheClearResponse;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::ExternalProvider;

use super::dependency_updates as base_service;

/// Service-level entry point for the `/v1/dependency-updates/timeline`
/// HTTP route and the matching `dependency_updates.timeline` WS
/// method. Resolves the GitHub token, constructs a production
/// `TimelineClient`, and hands off to
/// [`timeline::fetch_timeline_page`] which enforces the full-drain
/// pagination contract from the plan §2.6.
///
/// # Errors
/// Returns `CliError` when the GitHub token is missing, the GraphQL
/// transport fails, or the upstream API rate-limits the caller.
pub async fn fetch_dependency_update_timeline(
    request: &DependencyUpdatesTimelineRequest,
) -> Result<DependencyUpdatesTimelineResponse, CliError> {
    let token = github_token().ok_or_else(missing_token_error)?;
    let client = TimelineGitHubClient::new(&token)?;
    timeline::fetch_timeline_page(request.clone(), &client, Instant::now())
        .await
        .map_err(timeline_error_to_cli)
}

/// Combined cache-clear: drains the existing list + body caches via
/// the established service fn, then drains the timeline cache so a
/// single DELETE flushes every server-side dependency-updates state.
///
/// # Errors
/// Propagates errors from
/// [`base_service::clear_dependency_updates_cache`] verbatim.
pub fn clear_dependency_updates_caches_with_timeline(
) -> Result<DependencyUpdatesCacheClearResponse, CliError> {
    let mut response = base_service::clear_dependency_updates_cache()?;
    response.cleared_entries += timeline::drain_timeline_cache();
    Ok(response)
}

fn github_token() -> Option<String> {
    external_sync_config_for_repository(None, &[])
        .token_for(ExternalProvider::GitHub)
        .map(ToString::to_string)
}

fn missing_token_error() -> CliError {
    CliErrorKind::workflow_io(
        "dependency-updates timeline requires a GitHub token. Configure one in Settings > Secrets.",
    )
    .into()
}

fn timeline_error_to_cli(err: TimelineError) -> CliError {
    match err {
        TimelineError::Client(msg) => {
            CliErrorKind::workflow_io(format!("timeline upstream: {msg}")).into()
        }
        TimelineError::RateLimited => {
            CliErrorKind::workflow_io("timeline upstream: rate limit reached").into()
        }
        TimelineError::Mapping(msg) => {
            CliErrorKind::workflow_io(format!("timeline mapping: {msg}")).into()
        }
    }
}
