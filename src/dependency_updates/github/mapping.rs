use std::path::PathBuf;

use chrono::{DateTime, Utc};

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::GitHubProjectConfig;

use super::types::*;
use super::{
    DependencyUpdateActionKind, DependencyUpdateActionOutcome, DependencyUpdateActionResult,
    DependencyUpdateCheck, DependencyUpdateCheckConclusion, DependencyUpdateCheckRunStatus,
    DependencyUpdateCheckStatus, DependencyUpdateItem, DependencyUpdateMergeableState,
    DependencyUpdatePullRequestState, DependencyUpdateReview, DependencyUpdateReviewEventState,
    DependencyUpdateReviewStatus, DependencyUpdateTarget, DependencyUpdatesQueryRequest,
    GRAPHQL_PAGE_SIZE, SCOPE_QUERY_CAP,
};

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

pub(super) fn convert_node(node: SearchNode) -> Result<DependencyUpdateItem, CliError> {
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
        author_login: node
            .author
            .and_then(|author| author.login)
            .unwrap_or_default(),
        state: map_pull_request_state(node.state.as_deref()),
        mergeable: map_mergeable_state(node.mergeable.as_deref()),
        review_status: map_review_status(node.review_decision.as_deref()),
        check_status,
        policy_blocked,
        is_draft: node.is_draft,
        head_sha: node.head_ref_oid.unwrap_or_default(),
        labels: node
            .labels
            .nodes
            .into_iter()
            .map(|label| label.name)
            .collect(),
        checks,
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
        additions: node.additions.max(0) as u64,
        deletions: node.deletions.max(0) as u64,
        created_at,
        updated_at,
    })
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
        Some("PENDING" | "EXPECTED") => DependencyUpdateCheckConclusion::None,
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
