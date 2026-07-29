//! Wire types for the image-blob fetch. The GraphQL/REST fetch, MIME
//! sniffing helper, size-cap check, and base64 codec helpers stay in
//! `harness-reviews` (real network/byte-handling logic); only the
//! request/response DTOs and the `ReviewImageMime` enum move.

use serde::{Deserialize, Serialize};

use super::ReviewsRateLimitSnapshot;

/// Recognized image-content MIME types we'll preview inline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum ReviewImageMime {
    Png,
    Jpeg,
    Gif,
    Svg,
}

impl ReviewImageMime {
    /// IANA MIME type string.
    #[must_use]
    pub fn mime_type(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
            Self::Gif => "image/gif",
            Self::Svg => "image/svg+xml",
        }
    }
}

/// Request the bytes for one image blob by repository node id + git OID.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesBlobRequest {
    pub repository_id: String,
    pub oid: String,
    pub path: String,
}

impl ReviewsFilesBlobRequest {
    #[must_use]
    pub fn normalized_oid(&self) -> String {
        self.oid.trim().to_lowercase()
    }
}

/// Response carrying the blob bytes (base64-encoded for JSON transport) +
/// metadata + a per-call rate-limit snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesBlobResponse {
    pub path: String,
    pub oid: String,
    pub mime: ReviewImageMime,
    /// Base64-encoded bytes. Empty for `is_too_large == true`.
    pub content_base64: String,
    pub byte_size: u64,
    #[serde(default)]
    pub is_truncated: bool,
    #[serde(default)]
    pub is_too_large: bool,
    pub fetched_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_limit_snapshot: Option<ReviewsRateLimitSnapshot>,
}
