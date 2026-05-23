use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use chrono::{DateTime, Utc};
use serde_json::json;

use crate::daemon::service::BlobTextProjection;
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::files::blob::blob_exceeds_cap;
use crate::reviews::files::patch_rest::split_repo_full_name;

use super::client::{ReviewsGitHubClient, normalize_git_blob_base64};
use super::errors::operation_error;
use super::mapping::parse_timestamp;
use super::queries::{self, PULL_REQUEST_BODY_QUERY, UPDATE_PULL_REQUEST_BODY_MUTATION};
use super::types::{PullRequestBodyResponse, UpdatePullRequestBodyResponse};

impl ReviewsGitHubClient {
    pub(crate) async fn fetch_pull_request_files(
        &self,
        request: &super::super::ReviewsFilesListRequest,
    ) -> Result<super::super::ReviewsFilesListResponse, CliError> {
        super::super::files::list::fetch_files(&self.client, request, Utc::now())
            .await
            .map_err(|err| {
                CliErrorKind::workflow_io(format!("reviews files list: {err}")).into()
            })
    }

    /// Run a `markFileAsViewed` or `unmarkFileAsViewed` GraphQL mutation
    /// against one (pullRequestId, path) pair. The mutation response is
    /// inspected only for success/failure; daemon-side drift detection
    /// happens before this method is called.
    pub(crate) async fn toggle_pull_request_file_viewed(
        &self,
        pull_request_id: &str,
        path: &str,
        mark_viewed: bool,
    ) -> Result<(), CliError> {
        let query = if mark_viewed {
            queries::MARK_PR_FILE_AS_VIEWED_MUTATION
        } else {
            queries::UNMARK_PR_FILE_AS_VIEWED_MUTATION
        };
        self.client
            .graphql::<serde_json::Value>(&json!({
                "query": query,
                "variables": {
                    "pullRequestId": pull_request_id,
                    "path": path,
                },
            }))
            .await
            .map(|_| ())
            .map_err(operation_error)
    }

    /// Fetch the text payload of one blob via GraphQL. Returns
    /// `(content_base64, byte_size, is_truncated, is_too_large)`. Binary blobs
    /// return empty content (`text == null` on the GraphQL side);
    /// callers should fall through to a REST raw-bytes fetch when the
    /// `byte_size` is non-zero but the content is empty.
    pub(crate) async fn fetch_repository_blob_text(
        &self,
        repository_id: &str,
        oid: &str,
    ) -> Result<BlobTextProjection, CliError> {
        #[derive(Debug, serde::Deserialize)]
        struct RepositoryBlobResponse {
            node: Option<RepositoryBlobNode>,
        }
        #[derive(Debug, serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct RepositoryBlobNode {
            name_with_owner: Option<String>,
            object: Option<RepositoryBlobObject>,
        }
        #[derive(Debug, serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct RepositoryBlobObject {
            byte_size: Option<u64>,
            text: Option<String>,
            is_truncated: Option<bool>,
        }
        let response: RepositoryBlobResponse = self
            .client
            .graphql(&json!({
                "query": queries::REPOSITORY_BLOB_QUERY,
                "variables": {
                    "id": repository_id,
                    "expression": oid,
                },
            }))
            .await
            .map_err(operation_error)?;
        let node = response.node.ok_or_else(|| {
            CliErrorKind::workflow_parse(format!(
                "reviews blob '{oid}' was not found in repository '{repository_id}'"
            ))
        })?;
        let repository_full_name = node.name_with_owner;
        let blob = node.object.ok_or_else(|| {
            CliErrorKind::workflow_parse(format!(
                "reviews blob '{oid}' was not found in repository '{repository_id}'"
            ))
        })?;
        let byte_size = blob.byte_size.unwrap_or_default();
        let is_too_large = blob_exceeds_cap(byte_size);
        let content_base64 = blob
            .text
            .as_deref()
            .filter(|_| !is_too_large)
            .map(|text| BASE64_STANDARD.encode(text.as_bytes()))
            .unwrap_or_default();
        let is_truncated = blob.is_truncated.unwrap_or_default();
        Ok(BlobTextProjection {
            repository_full_name,
            content_base64,
            byte_size,
            is_truncated,
            is_too_large,
        })
    }

    /// Fetch one git blob through GitHub REST and return its base64 payload.
    /// Used as the binary-image fallback after GraphQL has resolved the
    /// repository `nameWithOwner`.
    pub(crate) async fn fetch_repository_blob_base64(
        &self,
        repo_full_name: &str,
        oid: &str,
    ) -> Result<BlobTextProjection, CliError> {
        #[derive(Debug, serde::Deserialize)]
        struct GitBlobResponse {
            content: String,
            encoding: String,
            size: u64,
        }

        let (owner, repo) =
            split_repo_full_name(repo_full_name)
                .ok_or_else(|| {
                    CliErrorKind::workflow_parse(format!(
                        "reviews blob: repository '{repo_full_name}' is not owner/name"
                    ))
                })?;
        let route = format!("/repos/{owner}/{repo}/git/blobs/{oid}");
        let blob: GitBlobResponse = self
            .client
            .get(route, None::<&()>)
            .await
            .map_err(operation_error)?;
        if !blob.encoding.eq_ignore_ascii_case("base64") {
            return Err(CliErrorKind::workflow_parse(format!(
                "reviews blob '{oid}' returned unsupported encoding '{}'",
                blob.encoding
            ))
            .into());
        }
        let is_too_large = blob_exceeds_cap(blob.size);
        let content_base64 = if is_too_large {
            String::new()
        } else {
            normalize_git_blob_base64(&blob.content)
        };
        Ok(BlobTextProjection {
            repository_full_name: Some(repo_full_name.to_string()),
            content_base64,
            byte_size: blob.size,
            is_truncated: false,
            is_too_large,
        })
    }

    pub(crate) async fn fetch_pull_request_body(
        &self,
        pull_request_id: &str,
    ) -> Result<(String, DateTime<Utc>), CliError> {
        let response: PullRequestBodyResponse = self
            .client
            .graphql(&json!({
                "query": PULL_REQUEST_BODY_QUERY,
                "variables": { "id": pull_request_id },
            }))
            .await
            .map_err(operation_error)?;
        let node = response.node.ok_or_else(|| {
            CliErrorKind::workflow_parse(format!(
                "reviews pull request '{pull_request_id}' was not found or is not accessible"
            ))
        })?;
        let updated_at = parse_timestamp(node.updated_at.as_str())?;
        Ok((node.body.unwrap_or_default(), updated_at))
    }

    pub(crate) async fn update_pull_request_body(
        &self,
        pull_request_id: &str,
        body: &str,
    ) -> Result<(String, DateTime<Utc>), CliError> {
        let response: UpdatePullRequestBodyResponse = self
            .client
            .graphql(&json!({
                "query": UPDATE_PULL_REQUEST_BODY_MUTATION,
                "variables": { "id": pull_request_id, "body": body },
            }))
            .await
            .map_err(operation_error)?;
        let node = response
            .update_pull_request
            .and_then(|payload| payload.pull_request)
            .ok_or_else(|| {
                CliErrorKind::workflow_parse(format!(
                    "reviews pull request '{pull_request_id}' rejected the body update"
                ))
            })?;
        let updated_at = parse_timestamp(node.updated_at.as_str())?;
        Ok((node.body.unwrap_or_default(), updated_at))
    }
}
