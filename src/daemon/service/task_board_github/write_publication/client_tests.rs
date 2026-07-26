use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::*;
use crate::daemon::service::sync_task_board_github_tokens;
use crate::task_board::TaskBoardGitHubTokensSyncRequest;
use crate::task_board::github::GitHubAutomation;

async fn database(root: &std::path::Path) -> AsyncDaemonDb {
    AsyncDaemonDb::connect(&root.join("harness.db"))
        .await
        .expect("database")
}

fn seed_tokens(repositories: &[&str]) {
    sync_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest {
        global_token: Some("global-token".into()),
        repository_tokens: repositories
            .iter()
            .map(
                |repository| crate::task_board::TaskBoardGitHubRepositoryToken {
                    repository: (*repository).into(),
                    token: format!("token-for-{repository}"),
                },
            )
            .collect(),
    })
    .expect("seed tokens");
}

#[test]
fn each_repository_gets_its_own_publication_target() {
    let temp = tempdir().expect("tempdir");
    with_isolated_harness_env(temp.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db = database(temp.path()).await;
            let repositories = ["example/compass", "another-owner/atlas"];
            seed_tokens(&repositories);
            let settings = TaskBoardOrchestratorSettings::default();

            for repository in repositories {
                let publication = publication_client_for_repository(
                    &db,
                    &settings,
                    TaskBoardWorkflowKind::DefaultTask,
                    Some(repository),
                )
                .await
                .expect("publication client");

                assert_eq!(publication.repository, repository);
                assert_eq!(publication.config.repository_slug(), repository);
            }
        });
    });
}

#[test]
fn publication_target_is_normalized_before_use() {
    let temp = tempdir().expect("tempdir");
    with_isolated_harness_env(temp.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db = database(temp.path()).await;
            seed_tokens(&["example/mixed-case"]);

            let publication = publication_client_for_repository(
                &db,
                &TaskBoardOrchestratorSettings::default(),
                TaskBoardWorkflowKind::DefaultTask,
                Some("Example/Mixed-Case"),
            )
            .await
            .expect("publication client");

            assert_eq!(publication.repository, "example/mixed-case");
        });
    });
}

#[test]
fn a_malformed_repository_is_refused() {
    let temp = tempdir().expect("tempdir");
    with_isolated_harness_env(temp.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db = database(temp.path()).await;
            seed_tokens(&[]);

            let Err(error) = publication_client_for_repository(
                &db,
                &TaskBoardOrchestratorSettings::default(),
                TaskBoardWorkflowKind::DefaultTask,
                Some("not-a-slug"),
            )
            .await
            else {
                panic!("a malformed repository must not publish");
            };

            assert!(
                error
                    .to_string()
                    .contains("is not an owner/repo repository"),
                "unexpected error: {error}"
            );
        });
    });
}

#[test]
fn disabled_automations_refuse_every_repository() {
    let temp = tempdir().expect("tempdir");
    with_isolated_harness_env(temp.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db = database(temp.path()).await;
            seed_tokens(&["example/compass"]);
            let mut settings = TaskBoardOrchestratorSettings::default();
            settings.github_project.enabled_automations.enabled =
                vec![GitHubAutomation::WatchChecks];

            let Err(error) = publication_client_for_repository(
                &db,
                &settings,
                TaskBoardWorkflowKind::DefaultTask,
                Some("example/compass"),
            )
            .await
            else {
                panic!("publication without CreateBranch must be refused");
            };

            assert!(
                error
                    .to_string()
                    .contains("requires CreateBranch automation"),
                "unexpected error: {error}"
            );
        });
    });
}
