use std::path::PathBuf;

use chrono::{DateTime, Utc};

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::GitHubProjectConfig;

use super::types::{
    CommitConnection, LabelNode, PageInfo, RepositoryLabelNode, ReviewNode, SearchNode,
    StatusContextNode,
};
use super::{
    DependencyUpdateActionKind, DependencyUpdateActionOutcome, DependencyUpdateActionResult,
    DependencyUpdateCheck, DependencyUpdateCheckConclusion, DependencyUpdateCheckRunStatus,
    DependencyUpdateCheckStatus, DependencyUpdateItem, DependencyUpdateMergeableState,
    DependencyUpdatePullRequestState, DependencyUpdateRepositoryLabel, DependencyUpdateReview,
    DependencyUpdateReviewEventState, DependencyUpdateReviewStatus, DependencyUpdateTarget,
    DependencyUpdatesQueryRequest, GRAPHQL_PAGE_SIZE, SCOPE_QUERY_CAP,
};

pub(super) type RepositoryLabelBundle = (String, Vec<DependencyUpdateRepositoryLabel>);

#[derive(Debug, Clone)]
pub(super) struct InnerCursor {
    pub(super) after: Option<String>,
}

#[derive(Debug)]
pub(super) struct NodeContinuation {
    pub(super) pull_request_id: String,
    pub(super) repository_id: String,
    pub(super) pr_labels: Option<InnerCursor>,
    pub(super) reviews: Option<InnerCursor>,
    pub(super) checks: Option<InnerCursor>,
    pub(super) repository_labels: Option<InnerCursor>,
}

impl NodeContinuation {
    pub(super) fn has_work(&self) -> bool {
        self.pr_labels.is_some()
            || self.reviews.is_some()
            || self.checks.is_some()
            || self.repository_labels.is_some()
    }
}

pub(super) fn scopes(request: &DependencyUpdatesQueryRequest) -> Result<Vec<ScopeQuery>, CliError> {
    let authors = request.normalized_authors();
    let organizations = request.normalized_organizations();
    let repositories = request.normalized_repositories();
    let scope_count = authors
        .len()
        .saturating_mul(organizations.len().saturating_add(repositories.len()));
    if scope_count > SCOPE_QUERY_CAP {
        return Err(CliErrorKind::workflow_parse(format!(
            "dependency-updates query resolves to {scope_count} GitHub searches; narrow authors, organizations, or repositories to at most {SCOPE_QUERY_CAP} searches"
        ))
        .into());
    }
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
    Ok(scopes)
}

pub(super) fn convert_node(
    node: SearchNode,
) -> Result<
    (
        DependencyUpdateItem,
        Option<RepositoryLabelBundle>,
        NodeContinuation,
    ),
    CliError,
> {
    let created_at = parse_timestamp(node.created_at.as_str())?;
    let updated_at = parse_timestamp(node.updated_at.as_str())?;
    let pull_request_id = node.id.clone();
    let repository_id = node.repository.id.clone();
    let check_summary = CheckSummary::from_commits(node.commits);
    let checks_continuation = check_summary
        .next_page_cursor
        .clone()
        .map(|cursor| InnerCursor {
            after: Some(cursor),
        });

    let repository_name = node.repository.name_with_owner;
    let (repository_label_bundle, repository_labels_continuation) = match node.repository.labels {
        Some(connection) => {
            let labels = connection
                .nodes
                .into_iter()
                .map(|label| DependencyUpdateRepositoryLabel {
                    name: label.name,
                    color: label.color.filter(|value| !value.is_empty()),
                    description: label.description.filter(|value| !value.is_empty()),
                })
                .collect::<Vec<_>>();
            let continuation = if connection.page_info.has_next_page {
                Some(InnerCursor {
                    after: connection.page_info.end_cursor,
                })
            } else {
                None
            };
            (Some((repository_name.clone(), labels)), continuation)
        }
        None => (None, None),
    };

    let pr_labels_continuation = if node.labels.page_info.has_next_page {
        Some(InnerCursor {
            after: node.labels.page_info.end_cursor.clone(),
        })
    } else {
        None
    };
    let reviews_continuation = if node.reviews.page_info.has_next_page {
        Some(InnerCursor {
            after: node.reviews.page_info.end_cursor.clone(),
        })
    } else {
        None
    };

    let item = DependencyUpdateItem {
        pull_request_id: pull_request_id.clone(),
        repository_id: repository_id.clone(),
        repository: repository_name,
        number: node.number,
        title: node.title,
        url: node.url,
        author_login: node
            .author
            .and_then(|author| author.login)
            .unwrap_or_default(),
        state: map_pull_request_state(node.state.as_deref()),
        mergeable: map_mergeable_state(node.mergeable.as_deref()),
        review_status: map_review_status(node.review_decision.as_deref()),
        check_status: check_summary.status(),
        policy_blocked: check_summary.policy_blocked,
        is_draft: node.is_draft,
        head_sha: node.head_ref_oid.unwrap_or_default(),
        labels: node
            .labels
            .nodes
            .into_iter()
            .map(|label| label.name)
            .collect(),
        checks: check_summary.checks,
        reviews: node
            .reviews
            .nodes
            .into_iter()
            .map(|review| DependencyUpdateReview {
                author: review
                    .author
                    .and_then(|author| author.login)
                    .unwrap_or_default(),
                state: map_review_event_state(review.state.as_deref()),
            })
            .collect(),
        additions: node.additions.max(0).cast_unsigned(),
        deletions: node.deletions.max(0).cast_unsigned(),
        created_at,
        updated_at,
    };
    let continuation = NodeContinuation {
        pull_request_id,
        repository_id,
        pr_labels: pr_labels_continuation,
        reviews: reviews_continuation,
        checks: checks_continuation,
        repository_labels: repository_labels_continuation,
    };
    Ok((item, repository_label_bundle, continuation))
}

#[derive(Default)]
pub(super) struct CheckSummary {
    pub(super) checks: Vec<DependencyUpdateCheck>,
    pending: u64,
    failed: u64,
    total: u64,
    pub(super) policy_blocked: bool,
    pub(super) next_page_cursor: Option<String>,
}

impl CheckSummary {
    fn from_commits(commits: CommitConnection) -> Self {
        let mut summary = Self::default();
        let Some(rollup) = commits
            .nodes
            .into_iter()
            .last()
            .and_then(|node| node.commit)
            .and_then(|commit| commit.status_check_rollup)
        else {
            return summary;
        };
        if rollup.contexts.page_info.has_next_page {
            summary
                .next_page_cursor
                .clone_from(&rollup.contexts.page_info.end_cursor);
        }
        for context in rollup.contexts.nodes {
            summary.push_context(context);
        }
        summary
    }

    fn push_context(&mut self, context: StatusContextNode) {
        match context {
            StatusContextNode::CheckRun {
                name,
                status,
                conclusion,
                url,
                check_suite,
            } => self.push_check_run(
                name,
                status.as_deref(),
                conclusion.as_deref(),
                check_suite.and_then(|suite| suite.id),
                url,
            ),
            StatusContextNode::StatusContext {
                context,
                state,
                target_url,
            } => {
                self.push_status_context(context, state.as_deref(), target_url);
            }
        }
    }

    fn push_check_run(
        &mut self,
        name: String,
        status: Option<&str>,
        conclusion: Option<&str>,
        check_suite_id: Option<String>,
        details_url: Option<String>,
    ) {
        self.total += 1;
        let status = map_check_run_status(status);
        let conclusion = map_check_conclusion(conclusion);
        if status != DependencyUpdateCheckRunStatus::Completed {
            self.pending += 1;
        } else if is_failed_check_conclusion(conclusion) {
            self.failed += 1;
        }
        self.checks.push(DependencyUpdateCheck {
            name,
            status,
            conclusion,
            check_suite_id,
            details_url: normalized_details_url(details_url),
        });
    }

    fn push_status_context(
        &mut self,
        context: String,
        state: Option<&str>,
        details_url: Option<String>,
    ) {
        if context == "renovate/stability-days" && !matches!(state, Some("SUCCESS")) {
            self.policy_blocked = true;
            return;
        }
        self.total += 1;
        let conclusion = map_status_context_conclusion(state);
        if matches!(conclusion, DependencyUpdateCheckConclusion::Failure) {
            self.failed += 1;
        }
        self.checks.push(DependencyUpdateCheck {
            name: context,
            status: DependencyUpdateCheckRunStatus::Completed,
            conclusion,
            check_suite_id: None,
            details_url: normalized_details_url(details_url),
        });
    }

    fn status(&self) -> DependencyUpdateCheckStatus {
        if self.total == 0 {
            DependencyUpdateCheckStatus::None
        } else if self.failed > 0 {
            DependencyUpdateCheckStatus::Failure
        } else if self.pending > 0 {
            DependencyUpdateCheckStatus::Pending
        } else {
            DependencyUpdateCheckStatus::Success
        }
    }
}

fn is_failed_check_conclusion(conclusion: DependencyUpdateCheckConclusion) -> bool {
    matches!(
        conclusion,
        DependencyUpdateCheckConclusion::Failure
            | DependencyUpdateCheckConclusion::Cancelled
            | DependencyUpdateCheckConclusion::TimedOut
            | DependencyUpdateCheckConclusion::ActionRequired
            | DependencyUpdateCheckConclusion::StartupFailure
    )
}

fn normalized_details_url(details_url: Option<String>) -> Option<String> {
    let trimmed = details_url?.trim().to_string();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("https://") || lower.starts_with("http://") {
        Some(trimmed)
    } else {
        None
    }
}

pub(super) fn append_pull_request_labels(item: &mut DependencyUpdateItem, labels: Vec<LabelNode>) {
    item.labels
        .extend(labels.into_iter().map(|label| label.name));
}

pub(super) fn append_pull_request_reviews(
    item: &mut DependencyUpdateItem,
    reviews: Vec<ReviewNode>,
) {
    item.reviews.extend(reviews.into_iter().map(|review| {
        DependencyUpdateReview {
            author: review
                .author
                .and_then(|author| author.login)
                .unwrap_or_default(),
            state: map_review_event_state(review.state.as_deref()),
        }
    }));
}

pub(super) fn append_check_contexts(
    item: &mut DependencyUpdateItem,
    contexts: Vec<StatusContextNode>,
) {
    let mut summary = CheckSummary::default();
    for context in contexts {
        summary.push_context(context);
    }
    item.policy_blocked = item.policy_blocked || summary.policy_blocked;
    item.checks.extend(summary.checks);
    item.check_status = recompute_check_status(&item.checks);
}

pub(super) fn append_repository_labels(
    bundle: &mut Vec<DependencyUpdateRepositoryLabel>,
    labels: Vec<RepositoryLabelNode>,
) {
    bundle.extend(
        labels
            .into_iter()
            .map(|label| DependencyUpdateRepositoryLabel {
                name: label.name,
                color: label.color.filter(|value| !value.is_empty()),
                description: label.description.filter(|value| !value.is_empty()),
            }),
    );
}

fn recompute_check_status(checks: &[DependencyUpdateCheck]) -> DependencyUpdateCheckStatus {
    if checks.is_empty() {
        return DependencyUpdateCheckStatus::None;
    }
    let mut pending = 0_u64;
    let mut failed = 0_u64;
    for check in checks {
        if check.status != DependencyUpdateCheckRunStatus::Completed {
            pending += 1;
        } else if is_failed_check_conclusion(check.conclusion) {
            failed += 1;
        }
    }
    if failed > 0 {
        DependencyUpdateCheckStatus::Failure
    } else if pending > 0 {
        DependencyUpdateCheckStatus::Pending
    } else {
        DependencyUpdateCheckStatus::Success
    }
}

pub(super) fn github_project_config(repository: &str) -> Option<GitHubProjectConfig> {
    let (owner, repo) = repository.split_once('/')?;
    Some(GitHubProjectConfig::new(owner, repo, PathBuf::new()))
}

pub(super) fn action_result(
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

pub(super) fn parse_timestamp(value: &str) -> Result<DateTime<Utc>, CliError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "parse dependency-updates timestamp '{value}': {error}"
            ))
            .into()
        })
}

pub(super) fn map_pull_request_state(value: Option<&str>) -> DependencyUpdatePullRequestState {
    match value {
        Some("OPEN") => DependencyUpdatePullRequestState::Open,
        Some("CLOSED") => DependencyUpdatePullRequestState::Closed,
        Some("MERGED") => DependencyUpdatePullRequestState::Merged,
        _ => DependencyUpdatePullRequestState::Unknown,
    }
}

pub(super) fn map_mergeable_state(value: Option<&str>) -> DependencyUpdateMergeableState {
    match value {
        Some("MERGEABLE") => DependencyUpdateMergeableState::Mergeable,
        Some("CONFLICTING") => DependencyUpdateMergeableState::Conflicting,
        _ => DependencyUpdateMergeableState::Unknown,
    }
}

pub(super) fn map_review_status(value: Option<&str>) -> DependencyUpdateReviewStatus {
    match value {
        Some("APPROVED") => DependencyUpdateReviewStatus::Approved,
        Some("CHANGES_REQUESTED") => DependencyUpdateReviewStatus::ChangesRequested,
        Some("REVIEW_REQUIRED") => DependencyUpdateReviewStatus::ReviewRequired,
        _ => DependencyUpdateReviewStatus::None,
    }
}

pub(super) fn map_check_run_status(value: Option<&str>) -> DependencyUpdateCheckRunStatus {
    match value {
        Some("COMPLETED") => DependencyUpdateCheckRunStatus::Completed,
        Some("IN_PROGRESS") => DependencyUpdateCheckRunStatus::InProgress,
        Some("QUEUED") => DependencyUpdateCheckRunStatus::Queued,
        Some("REQUESTED") => DependencyUpdateCheckRunStatus::Requested,
        Some("WAITING") => DependencyUpdateCheckRunStatus::Waiting,
        _ => DependencyUpdateCheckRunStatus::Unknown,
    }
}

pub(super) fn map_check_conclusion(value: Option<&str>) -> DependencyUpdateCheckConclusion {
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

pub(super) fn map_status_context_conclusion(
    value: Option<&str>,
) -> DependencyUpdateCheckConclusion {
    match value {
        Some("SUCCESS") => DependencyUpdateCheckConclusion::Success,
        Some("FAILURE" | "ERROR") => DependencyUpdateCheckConclusion::Failure,
        _ => DependencyUpdateCheckConclusion::None,
    }
}

pub(super) fn map_review_event_state(value: Option<&str>) -> DependencyUpdateReviewEventState {
    match value {
        Some("APPROVED") => DependencyUpdateReviewEventState::Approved,
        Some("CHANGES_REQUESTED") => DependencyUpdateReviewEventState::ChangesRequested,
        Some("COMMENTED") => DependencyUpdateReviewEventState::Commented,
        Some("DISMISSED") => DependencyUpdateReviewEventState::Dismissed,
        Some("PENDING") => DependencyUpdateReviewEventState::Pending,
        _ => DependencyUpdateReviewEventState::Unknown,
    }
}

pub(super) fn next_cursor_or_scope_limit(
    page_info: &PageInfo,
    page: u32,
    page_cap: u32,
    context: &str,
) -> Result<Option<String>, CliError> {
    if page >= page_cap {
        return Err(CliErrorKind::workflow_io(format!(
            "{context} exceeded {} GitHub GraphQL results; narrow the request before retrying",
            page_cap * GRAPHQL_PAGE_SIZE
        ))
        .into());
    }
    page_info.end_cursor.clone().map(Some).ok_or_else(|| {
        CliErrorKind::workflow_io(format!("{context} returned a next page without a cursor")).into()
    })
}

#[derive(Debug)]
pub(super) struct ScopeQuery {
    pub(super) query: String,
}
