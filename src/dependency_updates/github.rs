use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::OnceLock;

use chrono::{DateTime, Utc};
use octocrab::Octocrab;
use rustls::crypto::ring::default_provider;
use serde::Deserialize;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::{
    GitHubApiAutomationClient, GitHubAutomationClient, GitHubProjectConfig,
};

use super::{
    DependencyUpdateActionKind, DependencyUpdateActionOutcome, DependencyUpdateActionResult,
    DependencyUpdateCheck, DependencyUpdateCheckConclusion, DependencyUpdateCheckRunStatus,
    DependencyUpdateCheckStatus, DependencyUpdateItem, DependencyUpdateMergeableState,
    DependencyUpdatePullRequestState, DependencyUpdateReview, DependencyUpdateReviewEventState,
    DependencyUpdateReviewStatus, DependencyUpdateTarget, DependencyUpdatesApproveRequest,
    DependencyUpdatesAutoRequest, DependencyUpdatesLabelRequest, DependencyUpdatesMergeRequest,
    DependencyUpdatesQueryRequest, DependencyUpdatesRerunChecksRequest,
};

const SEARCH_QUERY: &str = r#"
query SearchDependencyUpdates($query: String!, $after: String) {
  search(query: $query, type: ISSUE, first: 100, after: $after) {
    pageInfo {
      hasNextPage
      endCursor
    }
    nodes {
      ... on PullRequest {
        id
        number
        title
        url
        state
        mergeable
        isDraft
        reviewDecision
        headRefOid
        author { login }
        repository {
          id
          nameWithOwner
        }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                contexts(first: 50) {
                  nodes {
                    ... on CheckRun {
                      name
                      status
                      conclusion
                      checkSuite { id }
                    }
                    ... on StatusContext {
                      context
                      state
                    }
                  }
                }
              }
            }
          }
        }
        reviews(last: 10) {
          nodes {
            author { login }
            state
          }
        }
        labels(first: 20) {
          nodes { name }
        }
        additions
        deletions
        createdAt
        updatedAt
      }
    }
  }
}
"#;

const APPROVE_MUTATION: &str = r#"
mutation ApproveDependencyUpdate($id: ID!) {
  addPullRequestReview(input: { pullRequestId: $id, event: APPROVE }) {
    pullRequestReview { state }
  }
}
"#;

const REREQUEST_CHECK_SUITE_MUTATION: &str = r#"
mutation RerequestDependencyUpdateCheckSuite($checkSuiteId: ID!, $repositoryId: ID!) {
  rerequestCheckSuite(input: { checkSuiteId: $checkSuiteId, repositoryId: $repositoryId }) {
    checkSuite { id }
  }
}
"#;

static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

pub(crate) struct DependencyUpdatesGitHubClient {
    client: Octocrab,
    automation: GitHubApiAutomationClient,
}

impl DependencyUpdatesGitHubClient {
    pub(crate) fn new(token: &str) -> Result<Self, CliError> {
        let token = token.trim();
        if token.is_empty() {
            return Err(
                CliErrorKind::workflow_io("dependency-updates github token missing").into(),
            );
        }
        ensure_rustls_provider();
        let client = Octocrab::builder()
            .personal_token(token.to_string())
            .build()
            .map_err(client_error)?;
        let automation = GitHubApiAutomationClient::new(token)?;
        Ok(Self { client, automation })
    }

    pub(crate) async fn fetch_updates(
        &self,
        request: &DependencyUpdatesQueryRequest,
    ) -> Result<Vec<DependencyUpdateItem>, CliError> {
        let mut deduped = BTreeMap::new();
        for scope in scopes(request) {
            let mut cursor = None;
            loop {
                let response: SearchResponse = self
                    .client
                    .graphql(&json!({
                        "query": SEARCH_QUERY,
                        "variables": {
                            "query": scope.query,
                            "after": cursor.as_deref(),
                        },
                    }))
                    .await
                    .map_err(operation_error)?;
                for node in response.search.nodes {
                    let item = convert_node(node)?;
                    if request
                        .normalized_exclude_repositories()
                        .contains(&item.repository)
                    {
                        continue;
                    }
                    deduped.insert(format!("{}#{}", item.repository, item.number), item);
                }
                if !response.search.page_info.has_next_page {
                    break;
                }
                cursor = response.search.page_info.end_cursor;
            }
        }
        Ok(deduped.into_values().collect())
    }

    pub(crate) async fn approve(
        &self,
        request: &DependencyUpdatesApproveRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = self
                .client
                .graphql::<serde_json::Value>(&json!({
                    "query": APPROVE_MUTATION,
                    "variables": {
                        "id": target.pull_request_id,
                    },
                }))
                .await;
            results.push(action_result(
                target,
                DependencyUpdateActionKind::Approve,
                result.map(|_| ()).map_err(operation_error),
            ));
        }
        Ok(results)
    }

    pub(crate) async fn merge(
        &self,
        request: &DependencyUpdatesMergeRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .merge_pull_request(
                        &config,
                        target.number,
                        request.method,
                        Some(target.head_sha.as_str()),
                    )
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid dependency-updates repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(
                target,
                DependencyUpdateActionKind::Merge,
                result,
            ));
        }
        Ok(results)
    }

    pub(crate) async fn rerun_checks(
        &self,
        request: &DependencyUpdatesRerunChecksRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            if target.check_suite_ids.is_empty() {
                results.push(DependencyUpdateActionResult {
                    repository: target.repository.clone(),
                    number: target.number,
                    action: DependencyUpdateActionKind::RerunChecks,
                    outcome: DependencyUpdateActionOutcome::Skipped,
                    message: Some("no rerunnable check suites were available".to_string()),
                });
                continue;
            }
            let mut outcome = Ok(());
            for check_suite_id in &target.check_suite_ids {
                if let Err(error) = self
                    .client
                    .graphql::<serde_json::Value>(&json!({
                        "query": REREQUEST_CHECK_SUITE_MUTATION,
                        "variables": {
                            "checkSuiteId": check_suite_id,
                            "repositoryId": target.repository_id,
                        },
                    }))
                    .await
                    .map_err(operation_error)
                {
                    outcome = Err(error);
                    break;
                }
            }
            results.push(action_result(
                target,
                DependencyUpdateActionKind::RerunChecks,
                outcome,
            ));
        }
        Ok(results)
    }

    pub(crate) async fn add_label(
        &self,
        request: &DependencyUpdatesLabelRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::with_capacity(request.targets.len());
        for target in &request.targets {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .sync_pull_request_labels(&config, target.number, &[], &[request.label.clone()])
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid dependency-updates repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(
                target,
                DependencyUpdateActionKind::AddLabel,
                result,
            ));
        }
        Ok(results)
    }

    pub(crate) async fn auto_mode(
        &self,
        request: &DependencyUpdatesAutoRequest,
    ) -> Result<Vec<DependencyUpdateActionResult>, CliError> {
        let mut results = Vec::new();
        for target in request.targets.iter().filter(|target| target.is_auto_approvable()) {
            let result = self
                .client
                .graphql::<serde_json::Value>(&json!({
                    "query": APPROVE_MUTATION,
                    "variables": {
                        "id": target.pull_request_id,
                    },
                }))
                .await
                .map(|_| ())
                .map_err(operation_error);
            results.push(action_result(
                target,
                DependencyUpdateActionKind::AutoApprove,
                result,
            ));
        }
        for target in request.targets.iter().filter(|target| {
            target.is_auto_mergeable() || target.is_auto_approvable()
        }) {
            let result = if let Some(config) = github_project_config(&target.repository) {
                self.automation
                    .merge_pull_request(
                        &config,
                        target.number,
                        request.method,
                        Some(target.head_sha.as_str()),
                    )
                    .await
            } else {
                Err(CliErrorKind::workflow_parse(format!(
                    "invalid dependency-updates repository '{}'",
                    target.repository
                ))
                .into())
            };
            results.push(action_result(
                target,
                DependencyUpdateActionKind::AutoMerge,
                result,
            ));
        }
        Ok(results)
    }
}

fn scopes(request: &DependencyUpdatesQueryRequest) -> Vec<ScopeQuery> {
    let authors = request.normalized_authors();
    let organizations = request.normalized_organizations();
    let repositories = request.normalized_repositories();
    let mut scopes = Vec::new();
    for author in &authors {
        for organization in &organizations {
            scopes.push(ScopeQuery {
                query: format!("org:{organization} author:{author} is:pr is:open"),
            });
        }
        for repository in &repositories {
            scopes.push(ScopeQuery {
                query: format!("repo:{repository} author:{author} is:pr is:open"),
            });
        }
    }
    scopes
}

fn convert_node(node: SearchNode) -> Result<DependencyUpdateItem, CliError> {
    let created_at = parse_timestamp(node.created_at.as_str())?;
    let updated_at = parse_timestamp(node.updated_at.as_str())?;
    let mut checks = Vec::new();
    let mut pending = 0;
    let mut failed = 0;
    let mut total = 0;
    let mut policy_blocked = false;

    if let Some(commit) = node
        .commits
        .nodes
        .into_iter()
        .last()
        .and_then(|node| node.commit)
        && let Some(rollup) = commit.status_check_rollup
    {
        for context in rollup.contexts.nodes {
            match context {
                StatusContextNode::CheckRun {
                    name,
                    status,
                    conclusion,
                    check_suite,
                } => {
                    total += 1;
                    let status = map_check_run_status(status.as_deref());
                    let conclusion = map_check_conclusion(conclusion.as_deref());
                    if status != DependencyUpdateCheckRunStatus::Completed {
                        pending += 1;
                    } else if matches!(
                        conclusion,
                        DependencyUpdateCheckConclusion::Failure
                            | DependencyUpdateCheckConclusion::Cancelled
                            | DependencyUpdateCheckConclusion::TimedOut
                            | DependencyUpdateCheckConclusion::ActionRequired
                            | DependencyUpdateCheckConclusion::StartupFailure
                    ) {
                        failed += 1;
                    }
                    checks.push(DependencyUpdateCheck {
                        name,
                        status,
                        conclusion,
                        check_suite_id: check_suite.and_then(|suite| suite.id),
                    });
                }
                StatusContextNode::StatusContext { context, state } => {
                    if context == "renovate/stability-days"
                        && !matches!(state.as_deref(), Some("SUCCESS"))
                    {
                        policy_blocked = true;
                        continue;
                    }
                    total += 1;
                    let conclusion = map_status_context_conclusion(state.as_deref());
                    if matches!(conclusion, DependencyUpdateCheckConclusion::Failure) {
                        failed += 1;
                    }
                    checks.push(DependencyUpdateCheck {
                        name: context,
                        status: DependencyUpdateCheckRunStatus::Completed,
                        conclusion,
                        check_suite_id: None,
                    });
                }
            }
        }
    }

    let check_status = if total == 0 {
        DependencyUpdateCheckStatus::None
    } else if failed > 0 {
        DependencyUpdateCheckStatus::Failure
    } else if pending > 0 {
        DependencyUpdateCheckStatus::Pending
    } else {
        DependencyUpdateCheckStatus::Success
    };

    Ok(DependencyUpdateItem {
        pull_request_id: node.id,
        repository_id: node.repository.id,
        repository: node.repository.name_with_owner,
        number: node.number,
        title: node.title,
        url: node.url,
        author_login: node.author.and_then(|author| author.login).unwrap_or_default(),
        state: map_pull_request_state(node.state.as_deref()),
        mergeable: map_mergeable_state(node.mergeable.as_deref()),
        review_status: map_review_status(node.review_decision.as_deref()),
        check_status,
        policy_blocked,
        is_draft: node.is_draft,
        head_sha: node.head_ref_oid.unwrap_or_default(),
        labels: node.labels.nodes.into_iter().map(|label| label.name).collect(),
        checks,
        reviews: node
            .reviews
            .nodes
            .into_iter()
            .map(|review| DependencyUpdateReview {
                author: review.author.and_then(|author| author.login).unwrap_or_default(),
                state: map_review_event_state(review.state.as_deref()),
            })
            .collect(),
        additions: node.additions.max(0) as u64,
        deletions: node.deletions.max(0) as u64,
        created_at,
        updated_at,
    })
}

fn github_project_config(repository: &str) -> Option<GitHubProjectConfig> {
    let (owner, repo) = repository.split_once('/')?;
    Some(GitHubProjectConfig::new(
        owner,
        repo,
        PathBuf::new(),
    ))
}

fn action_result(
    target: &DependencyUpdateTarget,
    action: DependencyUpdateActionKind,
    result: Result<(), CliError>,
) -> DependencyUpdateActionResult {
    match result {
        Ok(()) => DependencyUpdateActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action,
            outcome: DependencyUpdateActionOutcome::Applied,
            message: None,
        },
        Err(error) => DependencyUpdateActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action,
            outcome: DependencyUpdateActionOutcome::Failed,
            message: Some(error.to_string()),
        },
    }
}

fn parse_timestamp(value: &str) -> Result<DateTime<Utc>, CliError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "parse dependency-updates timestamp '{value}': {error}"
            ))
            .into()
        })
}

fn map_pull_request_state(value: Option<&str>) -> DependencyUpdatePullRequestState {
    match value {
        Some("OPEN") => DependencyUpdatePullRequestState::Open,
        Some("CLOSED") => DependencyUpdatePullRequestState::Closed,
        Some("MERGED") => DependencyUpdatePullRequestState::Merged,
        _ => DependencyUpdatePullRequestState::Unknown,
    }
}

fn map_mergeable_state(value: Option<&str>) -> DependencyUpdateMergeableState {
    match value {
        Some("MERGEABLE") => DependencyUpdateMergeableState::Mergeable,
        Some("CONFLICTING") => DependencyUpdateMergeableState::Conflicting,
        _ => DependencyUpdateMergeableState::Unknown,
    }
}

fn map_review_status(value: Option<&str>) -> DependencyUpdateReviewStatus {
    match value {
        Some("APPROVED") => DependencyUpdateReviewStatus::Approved,
        Some("CHANGES_REQUESTED") => DependencyUpdateReviewStatus::ChangesRequested,
        Some("REVIEW_REQUIRED") => DependencyUpdateReviewStatus::ReviewRequired,
        _ => DependencyUpdateReviewStatus::None,
    }
}

fn map_check_run_status(value: Option<&str>) -> DependencyUpdateCheckRunStatus {
    match value {
        Some("COMPLETED") => DependencyUpdateCheckRunStatus::Completed,
        Some("IN_PROGRESS") => DependencyUpdateCheckRunStatus::InProgress,
        Some("QUEUED") => DependencyUpdateCheckRunStatus::Queued,
        Some("REQUESTED") => DependencyUpdateCheckRunStatus::Requested,
        Some("WAITING") => DependencyUpdateCheckRunStatus::Waiting,
        _ => DependencyUpdateCheckRunStatus::Unknown,
    }
}

fn map_check_conclusion(value: Option<&str>) -> DependencyUpdateCheckConclusion {
    match value {
        Some("SUCCESS") => DependencyUpdateCheckConclusion::Success,
        Some("FAILURE") => DependencyUpdateCheckConclusion::Failure,
        Some("NEUTRAL") => DependencyUpdateCheckConclusion::Neutral,
        Some("CANCELLED") => DependencyUpdateCheckConclusion::Cancelled,
        Some("TIMED_OUT") => DependencyUpdateCheckConclusion::TimedOut,
        Some("ACTION_REQUIRED") => DependencyUpdateCheckConclusion::ActionRequired,
        Some("SKIPPED") => DependencyUpdateCheckConclusion::Skipped,
        Some("STALE") => DependencyUpdateCheckConclusion::Stale,
        Some("STARTUP_FAILURE") => DependencyUpdateCheckConclusion::StartupFailure,
        _ => DependencyUpdateCheckConclusion::None,
    }
}

fn map_status_context_conclusion(value: Option<&str>) -> DependencyUpdateCheckConclusion {
    match value {
        Some("SUCCESS") => DependencyUpdateCheckConclusion::Success,
        Some("FAILURE") | Some("ERROR") => DependencyUpdateCheckConclusion::Failure,
        Some("PENDING") | Some("EXPECTED") => DependencyUpdateCheckConclusion::None,
        _ => DependencyUpdateCheckConclusion::None,
    }
}

fn map_review_event_state(value: Option<&str>) -> DependencyUpdateReviewEventState {
    match value {
        Some("APPROVED") => DependencyUpdateReviewEventState::Approved,
        Some("CHANGES_REQUESTED") => DependencyUpdateReviewEventState::ChangesRequested,
        Some("COMMENTED") => DependencyUpdateReviewEventState::Commented,
        Some("DISMISSED") => DependencyUpdateReviewEventState::Dismissed,
        Some("PENDING") => DependencyUpdateReviewEventState::Pending,
        _ => DependencyUpdateReviewEventState::Unknown,
    }
}

fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(|| {
        let _ = default_provider().install_default();
    });
}

fn client_error(error: octocrab::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "create dependency-updates github client: {error}"
    )))
    .with_source(error)
}

fn operation_error(error: octocrab::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "dependency-updates github request failed: {error}"
    )))
    .with_source(error)
}

#[derive(Debug)]
struct ScopeQuery {
    query: String,
}

#[derive(Debug, Deserialize)]
struct SearchResponse {
    search: SearchConnection,
}

#[derive(Debug, Deserialize)]
struct SearchConnection {
    #[serde(rename = "pageInfo")]
    page_info: PageInfo,
    nodes: Vec<SearchNode>,
}

#[derive(Debug, Deserialize)]
struct PageInfo {
    #[serde(rename = "hasNextPage")]
    has_next_page: bool,
    #[serde(rename = "endCursor")]
    end_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SearchNode {
    id: String,
    number: u64,
    title: String,
    url: String,
    state: Option<String>,
    mergeable: Option<String>,
    #[serde(rename = "isDraft")]
    is_draft: bool,
    #[serde(rename = "reviewDecision")]
    review_decision: Option<String>,
    #[serde(rename = "headRefOid")]
    head_ref_oid: Option<String>,
    author: Option<LoginNode>,
    repository: RepositoryNode,
    commits: CommitConnection,
    reviews: ReviewConnection,
    labels: LabelConnection,
    additions: i64,
    deletions: i64,
    #[serde(rename = "createdAt")]
    created_at: String,
    #[serde(rename = "updatedAt")]
    updated_at: String,
}

#[derive(Debug, Deserialize)]
struct LoginNode {
    login: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RepositoryNode {
    id: String,
    #[serde(rename = "nameWithOwner")]
    name_with_owner: String,
}

#[derive(Debug, Deserialize)]
struct CommitConnection {
    nodes: Vec<CommitNode>,
}

#[derive(Debug, Deserialize)]
struct CommitNode {
    commit: Option<CommitPayload>,
}

#[derive(Debug, Deserialize)]
struct CommitPayload {
    #[serde(rename = "statusCheckRollup")]
    status_check_rollup: Option<StatusCheckRollup>,
}

#[derive(Debug, Deserialize)]
struct StatusCheckRollup {
    contexts: StatusCheckContexts,
}

#[derive(Debug, Deserialize)]
struct StatusCheckContexts {
    nodes: Vec<StatusContextNode>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum StatusContextNode {
    CheckRun {
        name: String,
        status: Option<String>,
        conclusion: Option<String>,
        #[serde(rename = "checkSuite")]
        check_suite: Option<CheckSuiteNode>,
    },
    StatusContext {
        context: String,
        state: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
struct CheckSuiteNode {
    id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ReviewConnection {
    nodes: Vec<ReviewNode>,
}

#[derive(Debug, Deserialize)]
struct ReviewNode {
    author: Option<LoginNode>,
    state: Option<String>,
}

#[derive(Debug, Deserialize)]
struct LabelConnection {
    nodes: Vec<LabelNode>,
}

#[derive(Debug, Deserialize)]
struct LabelNode {
    name: String,
}
