use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use reqwest::Url;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

const AVATAR_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const AVATAR_REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_AVATAR_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsAvatarRequest {
    pub avatar_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsAvatarResponse {
    pub avatar_url: String,
    pub mime_type: String,
    pub content_base64: String,
    pub fetched_at: String,
}

/// Fetch a GitHub avatar image through the daemon so Monitor never reaches
/// out to GitHub directly from SwiftUI row rendering.
///
/// # Errors
/// Returns `CliError` when the URL is not a GitHub avatar URL, the upstream
/// request fails, or the image is larger than the bounded avatar payload cap.
pub async fn fetch_review_avatar(
    request: &ReviewsAvatarRequest,
) -> Result<ReviewsAvatarResponse, CliError> {
    let url = validate_avatar_url(&request.avatar_url)?;
    let client = reqwest::Client::builder()
        .connect_timeout(AVATAR_CONNECT_TIMEOUT)
        .timeout(AVATAR_REQUEST_TIMEOUT)
        .build()
        .map_err(|error| CliErrorKind::workflow_io(format!("build avatar http client: {error}")))?;
    let response = client
        .get(url.clone())
        .header(reqwest::header::USER_AGENT, "harness-monitor")
        .send()
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("fetch review avatar: {error}")))?;
    let status = response.status();
    if !status.is_success() {
        return Err(CliErrorKind::workflow_io(format!(
            "fetch review avatar: upstream returned {status}"
        ))
        .into());
    }
    if response
        .content_length()
        .is_some_and(|len| len > MAX_AVATAR_BYTES as u64)
    {
        return Err(CliErrorKind::workflow_io("review avatar exceeds size cap").into());
    }
    let mime_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(normalize_mime_type)
        .unwrap_or_else(|| "image/png".to_string());
    let bytes = response
        .bytes()
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("read review avatar: {error}")))?;
    if bytes.len() > MAX_AVATAR_BYTES {
        return Err(CliErrorKind::workflow_io("review avatar exceeds size cap").into());
    }
    Ok(ReviewsAvatarResponse {
        avatar_url: url.to_string(),
        mime_type,
        content_base64: BASE64_STANDARD.encode(bytes),
        fetched_at: utc_now(),
    })
}

pub(crate) fn validate_avatar_url(raw: &str) -> Result<Url, CliError> {
    let url = Url::parse(raw.trim())
        .map_err(|error| CliErrorKind::workflow_parse(format!("invalid avatar URL: {error}")))?;
    if url.scheme() != "https" {
        return Err(CliErrorKind::workflow_parse("avatar URL must use https").into());
    }
    let Some(host) = url.host_str() else {
        return Err(CliErrorKind::workflow_parse("avatar URL must include a host").into());
    };
    if host != "avatars.githubusercontent.com" && host != "github.com" {
        return Err(
            CliErrorKind::workflow_parse("avatar URL must point at GitHub avatar hosts").into(),
        );
    }
    Ok(url)
}

fn normalize_mime_type(raw: &str) -> Option<String> {
    let mime = raw.split(';').next()?.trim().to_ascii_lowercase();
    if mime.starts_with("image/") {
        Some(mime)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn avatar_url_validation_allows_github_avatar_hosts() {
        assert!(validate_avatar_url("https://avatars.githubusercontent.com/in/2740?v=4").is_ok());
        assert!(validate_avatar_url("https://github.com/renovate%5Bbot%5D.png?size=36").is_ok());
    }

    #[test]
    fn avatar_url_validation_rejects_non_github_hosts() {
        let err = validate_avatar_url("https://example.com/avatar.png")
            .expect_err("non-GitHub avatar host should be rejected");
        assert!(err.to_string().contains("GitHub avatar hosts"));
    }

    #[test]
    fn avatar_url_validation_rejects_plain_http() {
        let err = validate_avatar_url("http://avatars.githubusercontent.com/in/2740")
            .expect_err("plain HTTP should be rejected");
        assert!(err.to_string().contains("https"));
    }

    #[test]
    fn mime_type_normalization_accepts_images_only() {
        assert_eq!(
            normalize_mime_type("image/png; charset=binary").as_deref(),
            Some("image/png")
        );
        assert_eq!(normalize_mime_type("text/html"), None);
    }
}
