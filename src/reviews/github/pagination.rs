use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::json;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};

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
use super::{ReviewItem, ReviewRepositoryLabel};

const INNER_PAGE_CAP: u32 = 10;

pub(super) async fn resolve_continuation(
    client: &GitHubProtectedClient,
    item: &mut ReviewItem,
    repository_labels: &mut BTreeMap<String, Vec<ReviewRepositoryLabel>>,
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
    client: &GitHubProtectedClient,
    item: &mut ReviewItem,
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
    client: &GitHubProtectedClient,
    item: &mut ReviewItem,
    cursor: InnerCursor,
) -> Result<(), CliError> {
    let mut after = cursor.after;
    let mut page = 1_u32;
    loop {
        let response: PullRequestLabelsPageResponse = client
            .graphql(
                page_descriptor("reviews.pr_labels_page"),
                json!({
                    "query": PR_LABELS_PAGE_QUERY,
                    "variables": { "id": item.pull_request_id, "after": after.as_deref() },
                }),
            )
            .await
            .map(|response| response.body)?;
        let Some(node) = response.node else {
            return Err(CliErrorKind::workflow_parse(format!(
                "reviews pull request '{}#{}' is no longer accessible",
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
            &format!("reviews labels for '{}#{}'", item.repository, item.number),
        )?;
        page += 1;
    }
}

async fn continue_pull_request_reviews(
    client: &GitHubProtectedClient,
    item: &mut ReviewItem,
    cursor: InnerCursor,
) -> Result<(), CliError> {
    let mut after = cursor.after;
    let mut page = 1_u32;
    loop {
        let response: PullRequestReviewsPageResponse = client
            .graphql(
                page_descriptor("reviews.pr_reviews_page"),
                json!({
                    "query": PR_REVIEWS_PAGE_QUERY,
                    "variables": { "id": item.pull_request_id, "after": after.as_deref() },
                }),
            )
            .await
            .map(|response| response.body)?;
        let Some(node) = response.node else {
            return Err(CliErrorKind::workflow_parse(format!(
                "reviews pull request '{}#{}' is no longer accessible",
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
            &format!("reviews reviews for '{}#{}'", item.repository, item.number),
        )?;
        page += 1;
    }
}

async fn continue_check_contexts(
    client: &GitHubProtectedClient,
    item: &mut ReviewItem,
    cursor: InnerCursor,
    required_check_names: &[String],
) -> Result<(), CliError> {
    let mut after = cursor.after;
    let mut page = 1_u32;
    loop {
        let response: PullRequestChecksPageResponse = client
            .graphql(
                page_descriptor("reviews.pr_checks_page"),
                json!({
                    "query": PR_CHECKS_PAGE_QUERY,
                    "variables": { "id": item.pull_request_id, "after": after.as_deref() },
                }),
            )
            .await
            .map(|response| response.body)?;
        let Some(node) = response.node else {
            return Err(CliErrorKind::workflow_parse(format!(
                "reviews pull request '{}#{}' is no longer accessible",
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
                "reviews check contexts for '{}#{}'",
                item.repository, item.number
            ),
        )?;
        page += 1;
    }
}

async fn continue_repository_labels(
    client: &GitHubProtectedClient,
    repository_id: &str,
    repository_name: &str,
    repository_labels: &mut BTreeMap<String, Vec<ReviewRepositoryLabel>>,
    cursor: InnerCursor,
) -> Result<(), CliError> {
    let mut after = cursor.after;
    let mut page = 1_u32;
    loop {
        let response: RepositoryLabelsPageResponse = client
            .graphql(
                page_descriptor("reviews.repository_labels_page"),
                json!({
                    "query": REPO_LABELS_PAGE_QUERY,
                    "variables": { "id": repository_id, "after": after.as_deref() },
                }),
            )
            .await
            .map(|response| response.body)?;
        let Some(node) = response.node else {
            return Err(CliErrorKind::workflow_parse(format!(
                "reviews repository '{repository_name}' is no longer accessible"
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
            &format!("reviews repository labels for '{repository_name}'"),
        )?;
        page += 1;
    }
}

fn page_descriptor(operation: &str) -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::graphql(
        operation,
        GitHubPriority::Background,
        GitHubCachePolicy::read_through(Duration::from_mins(5), Duration::from_mins(60)),
    )
    .with_expected_cost(10)
}
