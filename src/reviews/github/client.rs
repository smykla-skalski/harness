use std::collections::BTreeMap;
#[cfg(test)]
use std::time::Duration;

use crate::errors::{CliError, CliErrorKind};
use crate::github_api::GitHubProtectedClient;
use crate::task_board::github::GitHubApiAutomationClient;

use super::super::{ReviewItem, ReviewRepositoryLabel};

#[cfg(test)]
pub(in crate::reviews) const GITHUB_HTTP_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
#[cfg(test)]
pub(in crate::reviews) const GITHUB_HTTP_READ_TIMEOUT: Duration = Duration::from_mins(1);

pub(in crate::reviews) const GRAPHQL_PAGE_SIZE: u32 = 100;
pub(in crate::reviews) const SEARCH_PAGE_CAP: u32 = 10;
pub(in crate::reviews) const REPOSITORY_CATALOG_PAGE_CAP: u32 = 5;
pub(in crate::reviews) const SCOPE_QUERY_CAP: usize = 50;
pub(in crate::reviews) const NODES_BATCH_SIZE: usize = 50;

pub(crate) struct ReviewsFetch {
    pub items: Vec<ReviewItem>,
    pub repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
}

pub(crate) struct ReviewsFetchByIds {
    pub items: Vec<ReviewItem>,
    pub missing: Vec<String>,
    pub repository_labels: BTreeMap<String, Vec<ReviewRepositoryLabel>>,
}

pub(crate) struct ReviewsGitHubClient {
    pub(super) client: GitHubProtectedClient,
    pub(super) automation: GitHubApiAutomationClient,
}

impl ReviewsGitHubClient {
    pub(crate) const fn protected(&self) -> &GitHubProtectedClient {
        &self.client
    }

    pub(crate) fn new(token: &str) -> Result<Self, CliError> {
        let token = token.trim();
        if token.is_empty() {
            return Err(CliErrorKind::workflow_io("reviews github token missing").into());
        }
        let client = GitHubProtectedClient::new(token)?;
        let automation = GitHubApiAutomationClient::new(token)?;
        Ok(Self { client, automation })
    }
}

pub(super) fn normalize_git_blob_base64(content: &str) -> String {
    content.chars().filter(|c| !c.is_whitespace()).collect()
}
