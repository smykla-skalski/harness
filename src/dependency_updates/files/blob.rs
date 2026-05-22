//! Image blob fetch for inline previews in the Files section.
//!
//! Two paths converge here:
//!
//! - **GraphQL** for the OID/metadata: `Repository.object(expression:)` →
//!   `... on Blob { oid byteSize isBinary isTruncated text }`. Text blobs
//!   come back inline; binary blobs need the REST path because `text` is
//!   null for binary.
//! - **REST raw bytes** for binary blobs: `GET /repos/{owner}/{repo}/git/blobs/{sha}`
//!   with `Accept: application/vnd.github.raw` returns the raw image bytes.
//!
//! This commit defines the request/response types + pure helpers (path
//! → MIME, size cap enforcement, base64 round-trip). The Octocrab wiring
//! is folded into the service handler in A.10.

use serde::{Deserialize, Serialize};

use super::DependencyUpdatesRateLimitSnapshot;

/// Cap on a single blob byte size we'll return to the client. Larger blobs
/// get a placeholder response with a "Open on github.com" affordance.
pub(crate) const BLOB_BYTES_CAP: u64 = 5 * 1024 * 1024;

/// Recognized image-content MIME types we'll preview inline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdateImageMime {
    Png,
    Jpeg,
    Gif,
    Svg,
}

impl DependencyUpdateImageMime {
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
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesFilesBlobRequest {
    pub repository_id: String,
    pub oid: String,
    pub path: String,
}

impl DependencyUpdatesFilesBlobRequest {
    #[must_use]
    pub fn normalized_oid(&self) -> String {
        self.oid.trim().to_lowercase()
    }
}

/// Response carrying the blob bytes (base64-encoded for JSON transport) +
/// metadata + a per-call rate-limit snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesFilesBlobResponse {
    pub path: String,
    pub oid: String,
    pub mime: DependencyUpdateImageMime,
    /// Base64-encoded bytes. Empty for `is_too_large == true`.
    pub content_base64: String,
    pub byte_size: u64,
    #[serde(default)]
    pub is_truncated: bool,
    #[serde(default)]
    pub is_too_large: bool,
    pub fetched_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rate_limit_snapshot: Option<DependencyUpdatesRateLimitSnapshot>,
}

/// Infer the image MIME from a path extension. Returns `None` if the path is
/// not a previewable image (PNG/JPG/JPEG/GIF/SVG).
#[must_use]
pub fn image_mime_for_path(path: &str) -> Option<DependencyUpdateImageMime> {
    let lower = path.to_ascii_lowercase();
    let ext = lower.rsplit('.').next()?;
    if ext == lower {
        // No extension.
        return None;
    }
    match ext {
        "png" => Some(DependencyUpdateImageMime::Png),
        "jpg" | "jpeg" => Some(DependencyUpdateImageMime::Jpeg),
        "gif" => Some(DependencyUpdateImageMime::Gif),
        "svg" => Some(DependencyUpdateImageMime::Svg),
        _ => None,
    }
}

/// Returns true when a blob's `byte_size` exceeds the cap and should be
/// surfaced as a placeholder rather than streamed inline.
#[must_use]
pub fn blob_exceeds_cap(byte_size: u64) -> bool {
    byte_size > BLOB_BYTES_CAP
}

/// Pure base64 encode/decode helpers. The blob path needs round-trip stability
/// so we lift the encoder/decoder behind tiny shims (also makes them mockable
/// in tests without pulling in the base64 crate inside the test harness).
#[must_use]
pub fn encode_blob_bytes(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Decode helper - returns `Err` on invalid base64 so the service can surface
/// a clean error rather than panicking.
pub fn decode_blob_bytes(encoded: &str) -> Result<Vec<u8>, base64::DecodeError> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.decode(encoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn image_mime_recognises_supported_extensions() {
        assert_eq!(
            image_mime_for_path("docs/logo.png"),
            Some(DependencyUpdateImageMime::Png)
        );
        assert_eq!(
            image_mime_for_path("photo.jpg"),
            Some(DependencyUpdateImageMime::Jpeg)
        );
        assert_eq!(
            image_mime_for_path("photo.jpeg"),
            Some(DependencyUpdateImageMime::Jpeg)
        );
        assert_eq!(
            image_mime_for_path("anim.gif"),
            Some(DependencyUpdateImageMime::Gif)
        );
        assert_eq!(
            image_mime_for_path("vector.svg"),
            Some(DependencyUpdateImageMime::Svg)
        );
    }

    #[test]
    fn image_mime_case_insensitive() {
        assert_eq!(
            image_mime_for_path("LOGO.PNG"),
            Some(DependencyUpdateImageMime::Png)
        );
    }

    #[test]
    fn image_mime_returns_none_for_non_image() {
        assert!(image_mime_for_path("src/lib.rs").is_none());
        assert!(image_mime_for_path("doc.pdf").is_none());
        assert!(image_mime_for_path("no-extension").is_none());
    }

    #[test]
    fn mime_type_strings_match_iana() {
        assert_eq!(DependencyUpdateImageMime::Png.mime_type(), "image/png");
        assert_eq!(DependencyUpdateImageMime::Jpeg.mime_type(), "image/jpeg");
        assert_eq!(DependencyUpdateImageMime::Gif.mime_type(), "image/gif");
        assert_eq!(DependencyUpdateImageMime::Svg.mime_type(), "image/svg+xml");
    }

    #[test]
    fn blob_cap_recognises_oversize() {
        assert!(blob_exceeds_cap(BLOB_BYTES_CAP + 1));
        assert!(!blob_exceeds_cap(BLOB_BYTES_CAP));
        assert!(!blob_exceeds_cap(BLOB_BYTES_CAP - 1));
    }

    #[test]
    fn base64_round_trip() {
        let bytes: &[u8] = b"\x89PNG\r\n\x1a\n";
        let encoded = encode_blob_bytes(bytes);
        let decoded = decode_blob_bytes(&encoded).expect("decode");
        assert_eq!(decoded.as_slice(), bytes);
    }

    #[test]
    fn base64_decode_rejects_invalid() {
        let err = decode_blob_bytes("!!!not base64!!!");
        assert!(err.is_err());
    }

    #[test]
    fn normalized_oid_lowercases_and_trims() {
        let request = DependencyUpdatesFilesBlobRequest {
            repository_id: "MDEwOlJlcG9zaXRvcnk".into(),
            oid: "  ABCDEF1234  ".into(),
            path: "docs/logo.png".into(),
        };
        assert_eq!(request.normalized_oid(), "abcdef1234");
    }

    #[test]
    fn blob_response_serializes_round_trip() {
        let response = DependencyUpdatesFilesBlobResponse {
            path: "docs/logo.png".into(),
            oid: "abc123".into(),
            mime: DependencyUpdateImageMime::Png,
            content_base64: "iVBORw0KGgoAAAANSUhEUgAA".into(),
            byte_size: 64,
            is_truncated: false,
            is_too_large: false,
            fetched_at: "2026-05-22T10:00:00Z".into(),
            rate_limit_snapshot: None,
        };
        let json = serde_json::to_string(&response).expect("serialize");
        let parsed: DependencyUpdatesFilesBlobResponse =
            serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed, response);
    }

    #[test]
    fn blob_response_omits_optional_rate_limit() {
        let response = DependencyUpdatesFilesBlobResponse {
            path: "logo.png".into(),
            oid: "abc".into(),
            mime: DependencyUpdateImageMime::Png,
            content_base64: String::new(),
            byte_size: 0,
            is_truncated: false,
            is_too_large: true,
            fetched_at: "2026-05-22T10:00:00Z".into(),
            rate_limit_snapshot: None,
        };
        let json = serde_json::to_value(&response).expect("serialize");
        assert!(json.get("rate_limit_snapshot").is_none());
    }
}
