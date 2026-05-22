use std::collections::BTreeMap;
use std::sync::OnceLock;
use std::time::Duration;

use octocrab::Octocrab;
use rustls::crypto::ring::default_provider;

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::GitHubApiAutomationClient;

use super::super::{ReviewItem, ReviewRepositoryLabel};
use super::errors::client_error;

pub(in crate::reviews) const GITHUB_HTTP_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
pub(in crate::reviews) const GITHUB_HTTP_READ_TIMEOUT: Duration = Duration::from_secs(60);

pub(in crate::reviews) const GRAPHQL_PAGE_SIZE: u32 = 100;
pub(in crate::reviews) const SEARCH_PAGE_CAP: u32 = 10;
pub(in crate::reviews) const REPOSITORY_CATALOG_PAGE_CAP: u32 = 5;
pub(in crate::reviews) const SCOPE_QUERY_CAP: usize = 50;
pub(in crate::reviews) const NODES_BATCH_SIZE: usize = 50;

static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

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
    pub(super) client: Octocrab,
    pub(super) automation: GitHubApiAutomationClient,
}

impl ReviewsGitHubClient {
    /// Borrow the underlying Octocrab client. Used by the REST patch
    /// fetcher in `reviews::files::patch_rest`, which needs
    /// raw `pulls/<n>/files` access alongside the higher-level helpers
    /// on this struct.
    pub(crate) fn octocrab(&self) -> &Octocrab {
        &self.client
    }

    pub(crate) fn new(token: &str) -> Result<Self, CliError> {
        let token = token.trim();
        if token.is_empty() {
            return Err(
                CliErrorKind::workflow_io("reviews github token missing").into(),
            );
        }
        ensure_rustls_provider();
        let client = Octocrab::builder()
            .personal_token(token.to_string())
            .set_connect_timeout(Some(GITHUB_HTTP_CONNECT_TIMEOUT))
            .set_read_timeout(Some(GITHUB_HTTP_READ_TIMEOUT))
            .build()
            .map_err(client_error)?;
        let automation = GitHubApiAutomationClient::new(token)?;
        Ok(Self { client, automation })
    }
}

pub(super) fn normalize_git_blob_base64(content: &str) -> String {
    content.chars().filter(|c| !c.is_whitespace()).collect()
}

pub(crate) fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(|| {
        let _ = default_provider().install_default();
    });
}
