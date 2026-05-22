use std::collections::BTreeMap;

use octocrab::Octocrab;
use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api_errors;

use super::mapping::{
    InnerCursor, NodeContinuation, append_check_contexts, append_pull_request_labels,
    append_pull_request_reviews, append_repository_labels, next_cursor_or_scope_limit,
};
use super::queries::{
    PR_CHECKS_PAGE_QUERY, PR_LABELS_PAGE_QUERY, PR_REVIEWS_PAGE_QUERY, REPO_LABELS_PAGE_QUERY,
};
use super::types::{
    PullRequestChecksPageResponse, PullRequestLabelsPageResponse, PullRequestReviewsPageResponse,
    RepositoryLabelsPageResponse,
};
use super::{DependencyUpdateItem, DependencyUpdateRepositoryLabel};

const INNER_PAGE_CAP: u32 = 10;

pub(super) async fn resolve_continuation(
    client: &Octocrab,
    item: &mut DependencyUpdateItem,
    repository_labels: &mut BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
    continuation: NodeContinuation,
) -> Result<(), CliError> {
    let NodeContinuation {
        repository_id,
        pr_labels,
        reviews,
        checks,
        repository_labels: repo_labels_cursor,
        required_check_names,
        ..
    } = continuation;
    resolve_pull_request_pages(
        client,
        item,
        pr_labels,
        reviews,
        checks,
        &required_check_names,
    )
    .await?;
    if let Some(cursor) = repo_labels_cursor {
        continue_repository_labels(
            client,
            &repository_id,
            &item.repository,
            repository_labels,
            cursor,
        )
        .await?;
    }
    Ok(())
}

async fn resolve_pull_request_pages(
    client: &Octocrab,
    item: &mut DependencyUpdateItem,
    pr_labels: Option<InnerCursor>,
    reviews: Option<InnerCursor>,
    checks: Option<InnerCursor>,
    required_check_names: &[String],
) -> Result<(), CliError> {
    if let Some(cursor) = pr_labels {
        continue_pull_request_labels(client, item, cursor).await?;
    }
    if let Some(cursor) = reviews {
        continue_pull_request_reviews(client, item, cursor).await?;
    }
    if let Some(cursor) = checks {
        continue_check_contexts(client, item, cursor, required_check_names).await?;
    }
    Ok(())
}

async fn continue_pull_request_labels(
    client: &Octocrab,
    item: &mut DependencyUpdateItem,
    cursor: InnerCursor,
) -> Result<(), CliError> {
    let mut after = cursor.after;
    let mut page = 1_u32;
    loop {
        let response: PullRequestLabelsPageResponse = client
            .graphql(&json!({
                "query": PR_LABELS_PAGE_QUERY,
                "variables": { "id": item.pull_request_id, "after": after.as_deref() },
            }))
            .await
            .map_err(operation_error)?;
        let Some(node) = response.node else {
            return Err(CliErrorKind::workflow_parse(format!(
                "dependency-updates pull request '{}#{}' is no longer accessible",
                item.repository, item.number
            ))
            .into());
        };
        let page_info = node.labels.page_info;
        append_pull_request_labels(item, node.labels.nodes);
        if !page_info.has_next_page {
            return Ok(());
        }
        after = next_cursor_or_scope_limit(
            &page_info,
            page,
            INNER_PAGE_CAP,
            &format!(
                "dependency-updates labels for '{}#{}'",
                item.repository, item.number
            ),
        )?;
        page += 1;
    }
}

async fn continue_pull_request_reviews(
    client: &Octocrab,
    item: &mut DependencyUpdateItem,
    cursor: InnerCursor,
) -> Result<(), CliError> {
    let mut after = cursor.after;
    let mut page = 1_u32;
    loop {
        let response: PullRequestReviewsPageResponse = client
            .graphql(&json!({
                "query": PR_REVIEWS_PAGE_QUERY,
                "variables": { "id": item.pull_request_id, "after": after.as_deref() },
            }))
            .await
            .map_err(operation_error)?;
        let Some(node) = response.node else {
            return Err(CliErrorKind::workflow_parse(format!(
                "dependency-updates pull request '{}#{}' is no longer accessible",
                item.repository, item.number
            ))
            .into());
        };
        let page_info = node.reviews.page_info;
        append_pull_request_reviews(item, node.reviews.nodes);
        if !page_info.has_next_page {
            return Ok(());
        }
        after = next_cursor_or_scope_limit(
            &page_info,
            page,
            INNER_PAGE_CAP,
            &format!(
                "dependency-updates reviews for '{}#{}'",
                item.repository, item.number
            ),
        )?;
        page += 1;
    }
}

async fn continue_check_contexts(
    client: &Octocrab,
    item: &mut DependencyUpdateItem,
    cursor: InnerCursor,
    required_check_names: &[String],
) -> Result<(), CliError> {
    let mut after = cursor.after;
    let mut page = 1_u32;
    loop {
        let response: PullRequestChecksPageResponse = client
            .graphql(&json!({
                "query": PR_CHECKS_PAGE_QUERY,
                "variables": { "id": item.pull_request_id, "after": after.as_deref() },
            }))
            .await
            .map_err(operation_error)?;
        let Some(node) = response.node else {
            return Err(CliErrorKind::workflow_parse(format!(
                "dependency-updates pull request '{}#{}' is no longer accessible",
                item.repository, item.number
            ))
            .into());
        };
        let Some(rollup) = node
            .commits
            .nodes
            .into_iter()
            .last()
            .and_then(|node| node.commit)
            .and_then(|commit| commit.status_check_rollup)
        else {
            return Ok(());
        };
        let page_info = rollup.contexts.page_info;
        append_check_contexts(item, rollup.contexts.nodes, required_check_names);
        if !page_info.has_next_page {
            return Ok(());
        }
        after = next_cursor_or_scope_limit(
            &page_info,
            page,
            INNER_PAGE_CAP,
            &format!(
                "dependency-updates check contexts for '{}#{}'",
                item.repository, item.number
            ),
        )?;
        page += 1;
    }
}

async fn continue_repository_labels(
    client: &Octocrab,
    repository_id: &str,
    repository_name: &str,
    repository_labels: &mut BTreeMap<String, Vec<DependencyUpdateRepositoryLabel>>,
    cursor: InnerCursor,
) -> Result<(), CliError> {
    let mut after = cursor.after;
    let mut page = 1_u32;
    loop {
        let response: RepositoryLabelsPageResponse = client
            .graphql(&json!({
                "query": REPO_LABELS_PAGE_QUERY,
                "variables": { "id": repository_id, "after": after.as_deref() },
            }))
            .await
            .map_err(operation_error)?;
        let Some(node) = response.node else {
            return Err(CliErrorKind::workflow_parse(format!(
                "dependency-updates repository '{repository_name}' is no longer accessible"
            ))
            .into());
        };
        let bundle_key = if node.name_with_owner.is_empty() {
            repository_name.to_string()
        } else {
            node.name_with_owner
        };
        let entry = repository_labels.entry(bundle_key).or_default();
        let page_info = node.labels.page_info;
        append_repository_labels(entry, node.labels.nodes);
        if !page_info.has_next_page {
            return Ok(());
        }
        after = next_cursor_or_scope_limit(
            &page_info,
            page,
            INNER_PAGE_CAP,
            &format!("dependency-updates repository labels for '{repository_name}'"),
        )?;
        page += 1;
    }
}

fn operation_error(error: octocrab::Error) -> CliError {
    github_api_errors::operation_error("dependency-updates github request failed", error)
}
