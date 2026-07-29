use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::task_board::run_task_board_sync_blocking_with_config;
use crate::daemon::protocol::TaskBoardSyncRequest;
use crate::task_board::{ExternalProvider, ExternalSyncConfig, ExternalSyncDirection};

#[test]
fn github_pull_with_token_but_no_repository_reports_configuration_error() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let config = ExternalSyncConfig::default().with_github_token_override(Some("github-token"));
        let request = TaskBoardSyncRequest {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            ..TaskBoardSyncRequest::default()
        };

        let error =
            run_task_board_sync_blocking_with_config(&request, config).expect_err("sync error");

        assert!(
            error
                .to_string()
                .contains("GitHub pull sync requires a configured repository")
        );
    });
}
