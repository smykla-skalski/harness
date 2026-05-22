//! Image-preview blob fetch endpoint.

use serde::Deserialize;

use crate::errors::{CliError, CliErrorKind};
use crate::reviews::{
    ReviewImageMime, ReviewsFilesBlobRequest, ReviewsFilesBlobResponse, ReviewsGitHubClient,
};
use crate::workspace::utc_now;

use super::token::{github_token, missing_token_error};

/// Lightweight projection of one GraphQL blob fetch. Lives here (not on
/// the client) so the handler can decode both text and base64-text bodies
/// uniformly.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub(crate) struct BlobTextProjection {
    #[serde(default)]
    pub repository_full_name: Option<String>,
    pub content_base64: String,
    pub byte_size: u64,
    pub is_truncated: bool,
    pub is_too_large: bool,
}

/// Fetch an image blob's bytes for inline preview.
///
/// GraphQL covers text-encodable blobs such as SVG. Binary PNG/JPG/GIF blobs
/// return `text = null`, so the handler falls back to GitHub's git-blob REST
/// endpoint using the repository `nameWithOwner` returned by the same GraphQL
/// query. Blobs over the configured byte cap return an empty body with
/// `is_too_large = true`.
///
/// # Errors
/// Returns `CliError` for invalid requests.
pub async fn fetch_review_file_blob(
    request: &ReviewsFilesBlobRequest,
) -> Result<ReviewsFilesBlobResponse, CliError> {
    let oid = request.normalized_oid();
    if oid.is_empty() {
        return Err(CliErrorKind::workflow_parse(
            "reviews files blob: oid must not be empty",
        )
        .into());
    }
    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = ReviewsGitHubClient::new(&token)?;
    let response = client
        .fetch_repository_blob_text(&request.repository_id, &oid)
        .await;
    let mime = crate::reviews::image_mime_for_path(&request.path)
        .unwrap_or(ReviewImageMime::Png);
    match response {
        Ok(blob) => {
            let blob = fetch_binary_blob_when_needed(&client, blob, &oid).await;
            Ok(ReviewsFilesBlobResponse {
                path: request.path.clone(),
                oid,
                mime,
                content_base64: blob.content_base64,
                byte_size: blob.byte_size,
                is_truncated: blob.is_truncated,
                is_too_large: blob.is_too_large,
                fetched_at: utc_now(),
                rate_limit_snapshot: None,
            })
        }
        Err(error) => {
            tracing::warn!(
                target = "harness::reviews::files",
                oid = oid,
                path = request.path,
                error = %error,
                "fetch_review_file_blob graphql fetch failed - returning empty body"
            );
            Ok(ReviewsFilesBlobResponse {
                path: request.path.clone(),
                oid,
                mime,
                content_base64: String::new(),
                byte_size: 0,
                is_truncated: false,
                is_too_large: false,
                fetched_at: utc_now(),
                rate_limit_snapshot: None,
            })
        }
    }
}

async fn fetch_binary_blob_when_needed(
    client: &ReviewsGitHubClient,
    blob: BlobTextProjection,
    oid: &str,
) -> BlobTextProjection {
    if !blob.content_base64.is_empty() || blob.byte_size == 0 || blob.is_too_large {
        return blob;
    }
    let Some(repo_full_name) = blob.repository_full_name.as_deref() else {
        tracing::warn!(
            target = "harness::reviews::files",
            oid = oid,
            "binary blob fallback skipped because repository nameWithOwner was missing"
        );
        return blob;
    };
    match client
        .fetch_repository_blob_base64(repo_full_name, oid)
        .await
    {
        Ok(rest_blob) => rest_blob,
        Err(error) => {
            tracing::warn!(
                target = "harness::reviews::files",
                oid = oid,
                repo = repo_full_name,
                error = %error,
                "binary blob fallback failed"
            );
            blob
        }
    }
}
