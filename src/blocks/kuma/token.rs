use crate::blocks::{BlockError, ContainerRuntime};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use std::thread;
use std::time::{Duration, Instant};

/// Token kinds supported by the Kuma control plane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KumaTokenKind {
    Dataplane,
    Zone,
    User,
}

impl KumaTokenKind {
    #[must_use]
    pub const fn as_api_value(self) -> &'static str {
        match self {
            Self::Dataplane => "dataplane",
            Self::Zone => "zone",
            Self::User => "user",
        }
    }
}

/// Request payload for Kuma token generation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KumaTokenRequest {
    pub kind: KumaTokenKind,
    pub name: String,
    pub mesh: String,
    pub valid_for: String,
}

impl KumaTokenRequest {
    #[must_use]
    pub fn new(
        kind: KumaTokenKind,
        name: impl Into<String>,
        mesh: impl Into<String>,
        valid_for: impl Into<String>,
    ) -> Self {
        Self {
            kind,
            name: name.into(),
            mesh: mesh.into(),
            valid_for: valid_for.into(),
        }
    }

    /// # Errors
    ///
    /// Returns `BlockError` if any required field is empty.
    pub fn validate(&self) -> Result<(), BlockError> {
        if self.name.trim().is_empty() {
            return Err(BlockError::message(
                "kuma",
                "token request validation",
                "token name must not be empty",
            ));
        }
        if self.mesh.trim().is_empty() {
            return Err(BlockError::message(
                "kuma",
                "token request validation",
                "mesh must not be empty",
            ));
        }
        if self.valid_for.trim().is_empty() {
            return Err(BlockError::message(
                "kuma",
                "token request validation",
                "valid_for must not be empty",
            ));
        }
        Ok(())
    }
}

/// Parsed Kuma token response.
///
/// This stays intentionally small for now: current callers only need
/// the raw token string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KumaTokenResponse {
    pub token: String,
}

impl KumaTokenResponse {
    #[must_use]
    pub fn new(token: impl Into<String>) -> Self {
        Self {
            token: token.into(),
        }
    }

    /// # Errors
    ///
    /// Returns `BlockError` if the token string is empty.
    pub fn validate(&self) -> Result<(), BlockError> {
        if self.token.trim().is_empty() {
            return Err(BlockError::message(
                "kuma",
                "token response validation",
                "token must not be empty",
            ));
        }
        Ok(())
    }
}

/// Build the control-plane API path for a token request.
#[must_use]
pub fn token_api_path(request: &KumaTokenRequest) -> String {
    format!(
        "/tokens/{}?name={}&mesh={}&validFor={}",
        request.kind.as_api_value(),
        request.name,
        request.mesh,
        request.valid_for
    )
}

/// Resolve the resource path used to create a dataplane token.
///
/// # Errors
///
/// Returns `BlockError` if the mesh or name is empty.
pub fn dataplane_token_path(mesh: &str, name: &str) -> Result<String, BlockError> {
    let request = KumaTokenRequest::new(
        KumaTokenKind::Dataplane,
        require_non_empty("dataplane token", "name", name)?,
        require_non_empty("dataplane token", "mesh", mesh)?,
        "24h",
    );
    request.validate()?;
    Ok(token_api_path(&request))
}

/// Resolve the resource path used to create a zone token.
///
/// Kuma's zone token endpoint does not require a mesh parameter in practice, but
/// this block keeps a uniform request shape and uses the default mesh name for
/// compatibility with the rest of the harness token model.
///
/// # Errors
///
/// Returns `BlockError` if the name is empty.
pub fn zone_token_path(name: &str) -> Result<String, BlockError> {
    let request = KumaTokenRequest::new(
        KumaTokenKind::Zone,
        require_non_empty("zone token", "name", name)?,
        "default",
        "24h",
    );
    request.validate()?;
    Ok(token_api_path(&request))
}

/// Normalize a raw token body returned by the control plane.
///
/// Current CLI flows treat the body as a plain string. This helper trims
/// surrounding whitespace and validates that a token was actually returned.
///
/// # Errors
///
/// Returns `BlockError` if the trimmed response is empty.
pub fn parse_token_response(raw: &str) -> Result<KumaTokenResponse, BlockError> {
    let response = KumaTokenResponse::new(raw.trim().to_string());
    response.validate()?;
    Ok(response)
}

/// Extract the admin user token from a running Kuma control-plane container.
///
/// The control plane bootstraps the admin token asynchronously, so this helper
/// retries for a short bounded period before failing.
///
/// # Errors
///
/// Returns `BlockError` if the token cannot be fetched, parsed, decoded, or is
/// still unavailable after the retry window expires.
pub fn extract_admin_token(
    runtime: &dyn ContainerRuntime,
    cp_container: &str,
) -> Result<String, BlockError> {
    let container = require_non_empty("extract admin token", "cp_container", cp_container)?;
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut sleep_for = Duration::from_millis(200);
    let max_sleep = Duration::from_secs(2);

    loop {
        match try_extract_admin_token(runtime, container) {
            Ok(token) => return Ok(token),
            Err(error) => {
                let now = Instant::now();
                if now >= deadline {
                    return Err(error);
                }
                let remaining = deadline.saturating_duration_since(now);
                thread::sleep(sleep_for.min(remaining));
                sleep_for = (sleep_for * 2).min(max_sleep);
            }
        }
    }
}

fn try_extract_admin_token(
    runtime: &dyn ContainerRuntime,
    cp_container: &str,
) -> Result<String, BlockError> {
    let result = runtime.exec_command(
        cp_container,
        &[
            "/busybox/wget",
            "-q",
            "-O",
            "-",
            "http://localhost:5681/global-secrets/admin-user-token",
        ],
    )?;

    let body: serde_json::Value = serde_json::from_str(result.stdout.trim())
        .map_err(|error| BlockError::new("kuma", "parse admin token response", error))?;

    let b64_data = body
        .get("data")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            BlockError::message("kuma", "parse admin token response", "missing data field")
        })?;

    let bytes = STANDARD
        .decode(b64_data)
        .map_err(|error| BlockError::new("kuma", "decode admin token", error))?;

    let token = String::from_utf8(bytes)
        .map_err(|error| BlockError::new("kuma", "decode admin token utf8", error))?;

    let trimmed = token.trim().to_string();
    if trimmed.is_empty() {
        return Err(BlockError::message(
            "kuma",
            "extract_admin_token",
            "empty token",
        ));
    }

    Ok(trimmed)
}

fn require_non_empty<'a>(
    operation: &str,
    field: &str,
    value: &'a str,
) -> Result<&'a str, BlockError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(BlockError::message(
            "kuma",
            operation,
            format!("{field} must not be empty"),
        ));
    }
    Ok(trimmed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_kind_maps_to_api_values() {
        assert_eq!(KumaTokenKind::Dataplane.as_api_value(), "dataplane");
        assert_eq!(KumaTokenKind::Zone.as_api_value(), "zone");
        assert_eq!(KumaTokenKind::User.as_api_value(), "user");
    }

    #[test]
    fn request_validation_rejects_empty_fields() {
        let err = KumaTokenRequest::new(KumaTokenKind::Dataplane, "", "default", "24h")
            .validate()
            .expect_err("expected validation error");
        assert!(err.to_string().contains("token name"));
    }

    #[test]
    fn token_api_path_contains_expected_parts() {
        let request = KumaTokenRequest::new(KumaTokenKind::Dataplane, "demo", "default", "24h");
        assert_eq!(
            token_api_path(&request),
            "/tokens/dataplane?name=demo&mesh=default&validFor=24h"
        );
    }

    #[test]
    fn dataplane_token_path_uses_default_validity() {
        let path = dataplane_token_path("default", "demo").expect("expected dataplane path");
        assert_eq!(
            path,
            "/tokens/dataplane?name=demo&mesh=default&validFor=24h"
        );
    }

    #[test]
    fn zone_token_path_uses_default_mesh_and_validity() {
        let path = zone_token_path("zone-1").expect("expected zone path");
        assert_eq!(path, "/tokens/zone?name=zone-1&mesh=default&validFor=24h");
    }

    #[test]
    fn dataplane_token_path_rejects_empty_inputs() {
        assert!(dataplane_token_path("", "demo").is_err());
        assert!(dataplane_token_path("default", "").is_err());
    }

    #[test]
    fn zone_token_path_rejects_empty_name() {
        assert!(zone_token_path("").is_err());
    }

    #[test]
    fn parse_token_response_trims_and_validates() {
        let response = parse_token_response("  abc123  ").expect("expected token");
        assert_eq!(response.token, "abc123");
    }

    #[test]
    fn parse_token_response_rejects_empty_body() {
        let err = parse_token_response("   ").expect_err("expected validation error");
        assert!(err.to_string().contains("token must not be empty"));
    }
}
