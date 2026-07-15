//! Image-preview blob fetch endpoint.

use crate::errors::{CliError, CliErrorKind};
use crate::reviews::files::blob::BlobTextProjection;
use crate::reviews::{
    ReviewImageMime, ReviewsFilesBlobRequest, ReviewsFilesBlobResponse, ReviewsGitHubClient,
    image_mime_for_path,
};
use crate::workspace::utc_now;

use super::token::{github_token, missing_token_error};

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
        return Err(
            CliErrorKind::workflow_parse("reviews files blob: oid must not be empty").into(),
        );
    }
    let token = github_token(None).ok_or_else(|| missing_token_error(None))?;
    let client = ReviewsGitHubClient::new(&token)?;
    let mime = image_mime_for_path(&request.path).unwrap_or(ReviewImageMime::Png);
    fetch_blob_with_client(&client, request, oid, mime).await
}

fn blob_response(
    path: String,
    oid: String,
    mime: ReviewImageMime,
    blob: BlobTextProjection,
) -> ReviewsFilesBlobResponse {
    ReviewsFilesBlobResponse {
        path,
        oid,
        mime,
        content_base64: blob.content_base64,
        byte_size: blob.byte_size,
        is_truncated: blob.is_truncated,
        is_too_large: blob.is_too_large,
        fetched_at: utc_now(),
        rate_limit_snapshot: None,
    }
}

fn empty_blob_response(
    path: String,
    oid: String,
    mime: ReviewImageMime,
) -> ReviewsFilesBlobResponse {
    ReviewsFilesBlobResponse {
        path,
        oid,
        mime,
        content_base64: String::new(),
        byte_size: 0,
        is_truncated: false,
        is_too_large: false,
        fetched_at: utc_now(),
        rate_limit_snapshot: None,
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_blob_msg(msg: &str) {
    tracing::warn!(target = "harness::reviews::files", "{msg}");
}

async fn fetch_blob_with_client(
    client: &ReviewsGitHubClient,
    request: &ReviewsFilesBlobRequest,
    oid: String,
    mime: ReviewImageMime,
) -> Result<ReviewsFilesBlobResponse, CliError> {
    let result = client
        .fetch_repository_blob_text(&request.repository_id, &oid)
        .await;
    match result {
        Ok(blob) => {
            let blob = fetch_binary_blob_when_needed(client, blob, &oid).await;
            Ok(blob_response(request.path.clone(), oid, mime, blob))
        }
        Err(error) => {
            warn_blob_msg(&format!(
                "graphql blob fetch failed (returning empty body): oid={oid} path={} error={error}",
                request.path
            ));
            Ok(empty_blob_response(request.path.clone(), oid, mime))
        }
    }
}

fn needs_binary_fallback(blob: &BlobTextProjection) -> bool {
    blob.content_base64.is_empty() && blob.byte_size > 0 && !blob.is_too_large
}

async fn fetch_binary_blob_when_needed(
    client: &ReviewsGitHubClient,
    blob: BlobTextProjection,
    oid: &str,
) -> BlobTextProjection {
    if needs_binary_fallback(&blob) {
        return fetch_binary_blob_fallback(client, blob, oid).await;
    }
    blob
}

async fn fetch_binary_blob_fallback(
    client: &ReviewsGitHubClient,
    blob: BlobTextProjection,
    oid: &str,
) -> BlobTextProjection {
    let Some(repo_full_name) = blob.repository_full_name.as_deref() else {
        warn_blob_msg(&format!(
            "binary blob fallback skipped: missing nameWithOwner oid={oid}"
        ));
        return blob;
    };
    match client
        .fetch_repository_blob_base64(repo_full_name, oid)
        .await
    {
        Ok(rest_blob) => rest_blob,
        Err(error) => {
            warn_blob_msg(&format!(
                "binary blob fallback failed: oid={oid} repo={repo_full_name} error={error}"
            ));
            blob
        }
    }
}
