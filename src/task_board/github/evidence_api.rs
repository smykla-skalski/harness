use std::collections::{BTreeMap, BTreeSet};

use octocrab::{Error as OctocrabError, Octocrab};
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api_errors;

use super::config::GitHubProjectConfig;
use super::evidence::{
    GitHubBranchProtectionEvidence, GitHubCheckEvidence, GitHubMergeEvidence,
    GitHubPullRequestEvidence, GitHubReviewEvidence, GitHubReviewState,
};

mod types;

use types::{
    CHECKS_PAGE_QUERY, FILES_PAGE_QUERY, GitHubGraphqlPageInfo, GitHubReviewRollup,
    GitHubReviewThreadSummary, GraphqlBranchProtectionRule, GraphqlPullRequest,
    GraphqlPullRequestPage, GraphqlPullRequestReview, GraphqlRef, GraphqlStatusCheckContext,
    GraphqlStatusContext, PULL_REQUEST_MERGE_EVIDENCE_QUERY, PullRequestMergeEvidenceResponse,
    PullRequestPageResponse, REVIEWS_PAGE_QUERY, THREADS_PAGE_QUERY,
};

const GRAPHQL_PAGE_LIMIT: u32 = 20;

pub(super) async fn pull_request_merge_evidence(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
) -> Result<GitHubMergeEvidence, CliError> {
    let response: PullRequestMergeEvidenceResponse = client
        .graphql(&json!({
            "query": PULL_REQUEST_MERGE_EVIDENCE_QUERY,
            "variables": {
                "owner": config.owner.as_str(),
                "repo": config.repo.as_str(),
                "number": pull_request_number,
            },
        }))
        .await
        .map_err(operation_error)?;
    let pull_request = response
        .pull_request()
        .ok_or_else(|| missing_pull_request_error(config, pull_request_number))?;
    let mut checks = head_commit_checks(&pull_request);
    let check_page_info = head_commit_check_page_info(&pull_request);
    let merge_allowed = pull_request_merge_allowed(&pull_request);

    let files_page = pull_request.files;
    let mut changed_paths = files_page
        .nodes
        .into_iter()
        .map(|file| file.path)
        .collect::<Vec<_>>();
    load_remaining_changed_paths(
        client,
        config,
        pull_request_number,
        files_page.page_info,
        &mut changed_paths,
    )
    .await?;

    let reviews_page = pull_request.reviews;
    let mut reviews = reviews_page
        .nodes
        .into_iter()
        .filter_map(GraphqlPullRequestReview::into_rollup)
        .collect::<Vec<_>>();
    load_remaining_reviews(
        client,
        config,
        pull_request_number,
        reviews_page.page_info,
        &mut reviews,
    )
    .await?;

    let threads_page = pull_request.review_threads;
    let mut thread_summary = GitHubReviewThreadSummary::default();
    thread_summary.add_threads(threads_page.nodes);
    load_remaining_review_threads(
        client,
        config,
        pull_request_number,
        threads_page.page_info,
        &mut thread_summary,
    )
    .await?;

    if let Some(page_info) = check_page_info {
        load_remaining_check_contexts(client, config, pull_request_number, page_info, &mut checks)
            .await?;
    }

    let branch_protection = branch_protection_evidence(pull_request.base_ref, merge_allowed);

    Ok(GitHubMergeEvidence {
        pull_request: GitHubPullRequestEvidence {
            number: pull_request.number,
            html_url: Some(pull_request.url),
            base_branch: pull_request.base_ref_name,
            head_branch: pull_request.head_ref_name,
            draft: pull_request.is_draft,
            changed_paths,
        },
        checks: merge_check_evidence(checks),
        reviews: merge_review_rollups(reviews, &thread_summary.unresolved_by_reviewer),
        branch_protection,
    })
}

async fn load_remaining_changed_paths(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
    mut page_info: GitHubGraphqlPageInfo,
    paths: &mut Vec<String>,
) -> Result<(), CliError> {
    let mut pages = 1_u32;
    while page_info.has_next_page {
        let cursor = next_cursor(&page_info, "pull request files")?;
        page_limit("pull request files", pages)?;
        let page = query_page(
            client,
            config,
            pull_request_number,
            &cursor,
            FILES_PAGE_QUERY,
        )
        .await?
        .files
        .ok_or_else(|| missing_page_error("pull request files"))?;
        paths.extend(page.nodes.into_iter().map(|file| file.path));
        page_info = page.page_info;
        pages += 1;
    }
    Ok(())
}

async fn load_remaining_reviews(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
    mut page_info: GitHubGraphqlPageInfo,
    reviews: &mut Vec<GitHubReviewRollup>,
) -> Result<(), CliError> {
    let mut pages = 1_u32;
    while page_info.has_next_page {
        let cursor = next_cursor(&page_info, "pull request reviews")?;
        page_limit("pull request reviews", pages)?;
        let page = query_page(
            client,
            config,
            pull_request_number,
            &cursor,
            REVIEWS_PAGE_QUERY,
        )
        .await?
        .reviews
        .ok_or_else(|| missing_page_error("pull request reviews"))?;
        reviews.extend(
            page.nodes
                .into_iter()
                .filter_map(GraphqlPullRequestReview::into_rollup),
        );
        page_info = page.page_info;
        pages += 1;
    }
    Ok(())
}

async fn load_remaining_review_threads(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
    mut page_info: GitHubGraphqlPageInfo,
    summary: &mut GitHubReviewThreadSummary,
) -> Result<(), CliError> {
    let mut pages = 1_u32;
    while page_info.has_next_page {
        let cursor = next_cursor(&page_info, "pull request review threads")?;
        page_limit("pull request review threads", pages)?;
        let page = query_page(
            client,
            config,
            pull_request_number,
            &cursor,
            THREADS_PAGE_QUERY,
        )
        .await?
        .review_threads
        .ok_or_else(|| missing_page_error("pull request review threads"))?;
        summary.add_threads(page.nodes);
        page_info = page.page_info;
        pages += 1;
    }
    Ok(())
}

async fn load_remaining_check_contexts(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
    mut page_info: GitHubGraphqlPageInfo,
    checks: &mut Vec<GitHubCheckEvidence>,
) -> Result<(), CliError> {
    let mut pages = 1_u32;
    while page_info.has_next_page {
        let cursor = next_cursor(&page_info, "head commit check contexts")?;
        page_limit("head commit check contexts", pages)?;
        let page = query_page(
            client,
            config,
            pull_request_number,
            &cursor,
            CHECKS_PAGE_QUERY,
        )
        .await?
        .head_check_contexts()
        .ok_or_else(|| missing_page_error("head commit check contexts"))?;
        checks.extend(
            page.nodes
                .into_iter()
                .filter_map(|context| context.evidence()),
        );
        page_info = page.page_info;
        pages += 1;
    }
    Ok(())
}

async fn query_page(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    pull_request_number: u64,
    cursor: &str,
    query: &str,
) -> Result<GraphqlPullRequestPage, CliError> {
    let response: PullRequestPageResponse = client
        .graphql(&json!({
            "query": query,
            "variables": {
                "owner": config.owner.as_str(),
                "repo": config.repo.as_str(),
                "number": pull_request_number,
                "after": cursor,
            },
        }))
        .await
        .map_err(operation_error)?;
    response
        .pull_request()
        .ok_or_else(|| missing_pull_request_error(config, pull_request_number))
}

fn head_commit_checks(pull_request: &GraphqlPullRequest) -> Vec<GitHubCheckEvidence> {
    let Some(commit) = pull_request.head_commit() else {
        return Vec::new();
    };
    let mut checks = commit
        .status
        .as_ref()
        .map(|status| {
            status
                .contexts
                .iter()
                .map(GraphqlStatusContext::evidence)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if let Some(rollup) = commit.status_check_rollup.as_ref() {
        checks.extend(
            rollup
                .contexts
                .nodes
                .iter()
                .filter_map(GraphqlStatusCheckContext::evidence),
        );
    }
    checks
}

fn head_commit_check_page_info(pull_request: &GraphqlPullRequest) -> Option<GitHubGraphqlPageInfo> {
    pull_request
        .head_commit()
        .and_then(|commit| commit.status_check_rollup.as_ref())
        .map(|rollup| rollup.contexts.page_info.clone())
}

fn branch_protection_evidence(
    base_ref: Option<GraphqlRef>,
    merge_allowed: bool,
) -> GitHubBranchProtectionEvidence {
    let Some(rule) = base_ref.and_then(|base_ref| base_ref.branch_protection_rule) else {
        return GitHubBranchProtectionEvidence {
            enabled: false,
            merge_allowed,
            required_checks: Vec::new(),
        };
    };
    GitHubBranchProtectionEvidence {
        enabled: true,
        merge_allowed,
        required_checks: required_check_names(&rule),
    }
}

fn required_check_names(rule: &GraphqlBranchProtectionRule) -> Vec<String> {
    let mut required = BTreeSet::new();
    for context in &rule.required_status_check_contexts {
        required.insert(context.clone());
    }
    for check in &rule.required_status_checks {
        required.insert(check.context.clone());
    }
    required.into_iter().collect()
}

fn pull_request_merge_allowed(pull_request: &GraphqlPullRequest) -> bool {
    pull_request.mergeable == "MERGEABLE"
        && !pull_request.is_draft
        && !matches!(
            pull_request.merge_state_status.as_deref(),
            Some("BEHIND" | "BLOCKED" | "DIRTY" | "DRAFT" | "UNKNOWN")
        )
}

fn merge_check_evidence(checks: Vec<GitHubCheckEvidence>) -> Vec<GitHubCheckEvidence> {
    let mut merged = BTreeMap::new();
    for check in checks {
        merged.insert(check.name.clone(), check);
    }
    merged.into_values().collect()
}

fn merge_review_rollups(
    mut reviews: Vec<GitHubReviewRollup>,
    unresolved_threads: &BTreeMap<String, u32>,
) -> Vec<GitHubReviewEvidence> {
    reviews.sort_by(|left, right| left.submitted_at.cmp(&right.submitted_at));
    let mut merged: BTreeMap<String, GitHubReviewEvidence> = BTreeMap::new();
    for review in reviews {
        let unresolved_requested_changes = match review.state {
            GitHubReviewState::ChangesRequested => unresolved_threads
                .get(&review.reviewer)
                .copied()
                .unwrap_or(1),
            _ => unresolved_threads
                .get(&review.reviewer)
                .copied()
                .unwrap_or(0),
        };
        merged.insert(
            review.reviewer.clone(),
            GitHubReviewEvidence {
                reviewer: review.reviewer,
                state: review.state,
                unresolved_requested_changes,
            },
        );
    }
    merged.into_values().collect()
}

fn next_cursor(page_info: &GitHubGraphqlPageInfo, page: &str) -> Result<String, CliError> {
    page_info
        .end_cursor
        .clone()
        .ok_or_else(|| CliErrorKind::workflow_io(format!("{page} missing GraphQL cursor")).into())
}

fn page_limit(page: &str, loaded_pages: u32) -> Result<(), CliError> {
    if loaded_pages < GRAPHQL_PAGE_LIMIT {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "{page} exceeded {GRAPHQL_PAGE_LIMIT} GitHub GraphQL pages"
    ))
    .into())
}

fn missing_page_error(page: &str) -> CliError {
    CliErrorKind::workflow_io(format!("{page} missing from GitHub GraphQL response")).into()
}

fn missing_pull_request_error(config: &GitHubProjectConfig, pull_request_number: u64) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board github pull request not found: {}/{}#{}",
        config.owner, config.repo, pull_request_number
    ))
    .into()
}

fn operation_error(error: OctocrabError) -> CliError {
    github_api_errors::operation_error("task-board github automation failed", error)
}

#[cfg(test)]
mod tests;
