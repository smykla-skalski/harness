use std::{num::NonZeroU64, str::FromStr};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use clap::{Args, Subcommand, ValueEnum};
use serde::Serialize;
use uuid::Uuid;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::db::DaemonDb;
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::http::RemoteRequestLimitConfig;
use crate::daemon::remote::{
    RemoteAccessScope, RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider, RemoteRole,
    validate_remote_serve_config,
};
use crate::daemon::remote_pairing::{RemotePairingCode, RemotePairingRecord};
use crate::daemon::service::DaemonServeConfig;
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::ReviewsQueryRequest;
use crate::workspace::utc_now;

use super::control::{adopt_daemon_root_for_transport_command, print_json};
use super::remote_doctor::execute_remote_doctor;
use super::remote_pair_reviews::DaemonRemotePairReviewsArgs;
use super::remote_pairing_invitation::build_remote_pairing_invitation;
use super::remote_serve::execute_remote_serve;

#[derive(Debug, Clone, Subcommand)]
pub enum DaemonRemoteCommand {
    /// Serve the remote daemon over HTTPS/WSS.
    Serve(DaemonRemoteServeArgs),
    /// Create or manage one-time pairing flows.
    Pair {
        #[command(subcommand)]
        command: DaemonRemotePairCommand,
    },
    /// List, revoke, or rotate paired remote clients.
    Clients {
        #[command(subcommand)]
        command: DaemonRemoteClientsCommand,
    },
    /// Inspect or renew ACME certificate state.
    Acme {
        #[command(subcommand)]
        command: DaemonRemoteAcmeCommand,
    },
    /// Run remote daemon diagnostics.
    Doctor,
}

impl Execute for DaemonRemoteCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Pair { command } => command.execute(context),
            Self::Clients { command } => command.execute(context),
            Self::Acme { command } => command.execute(context),
            Self::Serve(args) => execute_remote_serve(args),
            Self::Doctor => execute_remote_doctor(),
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteServeArgs {
    /// Public DNS name clients use for the remote daemon.
    #[arg(long)]
    pub domain: String,
    /// Network interface to bind. Remote mode defaults to all IPv4 interfaces.
    #[arg(long, default_value = "0.0.0.0")]
    pub host: String,
    /// HTTPS/WSS listener port.
    #[arg(long, default_value_t = 443)]
    pub https_port: u16,
    /// HTTP listener port used when issuing certificates with HTTP-01.
    #[arg(long, default_value_t = 80)]
    pub http_port: u16,
    /// ACME account email address.
    #[arg(long)]
    pub acme_email: String,
    /// ACME challenge type used for certificate issuance.
    #[arg(long, value_enum, default_value = "tls-alpn")]
    pub acme_challenge: DaemonRemoteAcmeChallenge,
    /// DNS provider used by DNS-01 challenges.
    #[arg(long, value_enum)]
    pub acme_dns_provider: Option<DaemonRemoteDnsProvider>,
}

impl DaemonRemoteServeArgs {
    /// Build the static remote serve config used by later implementation phases.
    ///
    /// # Errors
    /// Returns [`CliError`] when required remote TLS or ACME settings are absent.
    pub fn contract_config(&self) -> Result<RemoteDaemonServeConfig, CliError> {
        let config = RemoteDaemonServeConfig {
            domain: self.domain.trim().to_string(),
            host: self.host.trim().to_string(),
            https_port: self.https_port,
            http_port: self.http_port,
            acme_email: self.acme_email.trim().to_string(),
            acme_challenge: self.acme_challenge.into(),
            acme_dns_provider: self.acme_dns_provider.map(Into::into),
        };
        validate_remote_serve_config(&config)
            .map_err(|error| CliError::from(CliErrorKind::workflow_parse(error.to_string())))?;
        Ok(config)
    }

    /// Build the remote-auth scaffold config for the future remote serve path.
    ///
    /// This selects [`DaemonHttpAuthMode::Remote`] and preserves the public
    /// remote bind host from the remote contract. It is not passed to the
    /// current local [`crate::daemon::service::serve`] path, whose validation
    /// intentionally remains loopback-only.
    ///
    /// # Errors
    /// Returns [`CliError`] when the remote TLS or ACME contract is invalid.
    pub fn remote_auth_scaffold_config(&self) -> Result<DaemonServeConfig, CliError> {
        let remote_config = self.contract_config()?;
        Ok(DaemonServeConfig {
            host: remote_config.host,
            port: remote_config.https_port,
            auth_mode: DaemonHttpAuthMode::Remote,
            remote_domain: Some(remote_config.domain),
            remote_request_limits: Some(RemoteRequestLimitConfig::default()),
            ..DaemonServeConfig::default()
        })
    }
}

#[derive(Debug, Clone, Subcommand)]
pub enum DaemonRemotePairCommand {
    /// Create a one-time remote pairing code.
    Create(DaemonRemotePairCreateArgs),
}

impl Execute for DaemonRemotePairCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Create(args) => args.execute(context),
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemotePairCreateArgs {
    /// Role granted to the paired client.
    #[arg(long, value_enum, default_value = "admin")]
    pub role: DaemonRemoteRole,
    /// Optional explicit scopes. Defaults to the selected role's scopes.
    #[arg(long, value_enum, value_delimiter = ',')]
    pub scopes: Vec<DaemonRemoteScope>,
    /// Pairing code time-to-live.
    #[arg(long, default_value = "10m")]
    pub ttl: DaemonRemotePairTtl,
    #[command(flatten)]
    pub(super) reviews: DaemonRemotePairReviewsArgs,
}

impl Execute for DaemonRemotePairCreateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_transport_command("daemon-remote-pair-create");
        let db = open_remote_daemon_db()?;
        let code = RemotePairingCode::generate();
        let pairing_id = format!("pairing-{}", Uuid::new_v4());
        let audit_event_id = format!("remote-pair-create-{}", Uuid::new_v4());
        let created_at = utc_now();
        let response = self.create_pairing_with(
            &db,
            pairing_id.as_str(),
            audit_event_id.as_str(),
            &code,
            created_at.as_str(),
        )?;
        print_json(&response)?;
        Ok(0)
    }
}

impl DaemonRemotePairCreateArgs {
    /// Create a durable pairing record and return the one-time operator
    /// response containing the raw code.
    ///
    /// # Errors
    /// Returns [`CliError`] when scope expansion, expiry calculation, or
    /// persistence fails.
    pub(crate) fn create_pairing_with(
        &self,
        db: &DaemonDb,
        pairing_id: &str,
        audit_event_id: &str,
        code: &RemotePairingCode,
        created_at: &str,
    ) -> Result<DaemonRemotePairCreateResponse, CliError> {
        let role = RemoteRole::from(self.role);
        let requested_scopes = self
            .scopes
            .iter()
            .copied()
            .map(RemoteAccessScope::from)
            .collect::<Vec<_>>();
        let expires_at = expires_at_from_ttl(created_at, self.ttl.as_secs())?;
        let reviews_query = self.reviews_query()?;
        let record = RemotePairingRecord::new_with_reviews_query(
            pairing_id,
            role,
            &requested_scopes,
            code.expose(),
            created_at,
            expires_at.as_str(),
            reviews_query.as_ref(),
        )
        .map_err(|error| CliErrorKind::workflow_parse(error.to_string()))?;
        let role = record.role.as_str().to_string();
        let scopes = record
            .scopes
            .iter()
            .map(|scope| scope.as_str().to_string())
            .collect::<Vec<_>>();
        let invitation = build_remote_pairing_invitation(
            db,
            code.expose(),
            role.as_str(),
            &scopes,
            record.expires_at.as_str(),
        )?;
        let stored = db.create_remote_pairing_code(&record, audit_event_id)?;
        Ok(DaemonRemotePairCreateResponse {
            pairing_id: stored.pairing_id,
            code: code.expose().to_string(),
            role,
            scopes,
            created_at: stored.created_at,
            expires_at: stored.expires_at,
            ttl_seconds: self.ttl.as_secs(),
            endpoint: invitation.endpoint,
            server_spki_sha256: invitation.server_spki_sha256,
            pairing_url: invitation.pairing_url,
            reviews_query: stored.reviews_query,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemotePairCreateResponse {
    pub pairing_id: String,
    pub code: String,
    pub role: String,
    pub scopes: Vec<String>,
    pub created_at: String,
    pub expires_at: String,
    pub ttl_seconds: u64,
    pub endpoint: String,
    pub server_spki_sha256: String,
    pub pairing_url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reviews_query: Option<ReviewsQueryRequest>,
}

pub(super) fn open_remote_daemon_db() -> Result<DaemonDb, CliError> {
    state::ensure_daemon_dirs()?;
    DaemonDb::open(&state::daemon_root().join("harness.db"))
}

fn expires_at_from_ttl(created_at: &str, ttl_seconds: u64) -> Result<String, CliError> {
    let created_at = DateTime::parse_from_rfc3339(created_at)
        .map_err(|error| CliErrorKind::workflow_parse(format!("parse pairing time: {error}")))?
        .with_timezone(&Utc);
    let ttl_seconds = i64::try_from(ttl_seconds)
        .map_err(|_| CliErrorKind::workflow_parse("pairing ttl value is too large"))?;
    let expires_at = created_at
        .checked_add_signed(ChronoDuration::seconds(ttl_seconds))
        .ok_or_else(|| CliErrorKind::workflow_parse("pairing ttl value is too large"))?;
    Ok(expires_at.format("%Y-%m-%dT%H:%M:%SZ").to_string())
}

#[derive(Debug, Clone, Subcommand)]
pub enum DaemonRemoteClientsCommand {
    /// List paired remote clients.
    List,
    /// Revoke a paired remote client.
    Revoke(DaemonRemoteClientIdArgs),
    /// Rotate a paired remote client's token.
    Rotate(DaemonRemoteClientIdArgs),
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteClientIdArgs {
    /// Remote client identifier.
    #[arg(long)]
    pub client_id: String,
}

#[derive(Debug, Clone, Subcommand)]
pub enum DaemonRemoteAcmeCommand {
    /// Show ACME account, challenge, and certificate status.
    Status,
    /// Renew the active certificate.
    Renew,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DaemonRemoteAcmeChallenge {
    #[value(name = "tls-alpn")]
    TlsAlpn,
    #[value(name = "http")]
    Http,
    #[value(name = "dns")]
    Dns,
}

impl DaemonRemoteAcmeChallenge {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TlsAlpn => "tls-alpn",
            Self::Http => "http",
            Self::Dns => "dns",
        }
    }
}

impl From<DaemonRemoteAcmeChallenge> for RemoteAcmeChallenge {
    fn from(value: DaemonRemoteAcmeChallenge) -> Self {
        match value {
            DaemonRemoteAcmeChallenge::TlsAlpn => Self::TlsAlpn,
            DaemonRemoteAcmeChallenge::Http => Self::Http,
            DaemonRemoteAcmeChallenge::Dns => Self::Dns,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DaemonRemoteDnsProvider {
    #[value(name = "aftermarket")]
    Aftermarket,
    #[value(name = "cloudflare")]
    Cloudflare,
    #[value(name = "route53")]
    Route53,
    #[value(name = "exec")]
    Exec,
}

impl DaemonRemoteDnsProvider {
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

impl From<DaemonRemoteDnsProvider> for RemoteDnsProvider {
    fn from(value: DaemonRemoteDnsProvider) -> Self {
        match value {
            DaemonRemoteDnsProvider::Aftermarket => Self::Aftermarket,
            DaemonRemoteDnsProvider::Cloudflare => Self::Cloudflare,
            DaemonRemoteDnsProvider::Route53 => Self::Route53,
            DaemonRemoteDnsProvider::Exec => Self::Exec,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DaemonRemoteRole {
    #[value(name = "admin")]
    Admin,
    #[value(name = "operator")]
    Operator,
    #[value(name = "viewer")]
    Viewer,
    #[value(name = "execution-coordinator")]
    ExecutionCoordinator,
}

impl DaemonRemoteRole {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Admin => "admin",
            Self::Operator => "operator",
            Self::Viewer => "viewer",
            Self::ExecutionCoordinator => "execution-coordinator",
        }
    }
}

impl From<DaemonRemoteRole> for RemoteRole {
    fn from(value: DaemonRemoteRole) -> Self {
        match value {
            DaemonRemoteRole::Admin => Self::Admin,
            DaemonRemoteRole::Operator => Self::Operator,
            DaemonRemoteRole::Viewer => Self::Viewer,
            DaemonRemoteRole::ExecutionCoordinator => Self::ExecutionCoordinator,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DaemonRemoteScope {
    #[value(name = "read")]
    Read,
    #[value(name = "write")]
    Write,
    #[value(name = "admin")]
    Admin,
    #[value(name = "execute")]
    Execute,
}

impl DaemonRemoteScope {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Write => "write",
            Self::Admin => "admin",
            Self::Execute => "execute",
        }
    }
}

impl From<DaemonRemoteScope> for RemoteAccessScope {
    fn from(value: DaemonRemoteScope) -> Self {
        match value {
            DaemonRemoteScope::Read => Self::Read,
            DaemonRemoteScope::Write => Self::Write,
            DaemonRemoteScope::Admin => Self::Admin,
            DaemonRemoteScope::Execute => Self::Execute,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DaemonRemotePairTtl {
    seconds: NonZeroU64,
}

impl DaemonRemotePairTtl {
    #[must_use]
    pub const fn as_secs(self) -> u64 {
        self.seconds.get()
    }
}

impl FromStr for DaemonRemotePairTtl {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let (digits, multiplier) = if let Some(digits) = value.strip_suffix('s') {
            (digits, 1)
        } else if let Some(digits) = value.strip_suffix('m') {
            (digits, 60)
        } else if let Some(digits) = value.strip_suffix('h') {
            (digits, 60 * 60)
        } else {
            return Err("pairing ttl must end with s, m, or h".to_string());
        };

        if digits.is_empty() || !digits.chars().all(|character| character.is_ascii_digit()) {
            return Err("pairing ttl must start with a positive integer".to_string());
        }

        let count = digits
            .parse::<u64>()
            .map_err(|_| "pairing ttl value is too large".to_string())?;
        let seconds = count
            .checked_mul(multiplier)
            .ok_or_else(|| "pairing ttl value is too large".to_string())?;
        let seconds = NonZeroU64::new(seconds)
            .ok_or_else(|| "pairing ttl must be greater than zero".to_string())?;

        Ok(Self { seconds })
    }
}
