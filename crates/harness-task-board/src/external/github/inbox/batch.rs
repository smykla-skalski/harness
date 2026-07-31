use std::collections::HashMap;

use futures_util::future::try_join_all;
use tokio::sync::OnceCell;

use crate::external::ExternalTask;
use harness_github_api::GitHubProtectedClient;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::super::graphql::GitHubBatchSearchResult;
use super::super::graphql::{GitHubSearchIssuePullRequestItem, search_issue_pull_requests_batch};
use super::super::{DEPENDENCY_BOT_AUTHORS, GitHubRepository, warn_github_message};
use super::mapping;

const MAX_ALIASED_SEARCHES_PER_REQUEST: usize = 5;

pub(super) struct InboxBatch {
    client: GitHubProtectedClient,
    repositories: Vec<GitHubRepository>,
    import_labels: Vec<String>,
    fresh: bool,
    include_review_requests: bool,
    outcome: OnceCell<InboxBatchOutcome>,
}

impl InboxBatch {
    pub(super) fn new(
        client: GitHubProtectedClient,
        repositories: Vec<GitHubRepository>,
        import_labels: Vec<String>,
        fresh: bool,
        include_review_requests: bool,
    ) -> Self {
        Self {
            client,
            repositories,
            import_labels,
            fresh,
            include_review_requests,
            outcome: OnceCell::new(),
        }
    }

    pub(super) async fn pull_repository(
        &self,
        repository: &GitHubRepository,
    ) -> Result<(Vec<ExternalTask>, bool), CliError> {
        let outcome = self
            .outcome
            .get_or_init(|| async {
                match self.fetch().await {
                    Ok(results) => InboxBatchOutcome::Ready(results),
                    Err(error) => InboxBatchOutcome::Failed(SharedFailure::from_error(&error)),
                }
            })
            .await;
        match outcome {
            InboxBatchOutcome::Failed(error) => Err(error.to_error()),
            InboxBatchOutcome::Ready(results) => {
                let slug = repository.slug().to_ascii_lowercase();
                let result = results.get(&slug).ok_or_else(|| {
                    CliErrorKind::workflow_io(format!(
                        "github inbox batch omitted configured repository {}",
                        repository.slug()
                    ))
                })?;
                for failure in &result.failures {
                    warn_github_message(&format!("skipping GitHub inbox repository {failure}"));
                }
                if !result.assigned_succeeded {
                    return Err(all_searches_failed(&result.failures));
                }
                Ok((result.tasks.clone(), result.failures.is_empty()))
            }
        }
    }

    async fn fetch(&self) -> Result<HashMap<String, RepositoryResult>, CliError> {
        let (slots, queries, contexts) = self.batch_inputs();
        let batch_size = if self.include_review_requests {
            MAX_ALIASED_SEARCHES_PER_REQUEST
        } else {
            MAX_ALIASED_SEARCHES_PER_REQUEST - 1
        };
        let batches = try_join_all(
            slots
                .chunks(batch_size)
                .zip(queries.chunks(batch_size))
                .zip(contexts.chunks(batch_size))
                .map(|((slots, queries), contexts)| async move {
                    let results = search_issue_pull_requests_batch(
                        &self.client,
                        queries,
                        contexts,
                        self.fresh,
                    )
                    .await?;
                    Ok::<_, CliError>((slots, results))
                }),
        )
        .await?;
        let mut repositories = self
            .repositories
            .iter()
            .map(|repository| {
                (
                    repository.slug().to_ascii_lowercase(),
                    RepositoryAccumulator::new(),
                )
            })
            .collect::<HashMap<_, _>>();
        for (slots, results) in batches {
            for (slot, result) in slots.iter().zip(results) {
                record_result(&mut repositories, slot, result);
            }
        }
        Ok(self.finish_repositories(&repositories))
    }

    fn batch_inputs(&self) -> (Vec<QuerySlot>, Vec<String>, Vec<String>) {
        let mut slots = Vec::new();
        let mut queries = Vec::new();
        let mut contexts = Vec::new();
        for scope in repository_scopes(&self.repositories) {
            let repository_qualifier = scope
                .repositories
                .iter()
                .map(|repository| format!("repo:{repository}"))
                .collect::<Vec<_>>()
                .join(" ");
            push_query(
                &mut slots,
                &mut queries,
                &mut contexts,
                &scope.repositories,
                QueryKind::Assigned,
                format!(
                    "{repository_qualifier} is:issue assignee:@me state:open state:closed \
sort:updated-desc"
                ),
                "assigned issue search",
            );
            if self.include_review_requests {
                push_query(
                    &mut slots,
                    &mut queries,
                    &mut contexts,
                    &scope.repositories,
                    QueryKind::Review,
                    format!(
                        "{repository_qualifier} is:pr review-requested:@me state:open \
sort:updated-desc"
                    ),
                    "review request search",
                );
            }
            for author in DEPENDENCY_BOT_AUTHORS {
                push_query(
                    &mut slots,
                    &mut queries,
                    &mut contexts,
                    &scope.repositories,
                    QueryKind::Dependency,
                    format!(
                        "{repository_qualifier} is:pr is:open author:{author} sort:updated-desc"
                    ),
                    "dependency author search",
                );
            }
            push_query(
                &mut slots,
                &mut queries,
                &mut contexts,
                &scope.repositories,
                QueryKind::Dependency,
                format!(
                    "{repository_qualifier} is:pr is:open label:dependencies sort:updated-desc"
                ),
                "dependency label search",
            );
        }
        (slots, queries, contexts)
    }

    fn finish_repositories(
        &self,
        accumulators: &HashMap<String, RepositoryAccumulator>,
    ) -> HashMap<String, RepositoryResult> {
        self.repositories
            .iter()
            .map(|repository| {
                let slug = repository.slug().to_ascii_lowercase();
                let accumulator = accumulators
                    .get(&slug)
                    .expect("configured repository has a batch accumulator");
                let mut tasks = mapping::assigned_issue_tasks(
                    repository,
                    &self.import_labels,
                    accumulator.assigned.clone(),
                    true,
                );
                tasks.extend(mapping::review_request_tasks(
                    repository,
                    &self.import_labels,
                    accumulator.reviews.clone(),
                    true,
                ));
                tasks.extend(mapping::dependency_update_tasks(
                    repository,
                    &self.import_labels,
                    accumulator.dependencies.clone(),
                    true,
                ));
                (
                    slug,
                    RepositoryResult {
                        tasks: mapping::union_pull_request_intents(tasks),
                        failures: accumulator.failures.clone(),
                        assigned_succeeded: accumulator.assigned_succeeded,
                    },
                )
            })
            .collect()
    }
}

fn push_query(
    slots: &mut Vec<QuerySlot>,
    queries: &mut Vec<String>,
    contexts: &mut Vec<String>,
    repositories: &[String],
    kind: QueryKind,
    query: String,
    operation: &'static str,
) {
    slots.push(QuerySlot {
        repositories: repositories.to_vec(),
        kind,
        operation,
    });
    queries.push(query);
    contexts.push(format!("{operation} across configured repositories"));
}

#[derive(Clone, Copy)]
enum QueryKind {
    Assigned,
    Review,
    Dependency,
}

struct QuerySlot {
    repositories: Vec<String>,
    kind: QueryKind,
    operation: &'static str,
}

struct RepositoryAccumulator {
    assigned: Vec<GitHubSearchIssuePullRequestItem>,
    reviews: Vec<GitHubSearchIssuePullRequestItem>,
    dependencies: Vec<GitHubSearchIssuePullRequestItem>,
    failures: Vec<String>,
    assigned_succeeded: bool,
}

impl RepositoryAccumulator {
    const fn new() -> Self {
        Self {
            assigned: Vec::new(),
            reviews: Vec::new(),
            dependencies: Vec::new(),
            failures: Vec::new(),
            assigned_succeeded: true,
        }
    }
}

fn record_result(
    repositories: &mut HashMap<String, RepositoryAccumulator>,
    slot: &QuerySlot,
    result: Result<GitHubBatchSearchResult, String>,
) {
    match result {
        Ok(result) => record_success(repositories, slot, result),
        Err(error) => record_failure(repositories, slot, &error),
    }
}

fn record_success(
    repositories: &mut HashMap<String, RepositoryAccumulator>,
    slot: &QuerySlot,
    result: GitHubBatchSearchResult,
) {
    if !result.complete {
        for slug in &slot.repositories {
            repositories
                .get_mut(slug)
                .expect("batch slot belongs to a configured repository")
                .failures
                .push(format!(
                    "{} {} kept the newest GitHub page; background sync will finish history",
                    slug, slot.operation
                ));
        }
    }
    for item in result.items {
        let Some(slug) = item.repository_slug().map(str::to_ascii_lowercase) else {
            continue;
        };
        if !slot.repositories.contains(&slug) {
            continue;
        }
        let accumulator = repositories
            .get_mut(&slug)
            .expect("batch result belongs to a configured repository");
        match slot.kind {
            QueryKind::Assigned => accumulator.assigned.push(item),
            QueryKind::Review => accumulator.reviews.push(item),
            QueryKind::Dependency => accumulator.dependencies.push(item),
        }
    }
}

fn record_failure(
    repositories: &mut HashMap<String, RepositoryAccumulator>,
    slot: &QuerySlot,
    error: &str,
) {
    for slug in &slot.repositories {
        let accumulator = repositories
            .get_mut(slug)
            .expect("batch slot belongs to a configured repository");
        if matches!(slot.kind, QueryKind::Assigned) {
            accumulator.assigned_succeeded = false;
        }
        accumulator
            .failures
            .push(format!("{} {} failed: {error}", slug, slot.operation));
    }
}

struct RepositoryScope {
    repositories: Vec<String>,
}

fn repository_scopes(repositories: &[GitHubRepository]) -> Vec<RepositoryScope> {
    repositories
        .iter()
        .map(|repository| RepositoryScope {
            repositories: vec![repository.slug().to_ascii_lowercase()],
        })
        .collect()
}

struct RepositoryResult {
    tasks: Vec<ExternalTask>,
    failures: Vec<String>,
    assigned_succeeded: bool,
}

enum InboxBatchOutcome {
    Ready(HashMap<String, RepositoryResult>),
    Failed(SharedFailure),
}

struct SharedFailure {
    message: String,
    details: Option<String>,
}

impl SharedFailure {
    fn from_error(error: &CliError) -> Self {
        Self {
            message: error.message(),
            details: error.details().map(str::to_owned),
        }
    }

    fn to_error(&self) -> CliError {
        let error: CliError = CliErrorKind::workflow_io(self.message.clone()).into();
        match &self.details {
            Some(details) => error.with_details(details.clone()),
            None => error,
        }
    }
}

fn all_searches_failed(failures: &[String]) -> CliError {
    CliErrorKind::workflow_io("task-board github inbox sync failed for the configured repository")
        .with_details(
            failures
                .iter()
                .map(|failure| format!("- {failure}"))
                .collect::<Vec<_>>()
                .join("\n"),
        )
}
