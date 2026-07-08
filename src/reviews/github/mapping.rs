use std::collections::BTreeMap;
use std::mem;
use std::path::PathBuf;

use chrono::{DateTime, Utc};

use crate::errors::{CliError, CliErrorKind};
use crate::reviews::ReviewAuthorAssociation;
use crate::reviews::backports::BackportDetector;
use crate::task_board::github::GitHubProjectConfig;

use super::types::{
    CommitConnection, LabelNode, PageInfo, RepositoryLabelConnection, RepositoryLabelNode,
    ReviewNode, SearchNode, StatusContextNode,
};
use super::{
    GRAPHQL_PAGE_SIZE, PullRequestReview, ReviewActionKind, ReviewActionOutcome,
    ReviewActionResult, ReviewItem, ReviewRepositoryLabel, ReviewReviewEventState, ReviewTarget,
    ReviewsQueryRequest, SCOPE_QUERY_CAP,
};

mod check_summary;
mod enums;

use check_summary::{
    CheckSummary, recompute_check_status, required_check_names, required_failed_check_names,
};
pub(super) use enums::{
    map_mergeable_state, map_pull_request_state, map_review_event_state, map_review_status,
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
    let author_fanout = authors.len().max(1);
    let scope_count =
        author_fanout.saturating_mul(organizations.len().saturating_add(repositories.len()));
    if scope_count > SCOPE_QUERY_CAP {
        return Err(CliErrorKind::workflow_parse(format!(
            "reviews query resolves to {scope_count} GitHub searches; narrow authors, organizations, or repositories to at most {SCOPE_QUERY_CAP} searches"
        ))
        .into());
    }
    let mut scopes = Vec::new();
    if authors.is_empty() {
        for organization in &organizations {
            scopes.push(ScopeQuery {
                query: format!("org:{organization} is:pr is:open"),
            });
        }
        for repository in &repositories {
            scopes.push(ScopeQuery {
                query: format!("repo:{repository} is:pr is:open"),
            });
        }
    } else {
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
    }
    Ok(scopes)
}

pub(super) fn convert_node(
    mut node: SearchNode,
    backport_detector: Option<&BackportDetector>,
    viewer_login: Option<&str>,
) -> Result<(ReviewItem, Option<RepositoryLabelBundle>, NodeContinuation), CliError> {
    let created_at = parse_timestamp(node.created_at.as_str())?;
    let updated_at = parse_timestamp(node.updated_at.as_str())?;
    let pull_request_id = node.id.clone();
    let repository_id = node.repository.id.clone();
    let required_check_names = required_check_names(node.base_ref.as_ref());

    // Extract fields from node before any partial moves.
    let repository_name = node.repository.name_with_owner.clone();
    let repository_labels = node.repository.labels.take();
    let pr_labels_has_next = node.labels.page_info.has_next_page;
    let pr_labels_cursor = node.labels.page_info.end_cursor.clone();
    let reviews_has_next = node.reviews.page_info.has_next_page;
    let reviews_cursor = node.reviews.page_info.end_cursor.clone();
    let commits = mem::replace(&mut node.commits, CommitConnection { nodes: Vec::new() });
    let check_summary = CheckSummary::from_commits(commits);
    let checks_continuation = check_summary
        .next_page_cursor
        .clone()
        .map(|cursor| InnerCursor {
            after: Some(cursor),
        });
    let required_failed_check_names =
        required_failed_check_names(&check_summary.checks, &required_check_names);

    let (repository_label_bundle, repository_labels_continuation) =
        convert_repository_labels(repository_labels, &repository_name);

    let pr_labels_continuation = pr_labels_has_next.then_some(InnerCursor {
        after: pr_labels_cursor,
    });
    let reviews_continuation = reviews_has_next.then_some(InnerCursor {
        after: reviews_cursor,
    });

    let item = build_review_item(
        NodeItemContext {
            pull_request_id: pull_request_id.clone(),
            repository_id: repository_id.clone(),
            repository_name,
            check_summary,
            required_failed_check_names,
            created_at,
            updated_at,
        },
        node,
        backport_detector,
        viewer_login,
    );
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

fn convert_repository_labels(
    labels: Option<RepositoryLabelConnection>,
    repository_name: &str,
) -> (Option<RepositoryLabelBundle>, Option<InnerCursor>) {
    match labels {
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
            let continuation = connection.page_info.has_next_page.then_some(InnerCursor {
                after: connection.page_info.end_cursor,
            });
            (Some((repository_name.to_string(), labels)), continuation)
        }
        None => (None, None),
    }
}

struct NodeItemContext {
    pull_request_id: String,
    repository_id: String,
    repository_name: String,
    check_summary: CheckSummary,
    required_failed_check_names: Vec<String>,
    created_at: chrono::DateTime<chrono::Utc>,
    updated_at: chrono::DateTime<chrono::Utc>,
}
fn build_review_item(
    ctx: NodeItemContext,
    node: SearchNode,
    backport_detector: Option<&BackportDetector>,
    viewer_login: Option<&str>,
) -> ReviewItem {
    let (author_login, author_avatar_url) = node.author.map_or_else(
        || (String::new(), None),
        |author| (author.login.unwrap_or_default(), author.avatar_url),
    );
    let default_branch_name = node
        .repository
        .default_branch_ref
        .as_ref()
        .map(|branch| branch.name.clone());
    let viewer_is_requested_reviewer = viewer_login.is_some_and(|viewer_login| {
        node.review_requests
            .as_ref()
            .is_some_and(|review_requests| {
                review_requests.nodes.iter().any(|review_request| {
                    review_request
                        .requested_reviewer
                        .as_ref()
                        .and_then(|reviewer| reviewer.login())
                        .is_some_and(|login| login.eq_ignore_ascii_case(viewer_login))
                })
            })
    });
    let backport_detection =
        backport_detector.and_then(|detector| detector.detect(&ctx.repository_name, &node.title));
    let (title, backport_source) = backport_detection.map_or_else(
        || (node.title, None),
        |detection| (detection.title, Some(detection.source)),
    );
    ReviewItem {
        pull_request_id: ctx.pull_request_id,
        repository_id: ctx.repository_id,
        repository: ctx.repository_name,
        number: node.number,
        title,
        url: node.url,
        base_ref_name: node.base_ref_name,
        default_branch_name,
        backport_source,
        author_login,
        author_avatar_url,
        author_association: ReviewAuthorAssociation::parse(node.author_association.as_deref()),
        state: map_pull_request_state(node.state.as_deref()),
        mergeable: map_mergeable_state(node.mergeable.as_deref()),
        review_status: map_review_status(node.review_decision.as_deref()),
        check_status: ctx.check_summary.status(),
        flags: super::super::ReviewItemFlags {
            policy_blocked: ctx.check_summary.policy_blocked,
            is_draft: node.is_draft,
            viewer_can_update: node.viewer_can_update.unwrap_or(true),
            viewer_is_requested_reviewer,
        },
        viewer_can_merge_as_admin: node.viewer_can_merge_as_admin.unwrap_or(false),
        head_sha: node.head_ref_oid.unwrap_or_default(),
        labels: node.labels.nodes.into_iter().map(|l| l.name).collect(),
        checks: ctx.check_summary.checks,
        reviews: node
            .reviews
            .nodes
            .into_iter()
            .map(pull_request_review_from_node)
            .collect(),
        additions: node.additions.max(0).cast_unsigned(),
        deletions: node.deletions.max(0).cast_unsigned(),
        created_at: ctx.created_at,
        updated_at: ctx.updated_at,
        required_failed_check_names: ctx.required_failed_check_names,
        required_approving_review_count: Some(required_approving_review_count(
            node.base_ref.as_ref(),
        )),
        has_conflict_markers: None,
        viewer_has_active_approval: None,
        auto_merge_enabled: Some(node.auto_merge_request.is_some()),
        approval_requirement_satisfied_after_viewer_approval: None,
    }
}

pub(super) fn apply_policy_review_metadata(items: &mut [ReviewItem], viewer_login: Option<&str>) {
    for item in items {
        let latest_review_by_author = latest_review_by_author(&item.reviews);
        let active_approval_count = latest_review_by_author
            .values()
            .filter(|state| **state == ReviewReviewEventState::Approved)
            .count();
        let viewer_has_active_approval = viewer_login.is_some_and(|login| {
            latest_review_by_author
                .get(&login.to_ascii_lowercase())
                .is_some_and(|state| *state == ReviewReviewEventState::Approved)
        });
        item.viewer_has_active_approval = viewer_login.map(|_| viewer_has_active_approval);
        item.approval_requirement_satisfied_after_viewer_approval =
            approval_requirement_satisfied_after_viewer_approval(
                item.required_approving_review_count.unwrap_or(0),
                active_approval_count,
                viewer_login,
                viewer_has_active_approval,
            );
    }
}

fn latest_review_by_author(
    reviews: &[PullRequestReview],
) -> BTreeMap<String, ReviewReviewEventState> {
    let mut latest = BTreeMap::new();
    for review in reviews {
        let author = review.author.trim();
        if author.is_empty() {
            continue;
        }
        latest.insert(author.to_ascii_lowercase(), review.state);
    }
    latest
}

fn approval_requirement_satisfied_after_viewer_approval(
    required: u32,
    active_approval_count: usize,
    viewer_login: Option<&str>,
    viewer_has_active_approval: bool,
) -> Option<bool> {
    if required == 0 {
        return Some(true);
    }
    let viewer_login = viewer_login?;
    let viewer_addition =
        usize::from(!viewer_login.trim().is_empty() && !viewer_has_active_approval);
    Some(active_approval_count.saturating_add(viewer_addition) >= required as usize)
}

fn required_approving_review_count(base_ref: Option<&super::types::RefNode>) -> u32 {
    let Some(rule) = base_ref.and_then(|base| base.branch_protection_rule.as_ref()) else {
        return 0;
    };
    if rule.requires_approving_reviews == Some(false) {
        return 0;
    }
    rule.required_approving_review_count.unwrap_or(0)
}

pub(super) fn append_pull_request_labels(item: &mut ReviewItem, labels: Vec<LabelNode>) {
    item.labels
        .extend(labels.into_iter().map(|label| label.name));
}

pub(super) fn append_pull_request_reviews(item: &mut ReviewItem, reviews: Vec<ReviewNode>) {
    item.reviews
        .extend(reviews.into_iter().map(pull_request_review_from_node));
}

fn pull_request_review_from_node(review: ReviewNode) -> PullRequestReview {
    let state = map_review_event_state(review.state.as_deref());
    let (author, author_avatar_url) = review.author.map_or_else(
        || (String::new(), None),
        |author| (author.login.unwrap_or_default(), author.avatar_url),
    );
    PullRequestReview {
        author,
        author_avatar_url,
        state,
    }
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
    item.flags.policy_blocked = item.flags.policy_blocked || summary.policy_blocked;
    item.checks.extend(summary.checks);
    item.check_status = recompute_check_status(&item.checks);
    item.required_failed_check_names =
        required_failed_check_names(&item.checks, required_check_names);
}

pub(super) fn append_repository_labels(
    bundle: &mut Vec<ReviewRepositoryLabel>,
    labels: Vec<RepositoryLabelNode>,
) {
    bundle.extend(labels.into_iter().map(|label| ReviewRepositoryLabel {
        name: label.name,
        color: label.color.filter(|value| !value.is_empty()),
        description: label.description.filter(|value| !value.is_empty()),
    }));
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
            CliErrorKind::workflow_parse(format!("parse reviews timestamp '{value}': {error}"))
                .into()
        })
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
