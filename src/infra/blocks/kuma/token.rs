use crate::infra::blocks::BlockError;

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
mod tests;
