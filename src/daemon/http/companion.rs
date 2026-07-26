//! Routing a configured slice of the daemon's public traffic to a companion
//! service running beside it on loopback.
//!
//! The daemon terminates TLS itself and answers every request from one shared
//! router, so there is no proxy in front of it to split traffic. This module is
//! that split: requests under a configured path prefix are forwarded verbatim to
//! a local upstream, and everything else is served by the daemon exactly as
//! before. Nothing here activates unless an upstream is configured.
//!
//! The prefix is *not* stripped before forwarding. The companion serves its own
//! routes under the same prefix the public origin exposes, which keeps every
//! link it renders correct without teaching it about a rewrite.

use std::error::Error as StdError;
use std::fmt;
use std::net::IpAddr;
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use axum::Router;
use axum::body::Body;
use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderValue, Method, Request, Uri};
use axum::response::Response;
use axum::routing::any;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::{DaemonConnectInfo, DaemonHttpState};

mod credential;
mod forward;
mod rate_limit;
mod response_body;
#[cfg(test)]
mod tests;

pub(crate) use response_body::bind_response_permits;

/// Path segment the daemon's own API owns. A companion prefix may not start
/// here, or the companion would shadow routes the daemon must keep answering.
const DAEMON_API_SEGMENT: &str = "v1";

/// Default subtree handed to the companion when routing is enabled without an
/// explicit prefix.
pub const DEFAULT_COMPANION_PATH_PREFIX: &str = "/panel";

/// What each companion route pattern adds after the configured prefix. Kept as
/// constants so registration and [`CompanionRouteConfig::owns_route`] cannot
/// describe a different route set.
const ROUTE_SUFFIX_SLASH: &str = "/";
const ROUTE_SUFFIX_WILDCARD: &str = "/{*companion_path}";
const OAUTH_START_SUFFIX: &str = "/auth/github/start";
const MAX_CONCURRENT_COMPANION_REQUESTS: usize = 8;

/// Why a companion routing configuration was rejected.
///
/// Every variant is a startup misconfiguration: the daemon refuses to open its
/// public listener rather than serve a prefix that shadows its own API or
/// forwards public traffic off the host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CompanionConfigError {
    UpstreamUnparseable(String),
    UpstreamSchemeUnsupported(String),
    UpstreamMissingHost,
    UpstreamNotLoopback(String),
    UpstreamHasUserinfo(String),
    UpstreamHasPathOrQuery(String),
    AuthTokenUnreadable(String),
    AuthTokenNotRegularFile(String),
    AuthTokenPermissionsTooOpen(String),
    AuthTokenTooShort,
    AuthTokenInvalidCharacter,
    PrefixEmpty,
    PrefixNotAbsolute(String),
    PrefixIsRoot,
    PrefixTrailingSlash(String),
    PrefixEmptySegment(String),
    PrefixDotSegment(String),
    PrefixInvalidCharacter(String),
    PrefixShadowsDaemonApi(String),
}

impl fmt::Display for CompanionConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UpstreamUnparseable(value) => {
                write!(f, "companion upstream is not a valid URL: {value}")
            }
            Self::UpstreamSchemeUnsupported(scheme) => write!(
                f,
                "companion upstream must use the http scheme, got {scheme}"
            ),
            Self::UpstreamMissingHost => write!(f, "companion upstream requires a host"),
            Self::UpstreamNotLoopback(host) => write!(
                f,
                "companion upstream host must be loopback, got {host}; the daemon forwards public \
                 traffic only to a service on its own machine"
            ),
            Self::UpstreamHasUserinfo(value) => write!(
                f,
                "companion upstream must carry no userinfo, got {value}; use the dedicated \
                 companion auth token instead"
            ),
            Self::UpstreamHasPathOrQuery(value) => write!(
                f,
                "companion upstream must be an origin with no path or query, got {value}; the \
                 request path and query are forwarded unchanged"
            ),
            Self::AuthTokenUnreadable(detail) => {
                write!(f, "cannot read companion auth token file: {detail}")
            }
            Self::AuthTokenNotRegularFile(path) => {
                write!(f, "companion auth token must be a regular file: {path}")
            }
            Self::AuthTokenPermissionsTooOpen(path) => write!(
                f,
                "companion auth token file must not be accessible by group or others unless it is \
                 a protected systemd credential: {path}"
            ),
            Self::AuthTokenTooShort => {
                write!(f, "companion auth token must contain at least 32 bytes")
            }
            Self::AuthTokenInvalidCharacter => write!(
                f,
                "companion auth token must contain only visible ASCII without whitespace or control characters"
            ),
            Self::PrefixEmpty => write!(f, "companion path prefix is required"),
            Self::PrefixNotAbsolute(prefix) => {
                write!(f, "companion path prefix must start with /, got {prefix}")
            }
            Self::PrefixIsRoot => write!(
                f,
                "companion path prefix / would forward every request, including the daemon's own API"
            ),
            Self::PrefixTrailingSlash(prefix) => {
                write!(f, "companion path prefix must not end with /, got {prefix}")
            }
            Self::PrefixEmptySegment(prefix) => {
                write!(
                    f,
                    "companion path prefix contains an empty segment: {prefix}"
                )
            }
            Self::PrefixDotSegment(prefix) => write!(
                f,
                "companion path prefix contains a '.' or '..' URL segment: {prefix}"
            ),
            Self::PrefixInvalidCharacter(prefix) => write!(
                f,
                "companion path prefix must contain no whitespace, control, or URL-structural \
                 characters: {prefix}"
            ),
            Self::PrefixShadowsDaemonApi(prefix) => write!(
                f,
                "companion path prefix {prefix} would shadow the daemon's own /{DAEMON_API_SEGMENT} API"
            ),
        }
    }
}

impl StdError for CompanionConfigError {}

/// Credential the daemon presents to the loopback companion.
///
/// Its `Debug` representation is deliberately opaque because
/// [`CompanionRouteConfig`] appears in startup diagnostics.
#[derive(Clone, PartialEq, Eq)]
pub struct CompanionAuthToken(HeaderValue);

impl fmt::Debug for CompanionAuthToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CompanionAuthToken([REDACTED])")
    }
}

impl CompanionAuthToken {
    /// Read and validate a token from a private regular file.
    ///
    /// # Errors
    /// Returns [`CompanionConfigError`] when the file is unavailable, has unsafe
    /// permissions, or does not contain a header-safe token.
    pub fn read_private_file(path: &Path) -> Result<Self, CompanionConfigError> {
        let contents = credential::read_private_file(path)?;
        Self::parse(contents.as_str())
    }

    pub(crate) fn parse(contents: &str) -> Result<Self, CompanionConfigError> {
        let token = contents.trim();
        if token.len() < 32 {
            return Err(CompanionConfigError::AuthTokenTooShort);
        }
        if !token.bytes().all(|byte| (0x21..=0x7e).contains(&byte)) {
            return Err(CompanionConfigError::AuthTokenInvalidCharacter);
        }
        let mut value = HeaderValue::from_str(format!("Bearer {token}").as_str())
            .map_err(|_| CompanionConfigError::AuthTokenInvalidCharacter)?;
        value.set_sensitive(true);
        Ok(Self(value))
    }

    fn authorization_header(&self) -> HeaderValue {
        self.0.clone()
    }
}

/// A validated companion routing target: where to forward, and which subtree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompanionRouteConfig {
    upstream_origin: String,
    path_prefix: String,
    auth_token: CompanionAuthToken,
}

impl CompanionRouteConfig {
    /// Validate a companion upstream and path prefix, and bind its credential.
    ///
    /// # Errors
    /// Returns [`CompanionConfigError`] when the upstream is not a loopback
    /// `http` origin or the prefix would shadow the daemon's own API.
    pub fn new(
        upstream: &str,
        path_prefix: &str,
        auth_token: CompanionAuthToken,
    ) -> Result<Self, CompanionConfigError> {
        Ok(Self {
            upstream_origin: validate_upstream(upstream.trim())?,
            path_prefix: validate_path_prefix(path_prefix.trim())?,
            auth_token,
        })
    }

    /// Origin every forwarded request is sent to, for example `http://127.0.0.1:8787`.
    #[must_use]
    pub fn upstream_origin(&self) -> &str {
        &self.upstream_origin
    }

    /// Absolute path prefix owned by the companion, with no trailing slash.
    #[must_use]
    pub fn path_prefix(&self) -> &str {
        &self.path_prefix
    }

    fn authorization_header(&self) -> HeaderValue {
        self.auth_token.authorization_header()
    }

    /// Every route pattern the companion owns.
    ///
    /// Three are needed, not two: axum's `{*rest}` capture requires a non-empty
    /// remainder, so `/panel/{*companion_path}` does not match `/panel/` - the
    /// very URL a browser lands on. Without the bare trailing-slash pattern the
    /// companion's own root would fall through to the daemon's 404.
    #[must_use]
    pub(crate) fn routes(&self) -> [String; 3] {
        [
            self.path_prefix.clone(),
            format!("{}{ROUTE_SUFFIX_SLASH}", self.path_prefix),
            format!("{}{ROUTE_SUFFIX_WILDCARD}", self.path_prefix),
        ]
    }

    /// Whether a matched route path belongs to the companion rather than the
    /// daemon's own API.
    ///
    /// The limit middleware asks this of every remote request, the daemon's own
    /// included, so it answers by comparing suffixes rather than rebuilding
    /// [`Self::routes`] and allocating three strings to say "no".
    #[must_use]
    pub(crate) fn owns_route(&self, route_path: &str) -> bool {
        route_path
            .strip_prefix(self.path_prefix.as_str())
            .is_some_and(|rest| matches!(rest, "" | ROUTE_SUFFIX_SLASH | ROUTE_SUFFIX_WILDCARD))
    }

    fn is_oauth_start(&self, request_path: &str) -> bool {
        request_path.strip_prefix(self.path_prefix.as_str()) == Some(OAUTH_START_SUFFIX)
    }
}

fn validate_upstream(upstream: &str) -> Result<String, CompanionConfigError> {
    if upstream.is_empty() {
        return Err(CompanionConfigError::UpstreamMissingHost);
    }
    let uri = upstream
        .parse::<Uri>()
        .map_err(|_| CompanionConfigError::UpstreamUnparseable(upstream.to_owned()))?;
    let scheme = uri
        .scheme_str()
        .ok_or_else(|| CompanionConfigError::UpstreamUnparseable(upstream.to_owned()))?;
    if !scheme.eq_ignore_ascii_case("http") {
        return Err(CompanionConfigError::UpstreamSchemeUnsupported(
            scheme.to_owned(),
        ));
    }
    let authority = uri
        .authority()
        .ok_or(CompanionConfigError::UpstreamMissingHost)?;
    // Checking only `authority.host()` would read straight past userinfo and
    // accept `user:pass@127.0.0.1`, which the origin then carries into every
    // forwarded request. Authentication has one dedicated token, so userinfo
    // can only be an accident or a credential left where it does not belong.
    if authority.as_str().contains('@') {
        return Err(CompanionConfigError::UpstreamHasUserinfo(
            upstream.to_owned(),
        ));
    }
    // Report what the operator configured, not the fragment that tripped the
    // rule; a message reading "got /panel" sends them looking for the wrong
    // setting.
    if !authority.as_str().is_empty() && !uri.path().is_empty() && uri.path() != "/" {
        return Err(CompanionConfigError::UpstreamHasPathOrQuery(
            upstream.to_owned(),
        ));
    }
    if uri.query().is_some() {
        return Err(CompanionConfigError::UpstreamHasPathOrQuery(
            upstream.to_owned(),
        ));
    }
    let host = authority.host();
    if host.is_empty() {
        return Err(CompanionConfigError::UpstreamMissingHost);
    }
    if !is_loopback_host(host) {
        return Err(CompanionConfigError::UpstreamNotLoopback(host.to_owned()));
    }
    Ok(format!("{scheme}://{authority}"))
}

/// A companion runs on the same machine by construction, so the upstream host
/// must be a loopback literal. Even `localhost` is refused: the managed socket
/// proves ownership of one numeric address, while DNS may resolve the request
/// to another loopback address a different process owns.
fn is_loopback_host(host: &str) -> bool {
    let host = host.trim_start_matches('[').trim_end_matches(']');
    host.parse::<IpAddr>()
        .is_ok_and(|address| address.is_loopback())
}

fn validate_path_prefix(prefix: &str) -> Result<String, CompanionConfigError> {
    if prefix.is_empty() {
        return Err(CompanionConfigError::PrefixEmpty);
    }
    if !prefix.starts_with('/') {
        return Err(CompanionConfigError::PrefixNotAbsolute(prefix.to_owned()));
    }
    if prefix == "/" {
        return Err(CompanionConfigError::PrefixIsRoot);
    }
    if prefix.ends_with('/') {
        return Err(CompanionConfigError::PrefixTrailingSlash(prefix.to_owned()));
    }
    if prefix.chars().any(is_rejected_prefix_character) {
        return Err(CompanionConfigError::PrefixInvalidCharacter(
            prefix.to_owned(),
        ));
    }
    let mut segments = prefix.split('/').skip(1);
    let first = segments.next().unwrap_or_default();
    if first.is_empty() {
        return Err(CompanionConfigError::PrefixEmptySegment(prefix.to_owned()));
    }
    if segments.any(str::is_empty) {
        return Err(CompanionConfigError::PrefixEmptySegment(prefix.to_owned()));
    }
    if prefix.split('/').skip(1).any(is_url_dot_segment) {
        return Err(CompanionConfigError::PrefixDotSegment(prefix.to_owned()));
    }
    if prefix
        .split('/')
        .skip(1)
        .any(|segment| segment.starts_with(':'))
    {
        return Err(CompanionConfigError::PrefixInvalidCharacter(
            prefix.to_owned(),
        ));
    }
    if first.eq_ignore_ascii_case(DAEMON_API_SEGMENT) {
        return Err(CompanionConfigError::PrefixShadowsDaemonApi(
            prefix.to_owned(),
        ));
    }
    Ok(prefix.to_owned())
}

fn is_url_dot_segment(segment: &str) -> bool {
    matches!(segment, "." | "..")
        || segment.eq_ignore_ascii_case("%2e")
        || segment.eq_ignore_ascii_case(".%2e")
        || segment.eq_ignore_ascii_case("%2e.")
        || segment.eq_ignore_ascii_case("%2e%2e")
}

/// `{`, `}`, `*`, and a segment-leading `:` are axum route-pattern syntax; the
/// rest would change how the prefix parses as a URL.
fn is_rejected_prefix_character(character: char) -> bool {
    character.is_whitespace()
        || character.is_control()
        || matches!(character, '?' | '#' | '{' | '}' | '*' | '\\')
}

type CompanionClient = Client<HttpConnector, Body>;

/// Live companion routing: the validated target plus the pooled client used to
/// reach it. Cloning shares one connection pool.
#[derive(Clone)]
pub struct CompanionRouter {
    inner: Arc<CompanionRouterInner>,
}

struct CompanionRouterInner {
    config: CompanionRouteConfig,
    client: CompanionClient,
    oauth_start_limiter: Mutex<rate_limit::OAuthStartRateLimiter>,
    request_permits: Arc<Semaphore>,
}

impl fmt::Debug for CompanionRouter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CompanionRouter")
            .field("config", &self.inner.config)
            .finish_non_exhaustive()
    }
}

impl CompanionRouter {
    #[must_use]
    pub fn new(config: CompanionRouteConfig) -> Self {
        Self::with_request_limit(config, MAX_CONCURRENT_COMPANION_REQUESTS)
    }

    fn with_request_limit(config: CompanionRouteConfig, max_concurrency: usize) -> Self {
        let client = Client::builder(TokioExecutor::new()).build(HttpConnector::new());
        Self {
            inner: Arc::new(CompanionRouterInner {
                config,
                client,
                oauth_start_limiter: Mutex::new(rate_limit::OAuthStartRateLimiter::new()),
                request_permits: Arc::new(Semaphore::new(max_concurrency)),
            }),
        }
    }

    #[cfg(test)]
    pub(crate) fn with_request_limit_for_tests(
        config: CompanionRouteConfig,
        max_concurrency: usize,
    ) -> Self {
        Self::with_request_limit(config, max_concurrency)
    }

    pub(crate) fn try_request_permit(&self) -> Option<OwnedSemaphorePermit> {
        Arc::clone(&self.inner.request_permits)
            .try_acquire_owned()
            .ok()
    }

    /// Whether the given matched route path is served by the companion.
    #[must_use]
    pub(crate) fn owns_route(&self, route_path: &str) -> bool {
        self.inner.config.owns_route(route_path)
    }
}

/// Register every companion route pattern on the daemon router.
///
/// Merge these *after* the remote authentication layer is applied: the
/// companion authenticates its own users, and its paths carry no entry in
/// `HTTP_API_CONTRACT` for the daemon's scope table to authorize against.
pub(super) fn companion_routes(router: &CompanionRouter) -> Router<DaemonHttpState> {
    router
        .inner
        .config
        .routes()
        .into_iter()
        .fold(Router::new(), |router, route| {
            router.route(&route, any(proxy_request))
        })
}

async fn proxy_request(
    ConnectInfo(connect_info): ConnectInfo<DaemonConnectInfo>,
    State(state): State<DaemonHttpState>,
    request: Request<Body>,
) -> Response {
    let Some(companion) = state.companion.clone() else {
        // Unreachable through the router, which only registers these routes
        // when a companion is configured, but a 502 beats a panic if it ever is.
        return forward::companion_unconfigured_response();
    };
    let peer_addr = connect_info.remote_addr();
    if matches!(request.method(), &Method::GET | &Method::HEAD)
        && companion.inner.config.is_oauth_start(request.uri().path())
    {
        let retry_after = companion
            .inner
            .oauth_start_limiter
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .admit(peer_addr.ip(), Instant::now())
            .err();
        if let Some(retry_after_seconds) = retry_after {
            return rate_limit::rate_limited_response(retry_after_seconds);
        }
    }
    forward::forward_to_companion(
        &companion.inner.config,
        &companion.inner.client,
        peer_addr,
        request,
    )
    .await
}
