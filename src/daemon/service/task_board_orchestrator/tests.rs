use std::path::PathBuf;

use temp_env::with_vars;
use tempfile::tempdir;

use super::*;
use crate::task_board::{
    ExternalSyncAction, ExternalSyncOperation, GH_TOKEN_ENV, GITHUB_REPOSITORY_ENV,
    HARNESS_GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_TOKEN_ENV, HARNESS_TODOIST_TOKEN_ENV,
    TaskBoardGitHubProjectConfig, TaskBoardItem, TaskBoardStore, TaskBoardSyncSummary,
    TaskBoardWorkflowStatus,
};

#[test]
fn sync_github_tasks_uses_settings_repository_fallback_before_dispatch() {
    let temp = tempdir().expect("tempdir");
    with_vars(
        [
            (HARNESS_GITHUB_TOKEN_ENV, Some(" token ")),
            (GH_TOKEN_ENV, None::<&str>),
            (HARNESS_GITHUB_REPOSITORY_ENV, None::<&str>),
            (GITHUB_REPOSITORY_ENV, None::<&str>),
            (HARNESS_TODOIST_TOKEN_ENV, None::<&str>),
        ],
        || {
            let root = temp.path().join("board");
            let board = TaskBoardStore::new(root.clone());
            let mut item = TaskBoardItem::new(
                "task-1".to_string(),
                "Synced task".to_string(),
                String::new(),
                "2026-05-14T00:00:00Z".to_string(),
            );
            item.status = TaskBoardStatus::Todo;
            item.workflow.status = TaskBoardWorkflowStatus::Idle;
            board.create("Synced task", "", item).expect("create item");

            let orchestrator = TaskBoardOrchestrator::new(root);
            orchestrator
                .update_settings(&TaskBoardOrchestratorSettingsUpdateRequest {
                    github_project: Some(TaskBoardGitHubProjectConfig::new(
                        "owner",
                        "sync-fallback-repo",
                        PathBuf::new(),
                    )),
                    ..TaskBoardOrchestratorSettingsUpdateRequest::default()
                })
                .expect("update settings");
            let mut prepared = orchestrator
                .prepare_run(&TaskBoardOrchestratorRunOnceRequest::default())
                .expect("prepare run");

            let mut captured_request = None;
            let mut captured_config = None;
            sync_github_tasks_with_runner(&orchestrator, &mut prepared, |request, config| {
                captured_request = Some(request.clone());
                captured_config = Some(config);
                Ok(TaskBoardSyncSummary {
                    total: 1,
                    providers: Vec::new(),
                    operations: vec![ExternalSyncOperation {
                        provider: ExternalProvider::GitHub,
                        action: ExternalSyncAction::Pull,
                        board_item_id: Some("github-7".to_string()),
                        external_id: Some("7".to_string()),
                        url: None,
                        dry_run: true,
                        applied: false,
                        changed_fields: Vec::new(),
                        unsupported_fields: Vec::new(),
                    }],
                })
            })
            .expect("sync github tasks");

            let request = captured_request.expect("captured request");
            let config = captured_config.expect("captured config");
            assert_eq!(request.provider, Some(ExternalProvider::GitHub));
            assert_eq!(request.direction, ExternalSyncDirection::Pull);
            assert_eq!(request.status, Some(TaskBoardStatus::Todo));
            assert!(request.dry_run);
            assert_eq!(config.token_for(ExternalProvider::GitHub), Some("token"));
            assert_eq!(config.github_repository(), Some("owner/sync-fallback-repo"));
            assert_eq!(prepared.sync.operations.len(), 1);
            assert_eq!(prepared.audit.total, 1);
        },
    );
}

#[test]
fn sync_github_tasks_skips_item_scoped_runs() {
    let temp = tempdir().expect("tempdir");
    with_vars(
        [
            (HARNESS_GITHUB_TOKEN_ENV, Some("token")),
            (GH_TOKEN_ENV, None::<&str>),
            (HARNESS_GITHUB_REPOSITORY_ENV, Some("owner/repo")),
            (GITHUB_REPOSITORY_ENV, None::<&str>),
            (HARNESS_TODOIST_TOKEN_ENV, None::<&str>),
        ],
        || {
            let root = temp.path().join("board");
            let board = TaskBoardStore::new(root.clone());
            let mut item = TaskBoardItem::new(
                "task-1".to_string(),
                "Scoped task".to_string(),
                String::new(),
                "2026-05-14T00:00:00Z".to_string(),
            );
            item.status = TaskBoardStatus::Todo;
            board.create("Scoped task", "", item).expect("create item");

            let orchestrator = TaskBoardOrchestrator::new(root);
            let mut prepared = orchestrator
                .prepare_run(&TaskBoardOrchestratorRunOnceRequest {
                    item_id: Some("task-1".to_string()),
                    ..TaskBoardOrchestratorRunOnceRequest::default()
                })
                .expect("prepare scoped run");
            let mut invoked = false;
            sync_github_tasks_with_runner(&orchestrator, &mut prepared, |_, _| {
                invoked = true;
                Ok(TaskBoardSyncSummary {
                    total: 0,
                    providers: Vec::new(),
                    operations: Vec::new(),
                })
            })
            .expect("skip scoped sync");

            assert!(!invoked);
            assert!(prepared.sync.operations.is_empty());
        },
    );
}
