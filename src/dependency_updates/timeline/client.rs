#![allow(dead_code)]

use std::time::Duration;

use async_trait::async_trait;
use octocrab::Octocrab;
use serde_json::{Value, json};

use super::queries::{
    LIST_PR_REVIEW_COMMENTS_QUERY, LIST_PR_REVIEW_THREAD_COMMENTS_QUERY, PR_TIMELINE_PAGE_QUERY,
};
use super::{TimelineClient, TimelineError};
use crate::errors::{CliError, CliErrorKind};

const TIMELINE_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const TIMELINE_READ_TIMEOUT: Duration = Duration::from_secs(60);

pub(crate) struct TimelineGitHubClient {
    client: Octocrab,
}

impl TimelineGitHubClient {
    pub(crate) fn new(token: &str) -> Result<Self, CliError> {
        let token = token.trim();
        if token.is_empty() {
            return Err(CliErrorKind::workflow_io("timeline github client token missing").into());
        }
        let client = Octocrab::builder()
            .personal_token(token.to_string())
            .set_connect_timeout(Some(TIMELINE_CONNECT_TIMEOUT))
            .set_read_timeout(Some(TIMELINE_READ_TIMEOUT))
            .build()
            .map_err(|err| -> CliError {
                CliErrorKind::workflow_io(format!("timeline github client build: {err}")).into()
            })?;
        Ok(Self { client })
    }
}

fn graphql_err(err: octocrab::Error) -> TimelineError {
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
            .graphql::<Value>(&json!({
                "query": PR_TIMELINE_PAGE_QUERY,
                "variables": variables,
            }))
            .await
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
            .graphql::<Value>(&json!({
                "query": LIST_PR_REVIEW_COMMENTS_QUERY,
                "variables": variables,
            }))
            .await
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
            .graphql::<Value>(&json!({
                "query": LIST_PR_REVIEW_THREAD_COMMENTS_QUERY,
                "variables": variables,
            }))
            .await
            .map_err(graphql_err)
    }
}
