//! Local same-origin edge for an operator-run Sybra web backend.
//!
//! The standalone edge owns authentication and routing decisions. Its loopback
//! upstream receives only the private hop credential, never the browser token.

use std::error::Error as StdError;
use std::fmt;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;

use axum::http::{HeaderValue, Uri};

mod client;
mod credential;
mod forward;
#[cfg(test)]
mod gateway_tests;
mod ownership;
mod response_body;
mod router;
#[cfg(test)]
mod tests;

pub use ownership::{SybraOperation, SybraOwner, SybraOwnershipRegistry};
pub use router::SybraGateway;
pub use router::sybra_routes;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SybraGatewayConfigError {
    UpstreamUnparseable,
    UpstreamSchemeUnsupported(String),
    UpstreamMissingHost,
    UpstreamNotNumericLoopback(String),
    UpstreamHasUserinfo,
    UpstreamHasPathOrQuery,
    UpstreamMissingPort,
    UpstreamLoop(SocketAddr),
    TokenCollision,
    TokenUnreadable(String),
    TokenNotRegularFile(String),
    TokenPermissionsTooOpen(String),
    TokenTooShort,
    TokenInvalidCharacter,
}

impl fmt::Display for SybraGatewayConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UpstreamUnparseable => write!(f, "Sybra upstream is not a valid URL"),
            Self::UpstreamSchemeUnsupported(scheme) => {
                write!(f, "Sybra upstream must use HTTP, got {scheme}")
            }
            Self::UpstreamMissingHost => write!(f, "Sybra upstream requires a host"),
            Self::UpstreamNotNumericLoopback(host) => {
                write!(
                    f,
                    "Sybra upstream must use a numeric loopback host, got {host}"
                )
            }
            Self::UpstreamHasUserinfo => write!(f, "Sybra upstream must not contain userinfo"),
            Self::UpstreamHasPathOrQuery => {
                write!(f, "Sybra upstream must be an origin without path or query")
            }
            Self::UpstreamMissingPort => {
                write!(
                    f,
                    "Sybra upstream must include an explicit numeric loopback port"
                )
            }
            Self::UpstreamLoop(address) => {
                write!(
                    f,
                    "Sybra upstream loops back to the gateway listener at {address}"
                )
            }
            Self::TokenCollision => {
                write!(f, "Sybra browser and upstream credentials must be distinct")
            }
            Self::TokenUnreadable(detail) => {
                write!(f, "cannot read Sybra credential: {detail}")
            }
            Self::TokenNotRegularFile(path) => {
                write!(f, "Sybra credential must be a regular file: {path}")
            }
            Self::TokenPermissionsTooOpen(path) => {
                write!(f, "Sybra credential file permissions are too open: {path}")
            }
            Self::TokenTooShort => {
                write!(f, "Sybra credential must contain at least 32 bytes")
            }
            Self::TokenInvalidCharacter => write!(
                f,
                "Sybra credential must contain visible ASCII without whitespace"
            ),
        }
    }
}

impl StdError for SybraGatewayConfigError {}

#[derive(Clone, PartialEq, Eq)]
pub struct SybraGatewayConfig {
    origin: String,
    address: SocketAddr,
    token: SybraUpstreamToken,
}

impl fmt::Debug for SybraGatewayConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SybraGatewayConfig")
            .field("upstream_origin", &self.origin)
            .field("upstream_address", &self.address)
            .field("upstream_token", &self.token)
            .finish()
    }
}

impl SybraGatewayConfig {
    /// Validate and load the loopback upstream before service startup mutates state.
    ///
    /// # Errors
    /// Returns [`SybraGatewayConfigError`] for an unsafe origin or credential.
    pub fn from_private_token_file(
        upstream: &str,
        token_file: &Path,
    ) -> Result<Self, SybraGatewayConfigError> {
        let token = SybraUpstreamToken::read_private_file(token_file)?;
        Self::new(upstream, token)
    }

    pub(crate) fn new(
        upstream: &str,
        upstream_token: SybraUpstreamToken,
    ) -> Result<Self, SybraGatewayConfigError> {
        let upstream_origin = validate_upstream(upstream.trim())?;
        let uri = upstream_origin
            .parse::<Uri>()
            .map_err(|_| SybraGatewayConfigError::UpstreamMissingPort)?;
        let authority = uri
            .authority()
            .ok_or(SybraGatewayConfigError::UpstreamMissingPort)?;
        let port = authority
            .port_u16()
            .ok_or(SybraGatewayConfigError::UpstreamMissingPort)?;
        let host = authority
            .host()
            .trim_start_matches('[')
            .trim_end_matches(']');
        let ip = host
            .parse::<IpAddr>()
            .map_err(|_| SybraGatewayConfigError::UpstreamMissingPort)?;
        Ok(Self {
            origin: upstream_origin,
            address: SocketAddr::new(ip, port),
            token: upstream_token,
        })
    }

    /// Reject a listener that would recursively target the gateway itself.
    ///
    /// # Errors
    /// Returns [`SybraGatewayConfigError::UpstreamLoop`] for a matching address.
    pub fn reject_listener_loop(
        &self,
        listener: SocketAddr,
    ) -> Result<(), SybraGatewayConfigError> {
        if self.address == listener {
            return Err(SybraGatewayConfigError::UpstreamLoop(listener));
        }
        Ok(())
    }

    /// Reject reuse of the private upstream credential at the browser edge.
    ///
    /// # Errors
    /// Returns [`SybraGatewayConfigError::TokenCollision`] for equal credentials.
    pub fn reject_matching_browser_token(
        &self,
        browser_token: &SybraBrowserToken,
    ) -> Result<(), SybraGatewayConfigError> {
        if constant_time_eq(
            self.token.secret().as_bytes(),
            browser_token.secret().as_bytes(),
        ) {
            return Err(SybraGatewayConfigError::TokenCollision);
        }
        Ok(())
    }

    pub(crate) fn upstream_origin(&self) -> &str {
        &self.origin
    }

    pub(crate) fn authorization_header(&self) -> axum::http::HeaderValue {
        self.token.authorization_header()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct SybraBrowserToken(String);

impl fmt::Debug for SybraBrowserToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SybraBrowserToken([REDACTED])")
    }
}

impl SybraBrowserToken {
    #[cfg(test)]
    #[must_use]
    pub(crate) fn new(token: String) -> Self {
        Self(token)
    }

    /// Load the browser hop credential before binding the gateway listener.
    ///
    /// # Errors
    /// Returns [`SybraGatewayConfigError`] when the file is unsafe or invalid.
    pub fn from_private_file(path: &Path) -> Result<Self, SybraGatewayConfigError> {
        let contents = credential::read_private_file(path)?;
        let token = SybraUpstreamToken::parse(&contents)?;
        Ok(Self(token.secret))
    }

    fn accepts_header(&self, value: Option<&HeaderValue>) -> bool {
        value
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .map(str::trim)
            .is_some_and(|candidate| constant_time_eq(candidate.as_bytes(), self.0.as_bytes()))
    }

    fn accepts_secret(&self, candidate: &str) -> bool {
        constant_time_eq(candidate.as_bytes(), self.0.as_bytes())
    }

    fn secret(&self) -> &str {
        &self.0
    }
}

fn constant_time_eq(candidate: &[u8], expected: &[u8]) -> bool {
    if candidate.len() != expected.len() {
        return false;
    }
    candidate
        .iter()
        .zip(expected)
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

#[derive(Clone, PartialEq, Eq)]
struct SybraUpstreamToken {
    authorization: HeaderValue,
    secret: String,
}

impl fmt::Debug for SybraUpstreamToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SybraUpstreamToken([REDACTED])")
    }
}

impl SybraUpstreamToken {
    fn read_private_file(path: &Path) -> Result<Self, SybraGatewayConfigError> {
        let contents = credential::read_private_file(path)?;
        Self::parse(&contents)
    }

    fn parse(contents: &str) -> Result<Self, SybraGatewayConfigError> {
        let token = contents.trim();
        if token.len() < 32 {
            return Err(SybraGatewayConfigError::TokenTooShort);
        }
        if !token.bytes().all(|byte| (0x21..=0x7e).contains(&byte)) {
            return Err(SybraGatewayConfigError::TokenInvalidCharacter);
        }
        let mut authorization = HeaderValue::from_str(&format!("Bearer {token}"))
            .map_err(|_| SybraGatewayConfigError::TokenInvalidCharacter)?;
        authorization.set_sensitive(true);
        Ok(Self {
            authorization,
            secret: token.to_owned(),
        })
    }

    fn authorization_header(&self) -> HeaderValue {
        self.authorization.clone()
    }

    fn secret(&self) -> &str {
        &self.secret
    }
}

fn validate_upstream(upstream: &str) -> Result<String, SybraGatewayConfigError> {
    let uri = upstream
        .parse::<Uri>()
        .map_err(|_| SybraGatewayConfigError::UpstreamUnparseable)?;
    let scheme = uri
        .scheme_str()
        .ok_or(SybraGatewayConfigError::UpstreamUnparseable)?;
    if !scheme.eq_ignore_ascii_case("http") {
        return Err(SybraGatewayConfigError::UpstreamSchemeUnsupported(
            scheme.to_owned(),
        ));
    }
    let authority = uri
        .authority()
        .ok_or(SybraGatewayConfigError::UpstreamMissingHost)?;
    if authority.as_str().contains('@') {
        return Err(SybraGatewayConfigError::UpstreamHasUserinfo);
    }
    if (!uri.path().is_empty() && uri.path() != "/") || uri.query().is_some() {
        return Err(SybraGatewayConfigError::UpstreamHasPathOrQuery);
    }
    let host = authority.host();
    let numeric = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .parse::<IpAddr>()
        .ok();
    if !numeric.is_some_and(|address| address.is_loopback()) {
        return Err(SybraGatewayConfigError::UpstreamNotNumericLoopback(
            host.to_owned(),
        ));
    }
    Ok(format!("{scheme}://{authority}"))
}
