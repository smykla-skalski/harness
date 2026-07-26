//! Panel configuration: the flags an operator sets, and what they resolve to.
//!
//! Every absolute URL the panel produces, including the OAuth `redirect_uri`,
//! is built from `--public-origin` and `--base-path`. Deriving them from
//! forwarded headers instead would let whoever can reach the listener choose
//! where GitHub sends the authorization code.

pub mod daemon;
mod secret;

use std::net::SocketAddr;
use std::path::PathBuf;

use chrono::Duration;
use url::{Host, Url};

use crate::error::PanelError;
pub use secret::{ClientSecret, CompanionAuthDigest};

pub const DEFAULT_LISTEN: &str = "127.0.0.1:8787";
pub const DEFAULT_BASE_PATH: &str = "/panel";
pub const DEFAULT_GITHUB_AUTHORIZE_URL: &str = "https://github.com/login/oauth/authorize";
pub const DEFAULT_GITHUB_TOKEN_URL: &str = "https://github.com/login/oauth/access_token";
pub const DEFAULT_GITHUB_API_URL: &str = "https://api.github.com";
pub const DEFAULT_SESSION_TTL_HOURS: u32 = 12;

/// A year. The flag is a `u32`, and a value in the billions makes the expiry
/// `create_session` computes run off the end of the calendar `chrono` can
/// represent, which panics mid-request rather than failing to start.
pub const MAX_SESSION_TTL_HOURS: u32 = 8_760;

/// How long an unfinished sign-in may sit in the store before its state value
/// stops being accepted.
pub const OAUTH_STATE_TTL_MINUTES: i64 = 10;

/// The flags as written on the command line, before anything is read from disk.
///
/// `print-unit` renders these back out verbatim, so it must stay possible to
/// hold them without touching the filesystem.
#[derive(Debug, Clone, clap::Args)]
pub struct PanelArgs {
    /// Address to serve on. Bind loopback and let the daemon forward to it.
    #[arg(long, default_value = DEFAULT_LISTEN, env = "HARNESS_PANEL_LISTEN")]
    pub listen: SocketAddr,

    /// Origin the panel is reached at, such as `https://harness.example.com`.
    #[arg(long, env = "HARNESS_PANEL_PUBLIC_ORIGIN")]
    pub public_origin: String,

    /// Path subtree the panel is mounted under, matching the daemon's
    /// `--companion-path-prefix`.
    #[arg(long, default_value = DEFAULT_BASE_PATH, env = "HARNESS_PANEL_BASE_PATH")]
    pub base_path: String,

    /// Directory holding the panel's `SQLite` database.
    #[arg(long, env = "HARNESS_PANEL_STATE_DIR")]
    pub state_dir: PathBuf,

    /// File holding the private token the daemon presents on every forwarded
    /// request.
    #[arg(long, env = "HARNESS_PANEL_COMPANION_AUTH_TOKEN_FILE")]
    pub companion_auth_token_file: PathBuf,

    /// GitHub OAuth app client id.
    #[arg(long, env = "HARNESS_PANEL_GITHUB_CLIENT_ID")]
    pub github_client_id: String,

    /// File holding the GitHub OAuth app client secret. The secret is never
    /// taken as a flag value or an environment string, both of which any local
    /// process can read out of `/proc`.
    #[arg(long, env = "HARNESS_PANEL_GITHUB_CLIENT_SECRET_FILE")]
    pub github_client_secret_file: PathBuf,

    /// GitHub login of the person who owns this panel.
    #[arg(long, env = "HARNESS_PANEL_OWNER_LOGIN")]
    pub owner_login: String,

    /// Authorization endpoint. Override for GitHub Enterprise.
    #[arg(long, default_value = DEFAULT_GITHUB_AUTHORIZE_URL, env = "HARNESS_PANEL_GITHUB_AUTHORIZE_URL")]
    pub github_authorize_url: String,

    /// Access-token endpoint. Override for GitHub Enterprise.
    #[arg(long, default_value = DEFAULT_GITHUB_TOKEN_URL, env = "HARNESS_PANEL_GITHUB_TOKEN_URL")]
    pub github_token_url: String,

    /// REST API base. Override for GitHub Enterprise.
    #[arg(long, default_value = DEFAULT_GITHUB_API_URL, env = "HARNESS_PANEL_GITHUB_API_URL")]
    pub github_api_url: String,

    /// How long a signed-in session stays valid.
    #[arg(long, default_value_t = DEFAULT_SESSION_TTL_HOURS, env = "HARNESS_PANEL_SESSION_TTL_HOURS")]
    pub session_ttl_hours: u32,

    /// The daemon's public origin, such as `https://harness.example.com`.
    #[arg(long, env = "HARNESS_PANEL_DAEMON_ENDPOINT")]
    pub daemon_endpoint: String,

    /// The daemon's certificate pin, as `sha256/<base64>`. Every pairing
    /// invitation the daemon issues carries the same value.
    #[arg(long, env = "HARNESS_PANEL_DAEMON_SPKI_PIN")]
    pub daemon_spki_pin: String,

    /// The role every link the panel mints grants.
    #[arg(long, default_value = daemon::DEFAULT_PAIR_LINK_ROLE, env = "HARNESS_PANEL_PAIR_LINK_ROLE")]
    pub pair_link_role: String,

    /// How long a minted link stays claimable.
    #[arg(long, default_value_t = daemon::DEFAULT_PAIR_LINK_TTL_SECONDS, env = "HARNESS_PANEL_PAIR_LINK_TTL_SECONDS")]
    pub pair_link_ttl_seconds: u64,
}

/// Where the panel talks to GitHub, and as whom.
#[derive(Debug, Clone)]
pub struct GitHubConfig {
    pub client_id: String,
    pub client_secret: ClientSecret,
    pub authorize_url: Url,
    pub token_url: Url,
    pub api_url: Url,
}

/// Validated configuration the running panel uses.
#[derive(Debug, Clone)]
pub struct PanelConfig {
    pub listen: SocketAddr,
    pub public_origin: String,
    pub base_path: String,
    pub state_dir: PathBuf,
    pub companion_auth: CompanionAuthDigest,
    pub owner_login: String,
    pub github: GitHubConfig,
    pub session_ttl: Duration,
    pub daemon: daemon::DaemonConfig,
}

pub(crate) struct ValidatedPanelArgs {
    pub(crate) base_path: String,
    public_origin: String,
    client_id: String,
    owner_login: String,
    authorize_url: Url,
    token_url: Url,
    api_url: Url,
    session_ttl: Duration,
    daemon: daemon::DaemonConfig,
}

impl PanelArgs {
    /// Validate the flags and read the private credentials.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when a flag is malformed or a credential
    /// file is readable by anyone but its owner, and [`PanelError::Io`] when a
    /// credential file cannot be read.
    pub fn resolve(&self) -> Result<PanelConfig, PanelError> {
        let validated = self.validate_runtime()?;
        let client_secret = secret::read_client_secret(&self.github_client_secret_file)?;
        let companion_auth = secret::read_companion_auth_token(&self.companion_auth_token_file)?;

        Ok(PanelConfig {
            listen: self.listen,
            public_origin: validated.public_origin,
            base_path: validated.base_path,
            state_dir: self.state_dir.clone(),
            companion_auth,
            owner_login: validated.owner_login,
            github: GitHubConfig {
                client_id: validated.client_id,
                client_secret,
                authorize_url: validated.authorize_url,
                token_url: validated.token_url,
                api_url: validated.api_url,
            },
            session_ttl: validated.session_ttl,
            daemon: validated.daemon,
        })
    }

    /// Validate everything the running panel can check without reading private
    /// credentials or touching its state directory.
    pub(crate) fn validate_runtime(&self) -> Result<ValidatedPanelArgs, PanelError> {
        validate_listen(self.listen)?;
        let base_path = normalize_base_path(&self.base_path)?;
        let public_origin = normalize_public_origin(&self.public_origin)?;
        let client_id = self.github_client_id.trim().to_owned();
        if client_id.is_empty() {
            return Err(PanelError::config("--github-client-id must not be blank"));
        }
        let owner_login = self.owner_login.trim().to_owned();
        if owner_login.is_empty() {
            return Err(PanelError::config("--owner-login must not be blank"));
        }
        if self.session_ttl_hours == 0 {
            return Err(PanelError::config(
                "--session-ttl-hours must be at least 1; a zero-length session can never be used",
            ));
        }
        if self.session_ttl_hours > MAX_SESSION_TTL_HOURS {
            return Err(PanelError::config(format!(
                "--session-ttl-hours must be at most {MAX_SESSION_TTL_HOURS}; a longer session \
                expires past the end of the representable calendar"
            )));
        }

        Ok(ValidatedPanelArgs {
            public_origin,
            base_path,
            client_id,
            owner_login,
            authorize_url: parse_endpoint("--github-authorize-url", &self.github_authorize_url)?,
            token_url: parse_endpoint("--github-token-url", &self.github_token_url)?,
            api_url: parse_endpoint("--github-api-url", &self.github_api_url)?,
            session_ttl: Duration::hours(i64::from(self.session_ttl_hours)),
            daemon: daemon::resolve(
                &self.daemon_endpoint,
                &self.daemon_spki_pin,
                &self.pair_link_role,
                self.pair_link_ttl_seconds,
            )?,
        })
    }
}

pub(crate) fn validate_listen(listen: SocketAddr) -> Result<(), PanelError> {
    if !listen.ip().is_loopback() {
        return Err(PanelError::config(format!(
            "--listen must use a loopback address for daemon forwarding, got {listen}"
        )));
    }
    Ok(())
}

impl PanelConfig {
    /// The `redirect_uri` GitHub sends the authorization code back to.
    #[must_use]
    pub fn callback_url(&self) -> String {
        format!(
            "{}{}/auth/github/callback",
            self.public_origin, self.base_path
        )
    }

    /// Where the browser lands once a sign-in finishes.
    #[must_use]
    pub fn landing_path(&self) -> String {
        format!("{}/", self.base_path)
    }

    /// The `Path` attribute of the session cookie, which keeps the browser from
    /// offering it to anything else the daemon serves on the same origin.
    #[must_use]
    pub fn cookie_path(&self) -> &str {
        &self.base_path
    }

    /// Whether the panel is reached over TLS, and so whether the session cookie
    /// can carry `Secure`. A `Secure` cookie is dropped outright over plain
    /// HTTP, which would make local sign-in silently never work.
    #[must_use]
    pub fn cookie_is_secure(&self) -> bool {
        self.public_origin.starts_with("https://")
    }

    #[must_use]
    pub fn database_path(&self) -> PathBuf {
        self.state_dir.join("panel.sqlite3")
    }

    /// Whether `login` is the one `--owner-login` names.
    ///
    /// This decides who the owner binding is taken from the first time somebody
    /// signs in, and nothing after that. It is not the answer to "is this the
    /// owner", because a GitHub login can be renamed and the freed name
    /// registered by someone else; that answer lives in the owner binding,
    /// keyed on the immutable subject id. Conflating the two would hand the
    /// panel to whoever picked up the old name.
    ///
    /// Matched without regard to case, because GitHub treats logins that way
    /// and the flag is typed by hand.
    #[must_use]
    pub fn matches_owner_login(&self, login: &str) -> bool {
        login.eq_ignore_ascii_case(&self.owner_login)
    }
}

/// Reduce a mount point to a leading slash with no trailing one.
///
/// # Errors
/// Returns [`PanelError::Config`] when the value is not a usable subtree.
pub fn normalize_base_path(raw: &str) -> Result<String, PanelError> {
    let trimmed = raw.trim();
    if !trimmed.starts_with('/') {
        return Err(PanelError::config(format!(
            "--base-path must start with '/', got {trimmed:?}"
        )));
    }
    if !trimmed.is_ascii()
        || trimmed.contains([
            '?', '#', '{', '}', '*', '\\', '"', '\'', '<', '>', '&', ';', '`', '^',
        ])
        || trimmed
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
    {
        return Err(PanelError::config(format!(
            "--base-path must be a plain path, got {trimmed:?}"
        )));
    }
    let normalized = trimmed.trim_end_matches('/');
    if normalized.is_empty() {
        // Serving from the origin root would scope the session cookie to
        // everything else on that origin, including the daemon's own API.
        return Err(PanelError::config(
            "--base-path must name a subtree such as /panel, not the origin root",
        ));
    }
    if normalized.contains("//") {
        return Err(PanelError::config(format!(
            "--base-path must not contain an empty segment, got {trimmed:?}"
        )));
    }
    // A browser resolves `.` and `..` before it sends the request and before it
    // matches a cookie's `Path`, so a mount point containing them names one
    // subtree in the router and a different one in every request. The cookie
    // would then never be offered back and sign-in would never take, with
    // nothing to show for it.
    if normalized.split('/').any(is_url_dot_segment) {
        return Err(PanelError::config(format!(
            "--base-path must not contain a '.' or '..' segment, got {trimmed:?}"
        )));
    }
    if normalized
        .split('/')
        .any(|segment| segment.starts_with(':'))
    {
        return Err(PanelError::config(format!(
            "--base-path must not contain router capture syntax, got {trimmed:?}"
        )));
    }
    Ok(normalized.to_owned())
}

fn is_url_dot_segment(segment: &str) -> bool {
    matches!(segment, "." | "..")
        || segment.eq_ignore_ascii_case("%2e")
        || segment.eq_ignore_ascii_case(".%2e")
        || segment.eq_ignore_ascii_case("%2e.")
        || segment.eq_ignore_ascii_case("%2e%2e")
}

/// Reduce `--public-origin` to a scheme, host, and port with no trailing slash.
///
/// # Errors
/// Returns [`PanelError::Config`] when the value carries anything but an
/// origin, or is served over plain HTTP from somewhere other than loopback.
pub fn normalize_public_origin(raw: &str) -> Result<String, PanelError> {
    if raw.chars().any(char::is_control) {
        return Err(PanelError::config(
            "--public-origin must not contain control characters",
        ));
    }
    let parsed = Url::parse(raw.trim())
        .map_err(|error| PanelError::config(format!("--public-origin {raw:?}: {error}")))?;

    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(PanelError::config(format!(
            "--public-origin must be http or https, got {:?}",
            parsed.scheme()
        )));
    }
    if parsed.path() != "/" || parsed.query().is_some() || parsed.fragment().is_some() {
        return Err(PanelError::config(format!(
            "--public-origin must be an origin with no path, got {raw:?}. The mount point is \
             --base-path"
        )));
    }
    let host = parsed
        .host()
        .ok_or_else(|| PanelError::config(format!("--public-origin {raw:?} has no host")))?;
    if parsed.scheme() == "http" && !is_loopback_host(&host) {
        // The session cookie cannot carry `Secure` over plain HTTP, so a
        // non-loopback HTTP origin would hand every session to the network.
        return Err(PanelError::config(format!(
            "--public-origin must use https away from loopback, got {raw:?}"
        )));
    }

    // `Host` rather than `host_str`, because the latter hands back a v6 address
    // without its brackets and the origin would come out as `http://::1:8787`,
    // which is not a URL. Every absolute URL the panel builds starts here,
    // including the OAuth `redirect_uri`.
    let mut origin = format!("{}://{host}", parsed.scheme());
    if let Some(port) = parsed.port() {
        origin.push(':');
        origin.push_str(&port.to_string());
    }
    Ok(origin)
}

/// Whether the panel is reached over the loopback interface, and so may be
/// served without TLS.
///
/// Asked of the parsed host rather than its text, so `127.0.0.2` and an
/// abbreviated v6 loopback count without needing to be spelled out.
fn is_loopback_host(host: &Host<&str>) -> bool {
    match host {
        Host::Domain(domain) => domain.eq_ignore_ascii_case("localhost"),
        Host::Ipv4(address) => address.is_loopback(),
        Host::Ipv6(address) => address.is_loopback(),
    }
}

pub(crate) fn parse_endpoint(flag: &str, raw: &str) -> Result<Url, PanelError> {
    if raw.chars().any(char::is_control) {
        return Err(PanelError::config(format!(
            "{flag} must not contain control characters"
        )));
    }
    let parsed = Url::parse(raw.trim())
        .map_err(|_| PanelError::config(format!("{flag} must be a valid URL")))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(PanelError::config(format!("{flag} must be http or https")));
    }
    if !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err(PanelError::config(format!(
            "{flag} must not contain URL credentials, a query, or a fragment"
        )));
    }
    let host = parsed
        .host()
        .ok_or_else(|| PanelError::config(format!("{flag} must contain a host")))?;
    if parsed.scheme() == "http" && !is_loopback_host(&host) {
        return Err(PanelError::config(format!(
            "{flag} must use https away from loopback"
        )));
    }
    Ok(parsed)
}

#[cfg(test)]
mod tests;
