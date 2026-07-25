use std::error::Error;
use std::fmt;
use std::net::IpAddr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteAcmeChallenge {
    TlsAlpn,
    Http,
    Dns,
}

impl RemoteAcmeChallenge {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TlsAlpn => "tls-alpn",
            Self::Http => "http",
            Self::Dns => "dns",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteDnsProvider {
    Aftermarket,
    Cloudflare,
    Route53,
    Exec,
}

impl RemoteDnsProvider {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Aftermarket => "aftermarket",
            Self::Cloudflare => "cloudflare",
            Self::Route53 => "route53",
            Self::Exec => "exec",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteCompanionConfig {
    pub upstream: String,
    pub path_prefix: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteDaemonServeConfig {
    pub domain: String,
    pub host: String,
    pub https_port: u16,
    pub http_port: u16,
    pub acme_email: String,
    pub acme_challenge: RemoteAcmeChallenge,
    pub acme_dns_provider: Option<RemoteDnsProvider>,
    /// Companion web service the daemon forwards a path subtree to. The unit
    /// renders these as serve flags, so a companion cannot be enabled by hand
    /// editing an installed unit.
    pub companion: Option<RemoteCompanionConfig>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteDaemonConfigError {
    MissingDomain,
    MissingHost,
    MissingAcmeEmail,
    MissingHttpsPort,
    MissingHttpPort,
    MissingDnsProvider,
    UnexpectedDnsProvider,
    CompanionUpstreamNotLoopbackHttp(String),
    CompanionPathPrefixInvalid(String),
}

impl fmt::Display for RemoteDaemonConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingDomain => write!(formatter, "remote daemon domain is required"),
            Self::MissingHost => write!(formatter, "remote daemon bind host is required"),
            Self::MissingAcmeEmail => write!(formatter, "remote daemon ACME email is required"),
            Self::MissingHttpsPort => {
                write!(formatter, "remote daemon HTTPS port must be non-zero")
            }
            Self::MissingHttpPort => {
                write!(formatter, "remote daemon HTTP-01 port must be non-zero")
            }
            Self::MissingDnsProvider => {
                write!(
                    formatter,
                    "remote daemon DNS-01 challenge requires a DNS provider"
                )
            }
            Self::UnexpectedDnsProvider => write!(
                formatter,
                "remote daemon DNS provider is only valid with DNS-01 challenge"
            ),
            Self::CompanionUpstreamNotLoopbackHttp(upstream) => write!(
                formatter,
                "remote daemon companion upstream must be an http loopback origin, got {upstream}"
            ),
            // One variant covers every prefix rejection, so the message has to
            // name every rule; an operator reading it should not have to guess
            // which one their value broke.
            Self::CompanionPathPrefixInvalid(prefix) => write!(
                formatter,
                "remote daemon companion path prefix {prefix} must be an absolute path with no \
                 trailing slash, no empty segment, and no whitespace, control, or URL-structural \
                 character, and must not start with /{DAEMON_API_SEGMENT}"
            ),
        }
    }
}

impl Error for RemoteDaemonConfigError {}

/// Validate the remote daemon service contract used by the systemd unit.
///
/// # Errors
/// Returns a typed configuration error when a required value is missing or
/// incompatible with the selected ACME challenge.
pub fn validate_remote_serve_config(
    config: &RemoteDaemonServeConfig,
) -> Result<(), RemoteDaemonConfigError> {
    if config.domain.trim().is_empty() {
        return Err(RemoteDaemonConfigError::MissingDomain);
    }
    if config.host.trim().is_empty() {
        return Err(RemoteDaemonConfigError::MissingHost);
    }
    if config.acme_email.trim().is_empty() {
        return Err(RemoteDaemonConfigError::MissingAcmeEmail);
    }
    if config.https_port == 0 {
        return Err(RemoteDaemonConfigError::MissingHttpsPort);
    }
    if !matches!(config.acme_challenge, RemoteAcmeChallenge::Dns)
        && config.acme_dns_provider.is_some()
    {
        return Err(RemoteDaemonConfigError::UnexpectedDnsProvider);
    }
    match config.acme_challenge {
        RemoteAcmeChallenge::Http if config.http_port == 0 => {
            Err(RemoteDaemonConfigError::MissingHttpPort)
        }
        RemoteAcmeChallenge::Dns if config.acme_dns_provider.is_none() => {
            Err(RemoteDaemonConfigError::MissingDnsProvider)
        }
        RemoteAcmeChallenge::TlsAlpn | RemoteAcmeChallenge::Http | RemoteAcmeChallenge::Dns => {
            validate_companion(config.companion.as_ref())
        }
    }
}

/// Path segment the daemon's own API owns; a companion prefix that started here
/// would shadow routes the daemon must keep answering.
const DAEMON_API_SEGMENT: &str = "v1";

/// Subtree handed to the companion when one is configured without an explicit
/// prefix. Must match the daemon's own default.
pub const DEFAULT_COMPANION_PATH_PREFIX: &str = "/panel";

/// Reject a companion the daemon would refuse at startup, so `install` fails
/// while the operator is still watching instead of leaving a unit that will not
/// come up. The daemon re-validates authoritatively; this crate cannot call into
/// it, so the rule is restated rather than shared.
fn validate_companion(
    companion: Option<&RemoteCompanionConfig>,
) -> Result<(), RemoteDaemonConfigError> {
    let Some(companion) = companion else {
        return Ok(());
    };
    let upstream = companion.upstream.trim();
    if !is_loopback_http_origin(upstream) {
        return Err(RemoteDaemonConfigError::CompanionUpstreamNotLoopbackHttp(
            upstream.to_owned(),
        ));
    }
    let prefix = companion.path_prefix.trim();
    if !is_valid_companion_prefix(prefix) {
        return Err(RemoteDaemonConfigError::CompanionPathPrefixInvalid(
            prefix.to_owned(),
        ));
    }
    Ok(())
}

fn is_loopback_http_origin(upstream: &str) -> bool {
    let Some(authority) = strip_http_scheme(upstream) else {
        return false;
    };
    let authority = authority.strip_suffix('/').unwrap_or(authority);
    // The daemon parses the upstream as a URI, which refuses control characters
    // and lets userinfo be spotted; this hand-rolled split would otherwise read
    // `http://127.0.0.1:\n8787` as loopback and render the newline straight into
    // ExecStart, where it ends the directive and whatever follows becomes one of
    // its own.
    if authority.is_empty()
        || authority.contains(['/', '?', '#', '@'])
        || authority
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
    {
        return false;
    }
    companion_host(authority).is_some_and(is_loopback_host)
}

/// The daemon parses the URL and compares the scheme case-insensitively, so
/// `HTTP://` has to be accepted here too. Matching only the lowercase literal
/// would make `install` refuse an upstream the daemon would have taken.
fn strip_http_scheme(upstream: &str) -> Option<&str> {
    let (scheme, authority) = upstream.split_once("://")?;
    scheme.eq_ignore_ascii_case("http").then_some(authority)
}

/// Split `host:port`, keeping a bracketed IPv6 literal in one piece.
fn companion_host(authority: &str) -> Option<&str> {
    let Some(rest) = authority.strip_prefix('[') else {
        return Some(
            authority
                .split_once(':')
                .map_or(authority, |(host, _)| host),
        );
    };
    let (host, tail) = rest.split_once(']')?;
    (tail.is_empty() || tail.starts_with(':')).then_some(host)
}

fn is_loopback_host(host: &str) -> bool {
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<IpAddr>()
            .is_ok_and(|address| address.is_loopback())
}

fn is_valid_companion_prefix(prefix: &str) -> bool {
    if !prefix.starts_with('/') || prefix == "/" || prefix.ends_with('/') {
        return false;
    }
    // Must stay identical to the daemon's own rejected set, or `install` writes
    // a unit whose daemon refuses to start.
    if prefix.chars().any(|character| {
        character.is_whitespace()
            || character.is_control()
            || matches!(character, '?' | '#' | '{' | '}' | '*' | '\\')
    }) {
        return false;
    }
    let mut segments = prefix.split('/').skip(1);
    let Some(first) = segments.next().filter(|segment| !segment.is_empty()) else {
        return false;
    };
    !first.eq_ignore_ascii_case(DAEMON_API_SEGMENT) && !segments.any(str::is_empty)
}
