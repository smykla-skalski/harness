use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::github_api::{
    GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRequestDescriptor,
};

use super::queries::{
    LIST_PR_REVIEW_COMMENTS_QUERY, LIST_PR_REVIEW_THREAD_COMMENTS_QUERY, PR_TIMELINE_PAGE_QUERY,
};
use super::{TimelineClient, TimelineError};
use crate::errors::{CliError, CliErrorKind};

pub(crate) struct TimelineGitHubClient {
    client: GitHubProtectedClient,
}

impl TimelineGitHubClient {
    pub(crate) fn new(token: &str) -> Result<Self, CliError> {
        let token = token.trim();
        if token.is_empty() {
            return Err(CliErrorKind::workflow_io("timeline github client token missing").into());
        }
        let client = GitHubProtectedClient::new(token).map_err(|err| -> CliError {
            CliErrorKind::workflow_io(format!("timeline github client build: {err}")).into()
        })?;
        Ok(Self { client })
    }
}

fn graphql_err(err: CliError) -> TimelineError {
    let text = err.to_string();
    if text.contains("rate limit") || text.contains("API rate limit") {
        TimelineError::RateLimited
    } else {
        TimelineError::Client(text)
    }
}

#[async_trait]
impl TimelineClient for TimelineGitHubClient {
    async fn fetch_timeline_page_query(
        &self,
        pull_request_id: &str,
        page_size: u32,
        cursor: Option<&str>,
        inline_comment_page_size: u32,
        thread_comment_page_size: u32,
    ) -> Result<Value, TimelineError> {
        let mut variables = json!({
            "pullRequestID": pull_request_id,
            "pageSize": page_size,
            "inlineCommentPageSize": inline_comment_page_size,
            "threadCommentPageSize": thread_comment_page_size,
        });
        if let Some(c) = cursor {
            variables["cursor"] = Value::String(c.to_string());
        }
        self.client
            .graphql(
                timeline_descriptor("reviews.timeline_page"),
                json!({
                    "query": PR_TIMELINE_PAGE_QUERY,
                    "variables": variables,
                }),
            )
            .await
            .map(|response| response.body)
            .map_err(graphql_err)
    }

    async fn list_review_comments(
        &self,
        review_id: &str,
        page_size: u32,
        cursor: Option<&str>,
    ) -> Result<Value, TimelineError> {
        let mut variables = json!({
            "reviewID": review_id,
            "pageSize": page_size,
        });
        if let Some(c) = cursor {
            variables["cursor"] = Value::String(c.to_string());
        }
        self.client
            .graphql(
                timeline_descriptor("reviews.timeline_review_comments"),
                json!({
                    "query": LIST_PR_REVIEW_COMMENTS_QUERY,
                    "variables": variables,
                }),
            )
            .await
            .map(|response| response.body)
            .map_err(graphql_err)
    }

    async fn list_review_thread_comments(
        &self,
        thread_id: &str,
        page_size: u32,
        cursor: Option<&str>,
    ) -> Result<Value, TimelineError> {
        let mut variables = json!({
            "threadID": thread_id,
            "pageSize": page_size,
        });
        if let Some(c) = cursor {
            variables["cursor"] = Value::String(c.to_string());
        }
        self.client
            .graphql(
                timeline_descriptor("reviews.timeline_thread_comments"),
                json!({
                    "query": LIST_PR_REVIEW_THREAD_COMMENTS_QUERY,
                    "variables": variables,
                }),
            )
            .await
            .map(|response| response.body)
            .map_err(graphql_err)
    }
}

fn timeline_descriptor(operation: &str) -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::graphql(
        operation,
        GitHubPriority::NormalRead,
        GitHubCachePolicy::read_through(Duration::from_mins(5), Duration::from_mins(60)),
    )
    .with_expected_cost(10)
}
