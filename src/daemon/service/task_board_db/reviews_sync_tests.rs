use chrono::{TimeZone, Utc};
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::reviews::{
    ReviewAuthorAssociation, ReviewCheckStatus, ReviewItem, ReviewItemFlags, ReviewMergeableState,
    ReviewPullRequestState, ReviewReviewStatus,
};
use crate::task_board::external::{
    ExternalProviderScopeAttemptDecision, ExternalProviderScopeIdentity,
};
use crate::task_board::{
    ExternalProvider, TaskBoardGitHubInboxConfig, TaskBoardOrchestratorSettings,
};
use crate::task_board::{ExternalSyncClient, TaskBoardItem};
use crate::workspace::utc_now;

use super::{reconcile_shared_review_items_db, shared_review_request_clients_from_settings};

#[test]
fn shared_review_clients_split_scope_and_ownership_by_repository() {
    let repositories = vec!["Acme/Widgets".into(), "acme/tools".into()];
    let clients = shared_review_request_clients_from_settings(&repositories, &[], &[], false);
    let scope_ids = clients
        .iter()
        .map(ExternalSyncClient::scope_id)
        .collect::<Vec<_>>();
    let persistence_scope_ids = clients
        .iter()
        .map(|client| {
            ExternalProviderScopeIdentity::for_client(client)
                .scope_id()
                .to_owned()
        })
        .collect::<Vec<_>>();

    assert_eq!(scope_ids, ["acme/widgets", "acme/tools"]);
    assert_eq!(
        persistence_scope_ids,
        [
            "v1:github:read:12:acme/widgets",
            "v1:github:read:10:acme/tools",
        ]
    );

    let mut item = TaskBoardItem::new(
        "task-review".into(),
        "Review".into(),
        String::new(),
        "2026-07-16T10:00:00Z".into(),
    );
    item.execution_repository = Some("ACME/WIDGETS".into());
    assert_eq!(clients[0].scope_for_item(&item), "acme/widgets");
    assert_eq!(clients[1].scope_for_item(&item), "acme/widgets");
    assert_eq!(clients[0].scope_id(), clients[0].scope_for_item(&item));
    assert_ne!(clients[1].scope_id(), clients[1].scope_for_item(&item));
}

#[tokio::test]
async fn backed_off_review_repository_does_not_block_another_repository() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let repositories = vec!["acme/broken".into(), "acme/widgets".into()];
    db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings {
        github_inbox: TaskBoardGitHubInboxConfig {
            repositories: repositories.clone(),
            label_filter: Vec::new(),
        },
        ..TaskBoardOrchestratorSettings::default()
    })
    .await
    .expect("configure review inbox");
    let clients = shared_review_request_clients_from_settings(&repositories, &[], &[], false);
    let broken_scope = ExternalProviderScopeIdentity::for_client(&clients[0])
        .scope_id()
        .to_owned();
    let now = utc_now();
    let attempt = match db
        .begin_task_board_provider_scope_attempt(ExternalProvider::GitHub, &broken_scope, &now)
        .await
        .expect("begin failed repository attempt")
    {
        ExternalProviderScopeAttemptDecision::Started(attempt) => attempt,
        other => panic!("expected started attempt, got {other:?}"),
    };
    db.complete_task_board_provider_scope_failure(&attempt, &now)
        .await
        .expect("back off failed repository");

    let items = vec![
        review_item("acme/broken", 17),
        review_item("acme/widgets", 18),
    ];
    let (_, operations) = reconcile_shared_review_items_db(&db, &items)
        .await
        .expect("reconcile available repository");
    let board_items = db.list_task_board_items(None).await.expect("board items");

    assert_eq!(operations.len(), 1);
    assert_eq!(board_items.len(), 1);
    assert_eq!(
        board_items[0].execution_repository.as_deref(),
        Some("acme/widgets")
    );
}

fn review_item(repository: &str, number: u64) -> ReviewItem {
    ReviewItem {
        pull_request_id: format!("pr-{repository}-{number}"),
        repository_id: format!("repo-{repository}"),
        repository: repository.into(),
        number,
        title: format!("Review {repository}#{number}"),
        url: format!("https://github.com/{repository}/pull/{number}"),
        base_ref_name: None,
        default_branch_name: None,
        backport_source: None,
        author_login: "author".into(),
        author_avatar_url: None,
        author_association: ReviewAuthorAssociation::Member,
        state: ReviewPullRequestState::Open,
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::ReviewRequired,
        check_status: ReviewCheckStatus::Success,
        flags: ReviewItemFlags {
            policy_blocked: false,
            is_draft: false,
            viewer_can_update: true,
            viewer_is_requested_reviewer: true,
        },
        viewer_can_merge_as_admin: false,
        head_sha: format!("head-{number}"),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews: Vec::new(),
        additions: 1,
        deletions: 1,
        created_at: Utc
            .with_ymd_and_hms(2026, 7, 16, 10, 0, 0)
            .single()
            .expect("created at"),
        updated_at: Utc
            .with_ymd_and_hms(2026, 7, 16, 10, 5, 0)
            .single()
            .expect("updated at"),
        required_failed_check_names: Vec::new(),
        required_approving_review_count: None,
        has_conflict_markers: None,
        viewer_has_active_approval: None,
        auto_merge_enabled: None,
        approval_requirement_satisfied_after_viewer_approval: None,
    }
}
