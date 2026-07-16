use std::collections::HashSet;
use std::sync::Arc;

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
    normalize_repository_slug, sync_external_tasks,
};

pub(super) struct SharedReviewRequestClient {
    repository: String,
    tasks: Option<Vec<ExternalTask>>,
    query: Option<SharedReviewQuery>,
    authoritative_review_inbox: bool,
    github_revision_guard: SharedGitHubRevisionGuard,
}

struct SharedReviewQuery {
    request: ReviewsQueryRequest,
    labels: Vec<String>,
}

type SharedGitHubRevisionGuard = Arc<AsyncMutex<Option<HeldGitHubRevisionGuard>>>;

struct HeldGitHubRevisionGuard {
    revision: u64,
    _guard: OwnedMutexGuard<()>,
}

#[async_trait]
impl ExternalSyncClient for SharedReviewRequestClient {
    fn provider(&self) -> ExternalProvider {
        ExternalProvider::GitHub
    }

    fn scope_id(&self) -> String {
        self.repository.clone()
    }

    fn scope_for_item(&self, item: &TaskBoardItem) -> String {
        normalize_repository_slug(
            item.execution_repository
                .as_deref()
                .or(item.project_id.as_deref()),
        )
        .unwrap_or_else(|| self.scope_id())
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
        let source =
            super::super::reviews::query_reviews_repositories_source(&query.request).await?;
        self.hold_github_revision(source.github_data_revision)
            .await?;
        let tasks = review_external_tasks(
            std::slice::from_ref(&self.repository),
            &query.labels,
            &source.response.items,
        );
        Ok(tasks)
    }

    async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
        Err(CliErrorKind::workflow_io("shared Reviews source is pull-only").into())
    }
}

impl SharedReviewRequestClient {
    async fn hold_github_revision(&self, revision: u64) -> Result<(), CliError> {
        let mut held = self.github_revision_guard.lock().await;
        if let Some(current) = held.as_ref() {
            if current.revision == revision {
                return Ok(());
            }
            return Err(github_revision_changed_error());
        }
        let guard = stable_data_revision_guard(revision)
            .await
            .ok_or_else(github_revision_changed_error)?;
        *held = Some(HeldGitHubRevisionGuard {
            revision,
            _guard: guard,
        });
        Ok(())
    }
}

pub(super) async fn shared_review_request_clients(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
) -> Result<Vec<SharedReviewRequestClient>, CliError> {
    if !matches!(
        request.direction,
        ExternalSyncDirection::Pull | ExternalSyncDirection::Both
    ) || request
        .provider
        .is_some_and(|provider| provider != ExternalProvider::GitHub)
    {
        return Ok(Vec::new());
    }
    let settings = db.task_board_orchestrator_settings().await?;
    if settings.github_inbox.repositories.is_empty() {
        return Ok(Vec::new());
    }
    Ok(shared_review_query_clients(
        &settings.github_inbox.repositories,
        &settings.github_inbox.label_filter,
    ))
}

pub(crate) async fn reconcile_shared_review_items_db(
    db: &AsyncDaemonDb,
    items: &[ReviewItem],
) -> Result<(HashSet<String>, Vec<ExternalSyncOperation>), CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    let configured_keys = items
        .iter()
        .filter(|item| {
            shared_review_inbox_eligible(
                item,
                &settings.github_inbox.repositories,
                &settings.github_inbox.label_filter,
            )
        })
        .map(review_key)
        .collect::<HashSet<_>>();
    let clients = shared_review_request_clients_from_settings(
        &settings.github_inbox.repositories,
        &settings.github_inbox.label_filter,
        items,
        false,
    );
    if clients.is_empty() {
        return Ok((configured_keys, Vec::new()));
    }
    let clients = boxed_review_clients(clients);
    let operations = sync_external_tasks(
        db,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::GitHub),
            direction: ExternalSyncDirection::Pull,
            dry_run: false,
            ..ExternalSyncOptions::default()
        },
        &clients,
    )
    .await?;
    Ok((configured_keys, operations))
}

fn shared_review_request_clients_from_settings(
    repositories: &[String],
    labels: &[String],
    items: &[ReviewItem],
    authoritative_review_inbox: bool,
) -> Vec<SharedReviewRequestClient> {
    normalized_repositories(repositories)
        .into_iter()
        .map(|repository| SharedReviewRequestClient {
            tasks: Some(review_external_tasks(
                std::slice::from_ref(&repository),
                labels,
                items,
            )),
            query: None,
            repository,
            authoritative_review_inbox,
            github_revision_guard: Arc::new(AsyncMutex::new(None)),
        })
        .collect()
}

fn shared_review_query_clients(
    repositories: &[String],
    labels: &[String],
) -> Vec<SharedReviewRequestClient> {
    let github_revision_guard = Arc::new(AsyncMutex::new(None));
    normalized_repositories(repositories)
        .into_iter()
        .map(|repository| SharedReviewRequestClient {
            tasks: None,
            query: Some(SharedReviewQuery {
                request: ReviewsQueryRequest {
                    repositories: vec![repository.clone()],
                    ..ReviewsQueryRequest::default()
                },
                labels: labels.to_vec(),
            }),
            repository,
            authoritative_review_inbox: true,
            github_revision_guard: Arc::clone(&github_revision_guard),
        })
        .collect()
}

fn boxed_review_clients(
    clients: Vec<SharedReviewRequestClient>,
) -> Vec<Box<dyn ExternalSyncClient>> {
    clients
        .into_iter()
        .map(|client| Box::new(client) as Box<dyn ExternalSyncClient>)
        .collect()
}

fn normalized_repositories(repositories: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    repositories
        .iter()
        .filter_map(|repository| normalize_repository_slug(Some(repository.as_str())))
        .filter(|repository| seen.insert(repository.clone()))
        .collect()
}

fn github_revision_changed_error() -> CliError {
    CliErrorKind::concurrent_modification(
        "GitHub data changed before Task Board could reconcile the Reviews snapshot",
    )
    .into()
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
        && shared_review_inbox_eligible(item, repositories, labels)
}

fn shared_review_inbox_eligible(
    item: &ReviewItem,
    repositories: &[String],
    labels: &[String],
) -> bool {
    repositories
        .iter()
        .any(|repository| repository.trim().eq_ignore_ascii_case(&item.repository))
        && (labels.is_empty()
            || item.labels.iter().any(|label| {
                labels
                    .iter()
                    .any(|expected| label.eq_ignore_ascii_case(expected.trim()))
            }))
}

fn review_key(item: &ReviewItem) -> String {
    format!(
        "{}#{}",
        item.repository.trim().to_ascii_lowercase(),
        item.number
    )
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
        status: TaskBoardStatus::Backlog,
        project_id: Some(item.repository.clone()),
        updated_at: Some(item.updated_at.to_rfc3339_opts(SecondsFormat::Secs, true)),
    }
}

#[cfg(test)]
#[path = "reviews_sync_tests.rs"]
mod tests;
