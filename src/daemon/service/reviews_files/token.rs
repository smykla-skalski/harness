//! GitHub-token resolution for reviews-files endpoints.

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::ExternalProvider;

use super::super::task_board_runtime::external_sync_config_for_repository;

pub(super) fn github_token(repository: Option<&str>) -> Option<String> {
    external_sync_config_for_repository(repository, &[])
        .token_for(ExternalProvider::GitHub)
        .map(ToString::to_string)
}

pub(super) fn missing_token_error(repository: Option<&str>) -> CliError {
    match repository {
        Some(repository) => CliErrorKind::workflow_io(format!(
            "reviews files requires a GitHub token for '{repository}'. \
             Configure one in Settings > Secrets."
        ))
        .into(),
        None => CliErrorKind::workflow_io(
            "reviews files requires a GitHub token. \
             Configure one in Settings > Secrets.",
        )
        .into(),
    }
}
