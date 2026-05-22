use std::collections::BTreeSet;
use std::path::PathBuf;

use chrono::{DateTime, Utc};

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::GitHubProjectConfig;

use super::check_status::{is_failed_check_conclusion, normalized_details_url};
use super::types::{
    CommitConnection, LabelNode, PageInfo, RepositoryLabelNode, ReviewNode, SearchNode,
    StatusContextNode,
};
use super::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionResult,
    ReviewCheck, ReviewCheckConclusion, ReviewCheckRunStatus,
    ReviewCheckStatus, ReviewItem, ReviewMergeableState,
    ReviewPullRequestState, ReviewRepositoryLabel, PullRequestReview,
    ReviewReviewEventState, ReviewReviewStatus, ReviewTarget,
    ReviewsQueryRequest, GRAPHQL_PAGE_SIZE, SCOPE_QUERY_CAP,
};

pub(super) type RepositoryLabelBundle = (String, Vec<ReviewRepositoryLabel>);

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
    pub(super) required_check_names: Vec<String>,
}

impl NodeContinuation {
    pub(super) fn has_work(&self) -> bool {
        self.pr_labels.is_some()
            || self.reviews.is_some()
            || self.checks.is_some()
            || self.repository_labels.is_some()
    }
}

pub(super) fn scopes(request: &ReviewsQueryRequest) -> Result<Vec<ScopeQuery>, CliError> {
    let authors = request.normalized_authors();
    let organizations = request.normalized_organizations();
    let repositories = request.normalized_repositories();
    let scope_count = authors
        .len()
        .saturating_mul(organizations.len().saturating_add(repositories.len()));
    if scope_count > SCOPE_QUERY_CAP {
        return Err(CliErrorKind::workflow_parse(format!(
            "reviews query resolves to {scope_count} GitHub searches; narrow authors, organizations, or repositories to at most {SCOPE_QUERY_CAP} searches"
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
        ReviewItem,
        Option<RepositoryLabelBundle>,
        NodeContinuation,
    ),
    CliError,
> {
    let created_at = parse_timestamp(node.created_at.as_str())?;
    let updated_at = parse_timestamp(node.updated_at.as_str())?;
    let pull_request_id = node.id.clone();
    let repository_id = node.repository.id.clone();
    let required_check_names = required_check_names(node.base_ref.as_ref());
    let check_summary = CheckSummary::from_commits(node.commits);
    let checks_continuation = check_summary
        .next_page_cursor
        .clone()
        .map(|cursor| InnerCursor {
            after: Some(cursor),
        });
    let required_failed_check_names =
        required_failed_check_names(&check_summary.checks, &required_check_names);

    let repository_name = node.repository.name_with_owner;
    let (repository_label_bundle, repository_labels_continuation) = match node.repository.labels {
        Some(connection) => {
            let labels = connection
                .nodes
                .into_iter()
                .map(|label| ReviewRepositoryLabel {
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

    let item = ReviewItem {
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
            .map(|review| PullRequestReview {
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
        required_failed_check_names,
        viewer_can_update: node.viewer_can_update.unwrap_or(true),
        viewer_can_merge_as_admin: node.viewer_can_merge_as_admin.unwrap_or(false),
    };
    let continuation = NodeContinuation {
        pull_request_id,
        repository_id,
        pr_labels: pr_labels_continuation,
        reviews: reviews_continuation,
        checks: checks_continuation,
        repository_labels: repository_labels_continuation,
        required_check_names,
    };
    Ok((item, repository_label_bundle, continuation))
}

#[derive(Default)]
pub(super) struct CheckSummary {
    pub(super) checks: Vec<ReviewCheck>,
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
        if status != ReviewCheckRunStatus::Completed {
            self.pending += 1;
        } else if is_failed_check_conclusion(conclusion) {
            self.failed += 1;
        }
        self.checks.push(ReviewCheck {
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
        if matches!(conclusion, ReviewCheckConclusion::Failure) {
            self.failed += 1;
        }
        self.checks.push(ReviewCheck {
            name: context,
            status: ReviewCheckRunStatus::Completed,
            conclusion,
            check_suite_id: None,
            details_url: normalized_details_url(details_url),
        });
    }

    fn status(&self) -> ReviewCheckStatus {
        if self.total == 0 {
            ReviewCheckStatus::None
        } else if self.failed > 0 {
            ReviewCheckStatus::Failure
        } else if self.pending > 0 {
            ReviewCheckStatus::Pending
        } else {
            ReviewCheckStatus::Success
        }
    }
}

pub(super) fn append_pull_request_labels(item: &mut ReviewItem, labels: Vec<LabelNode>) {
    item.labels
        .extend(labels.into_iter().map(|label| label.name));
}

pub(super) fn append_pull_request_reviews(
    item: &mut ReviewItem,
    reviews: Vec<ReviewNode>,
) {
    item.reviews.extend(reviews.into_iter().map(|review| {
        PullRequestReview {
            author: review
                .author
                .and_then(|author| author.login)
                .unwrap_or_default(),
            state: map_review_event_state(review.state.as_deref()),
        }
    }));
}

pub(super) fn append_check_contexts(
    item: &mut ReviewItem,
    contexts: Vec<StatusContextNode>,
    required_check_names: &[String],
) {
    let mut summary = CheckSummary::default();
    for context in contexts {
        summary.push_context(context);
    }
    item.policy_blocked = item.policy_blocked || summary.policy_blocked;
    item.checks.extend(summary.checks);
    item.check_status = recompute_check_status(&item.checks);
    item.required_failed_check_names =
        required_failed_check_names(&item.checks, required_check_names);
}

pub(super) fn append_repository_labels(
    bundle: &mut Vec<ReviewRepositoryLabel>,
    labels: Vec<RepositoryLabelNode>,
) {
    bundle.extend(
        labels
            .into_iter()
            .map(|label| ReviewRepositoryLabel {
                name: label.name,
                color: label.color.filter(|value| !value.is_empty()),
                description: label.description.filter(|value| !value.is_empty()),
            }),
    );
}

fn required_check_names(base_ref: Option<&super::types::RefNode>) -> Vec<String> {
    let Some(branch_protection) =
        base_ref.and_then(|base_ref| base_ref.branch_protection_rule.as_ref())
    else {
        return Vec::new();
    };
    let mut names = BTreeSet::new();
    for context in &branch_protection.required_status_check_contexts {
        names.insert(context.clone());
    }
    for check in &branch_protection.required_status_checks {
        names.insert(check.context.clone());
    }
    names.into_iter().collect()
}

fn required_failed_check_names(
    checks: &[ReviewCheck],
    required_check_names: &[String],
) -> Vec<String> {
    let required = required_check_names
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    checks
        .iter()
        .filter(|check| {
            required.contains(check.name.as_str()) && is_failed_check_conclusion(check.conclusion)
        })
        .map(|check| check.name.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn recompute_check_status(checks: &[ReviewCheck]) -> ReviewCheckStatus {
    if checks.is_empty() {
        return ReviewCheckStatus::None;
    }
    let mut pending = 0_u64;
    let mut failed = 0_u64;
    for check in checks {
        if check.status != ReviewCheckRunStatus::Completed {
            pending += 1;
        } else if is_failed_check_conclusion(check.conclusion) {
            failed += 1;
        }
    }
    if failed > 0 {
        ReviewCheckStatus::Failure
    } else if pending > 0 {
        ReviewCheckStatus::Pending
    } else {
        ReviewCheckStatus::Success
    }
}

pub(super) fn github_project_config(repository: &str) -> Option<GitHubProjectConfig> {
    let (owner, repo) = repository.split_once('/')?;
    Some(GitHubProjectConfig::new(owner, repo, PathBuf::new()))
}

pub(super) fn action_result(
    target: &ReviewTarget,
    action: ReviewActionKind,
    result: Result<(), CliError>,
) -> ReviewActionResult {
    match result {
        Ok(()) => ReviewActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action,
            outcome: ReviewActionOutcome::Applied,
            message: None,
            timeline_entry: None,
        },
        Err(error) => ReviewActionResult {
            repository: target.repository.clone(),
            number: target.number,
            action,
            outcome: ReviewActionOutcome::Failed,
            message: Some(error.to_string()),
            timeline_entry: None,
        },
    }
}

pub(super) fn parse_timestamp(value: &str) -> Result<DateTime<Utc>, CliError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "parse reviews timestamp '{value}': {error}"
            ))
            .into()
        })
}

pub(super) fn map_pull_request_state(value: Option<&str>) -> ReviewPullRequestState {
    match value {
        Some("OPEN") => ReviewPullRequestState::Open,
        Some("CLOSED") => ReviewPullRequestState::Closed,
        Some("MERGED") => ReviewPullRequestState::Merged,
        _ => ReviewPullRequestState::Unknown,
    }
}

pub(super) fn map_mergeable_state(value: Option<&str>) -> ReviewMergeableState {
    match value {
        Some("MERGEABLE") => ReviewMergeableState::Mergeable,
        Some("CONFLICTING") => ReviewMergeableState::Conflicting,
        _ => ReviewMergeableState::Unknown,
    }
}

pub(super) fn map_review_status(value: Option<&str>) -> ReviewReviewStatus {
    match value {
        Some("APPROVED") => ReviewReviewStatus::Approved,
        Some("CHANGES_REQUESTED") => ReviewReviewStatus::ChangesRequested,
        Some("REVIEW_REQUIRED") => ReviewReviewStatus::ReviewRequired,
        _ => ReviewReviewStatus::None,
    }
}

pub(super) fn map_check_run_status(value: Option<&str>) -> ReviewCheckRunStatus {
    match value {
        Some("COMPLETED") => ReviewCheckRunStatus::Completed,
        Some("IN_PROGRESS") => ReviewCheckRunStatus::InProgress,
        Some("QUEUED") => ReviewCheckRunStatus::Queued,
        Some("REQUESTED") => ReviewCheckRunStatus::Requested,
        Some("WAITING") => ReviewCheckRunStatus::Waiting,
        _ => ReviewCheckRunStatus::Unknown,
    }
}

pub(super) fn map_check_conclusion(value: Option<&str>) -> ReviewCheckConclusion {
    match value {
        Some("SUCCESS") => ReviewCheckConclusion::Success,
        Some("FAILURE") => ReviewCheckConclusion::Failure,
        Some("NEUTRAL") => ReviewCheckConclusion::Neutral,
        Some("CANCELLED") => ReviewCheckConclusion::Cancelled,
        Some("TIMED_OUT") => ReviewCheckConclusion::TimedOut,
        Some("ACTION_REQUIRED") => ReviewCheckConclusion::ActionRequired,
        Some("SKIPPED") => ReviewCheckConclusion::Skipped,
        Some("STALE") => ReviewCheckConclusion::Stale,
        Some("STARTUP_FAILURE") => ReviewCheckConclusion::StartupFailure,
        _ => ReviewCheckConclusion::None,
    }
}

pub(super) fn map_status_context_conclusion(
    value: Option<&str>,
) -> ReviewCheckConclusion {
    match value {
        Some("SUCCESS") => ReviewCheckConclusion::Success,
        Some("FAILURE" | "ERROR") => ReviewCheckConclusion::Failure,
        _ => ReviewCheckConclusion::None,
    }
}

pub(super) fn map_review_event_state(value: Option<&str>) -> ReviewReviewEventState {
    match value {
        Some("APPROVED") => ReviewReviewEventState::Approved,
        Some("CHANGES_REQUESTED") => ReviewReviewEventState::ChangesRequested,
        Some("COMMENTED") => ReviewReviewEventState::Commented,
        Some("DISMISSED") => ReviewReviewEventState::Dismissed,
        Some("PENDING") => ReviewReviewEventState::Pending,
        _ => ReviewReviewEventState::Unknown,
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
