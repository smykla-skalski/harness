use async_trait::async_trait;
use chrono::SecondsFormat;
use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::TaskBoardSyncRequest;
use crate::errors::{CliError, CliErrorKind};
use crate::github_api::stable_data_revision_guard;
use crate::reviews::{ReviewItem, ReviewPullRequestState, ReviewsQueryRequest};
use crate::task_board::{
    ExternalProvider, ExternalSyncClient, ExternalSyncDirection, ExternalSyncOperation,
    ExternalSyncOptions, ExternalTask, ExternalTaskRef, TaskBoardItem, TaskBoardStatus,
    sync_external_tasks,
};

pub(super) struct SharedReviewRequestClient {
    tasks: Option<Vec<ExternalTask>>,
    query: Option<SharedReviewQuery>,
    authoritative_review_inbox: bool,
    github_revision_guard: AsyncMutex<Option<OwnedMutexGuard<()>>>,
}

struct SharedReviewQuery {
    request: ReviewsQueryRequest,
    repositories: Vec<String>,
    labels: Vec<String>,
}

#[async_trait]
impl ExternalSyncClient for SharedReviewRequestClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn allows_push(&self) -> bool {
        false
    }

    fn authoritative_review_inbox(&self) -> bool {
        self.authoritative_review_inbox
    }

    async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
        if let Some(tasks) = &self.tasks {
            return Ok(tasks.clone());
        }
        let query = self
            .query
            .as_ref()
            .expect("shared Reviews client has tasks or a query");
        let source = super::super::reviews::query_reviews_source(&query.request).await?;
        let revision_guard = stable_data_revision_guard(source.github_data_revision)
            .await
            .ok_or_else(|| {
                CliError::from(CliErrorKind::concurrent_modification(
                    "GitHub data changed before Task Board could reconcile the Reviews snapshot",
                ))
            })?;
        let tasks =
            review_external_tasks(&query.repositories, &query.labels, &source.response.items);
        *self.github_revision_guard.lock().await = Some(revision_guard);
        Ok(tasks)
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Err(CliErrorKind::workflow_io("shared Reviews source is pull-only").into())
    }
}

pub(super) async fn shared_review_request_client(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
) -> Result<Option<SharedReviewRequestClient>, CliError> {
    if !matches!(
        request.direction,
        ExternalSyncDirection::Pull | ExternalSyncDirection::Both
    ) || request
        .provider
        .is_some_and(|provider| provider != ExternalProvider::GitHub)
    {
        return Ok(None);
    }
    let settings = db.task_board_orchestrator_settings().await?;
    if settings.github_inbox.repositories.is_empty() {
        return Ok(None);
    }
    Ok(Some(SharedReviewRequestClient {
        tasks: None,
        query: Some(SharedReviewQuery {
            request: ReviewsQueryRequest {
                repositories: settings.github_inbox.repositories.clone(),
                ..ReviewsQueryRequest::default()
            },
            repositories: settings.github_inbox.repositories,
            labels: settings.github_inbox.label_filter,
        }),
        authoritative_review_inbox: true,
        github_revision_guard: AsyncMutex::new(None),
    }))
}

pub(crate) async fn reconcile_shared_review_items_db(
    db: &AsyncDaemonDb,
    items: &[ReviewItem],
) -> Result<Vec<ExternalSyncOperation>, CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    let Some(client) = shared_review_request_client_from_settings(
        &settings.github_inbox.repositories,
        &settings.github_inbox.label_filter,
        items,
        false,
    ) else {
        return Ok(Vec::new());
    };
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];
    sync_external_tasks(
        db,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            dry_run: false,
            ..ExternalSyncOptions::default()
        },
        &clients,
    )
    .await
}

fn shared_review_request_client_from_settings(
    repositories: &[String],
    labels: &[String],
    items: &[ReviewItem],
    authoritative_review_inbox: bool,
) -> Option<SharedReviewRequestClient> {
    if repositories.is_empty() {
        return None;
    }
    let tasks = review_external_tasks(repositories, labels, items);
    Some(SharedReviewRequestClient {
        tasks: Some(tasks),
        query: None,
        authoritative_review_inbox,
        github_revision_guard: AsyncMutex::new(None),
    })
}

fn review_external_tasks(
    repositories: &[String],
    labels: &[String],
    items: &[ReviewItem],
) -> Vec<ExternalTask> {
    items
        .iter()
        .filter(|item| shared_review_matches(item, repositories, labels))
        .map(review_external_task)
        .collect()
}

fn shared_review_matches(item: &ReviewItem, repositories: &[String], labels: &[String]) -> bool {
    item.state == ReviewPullRequestState::Open
        && item.flags.viewer_is_requested_reviewer
        && repositories
            .iter()
            .any(|repository| repository.trim().eq_ignore_ascii_case(&item.repository))
        && (labels.is_empty()
            || item.labels.iter().any(|label| {
                labels
                    .iter()
                    .any(|expected| label.eq_ignore_ascii_case(expected.trim()))
            }))
}

fn review_external_task(item: &ReviewItem) -> ExternalTask {
    ExternalTask {
        reference: ExternalTaskRef::new(
            ExternalProvider::GitHub,
            format!("{}#{}", item.repository, item.number),
        )
        .with_url(item.url.clone()),
        title: item.title.clone(),
        body: String::new(),
        status: TaskBoardStatus::HumanRequired,
        project_id: Some(item.repository.clone()),
        updated_at: Some(item.updated_at.to_rfc3339_opts(SecondsFormat::Secs, true)),
    }
}
