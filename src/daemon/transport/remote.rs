use std::{num::NonZeroU64, str::FromStr};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use clap::{Args, Subcommand, ValueEnum};
use serde::Serialize;
use uuid::Uuid;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::db::DaemonDb;
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::remote::{
    validate_remote_serve_config, RemoteAccessScope, RemoteAcmeChallenge, RemoteDaemonServeConfig,
    RemoteDnsProvider, RemoteRole,
};
use crate::daemon::remote_identity::{
    remote_token_hint, RemoteAuditEvent, RemoteAuditOutcome, RemoteAuditScopeDecision,
    RemoteBearerToken, RemoteStoredClient,
};
use crate::daemon::remote_pairing::{RemotePairingCode, RemotePairingRecord};
use crate::daemon::service::DaemonServeConfig;
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::control::{adopt_daemon_root_for_transport_command, print_json};

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
    /// Install a hardened Linux systemd service.
    InstallSystemd(DaemonRemoteSystemdArgs),
    /// Remove the Linux systemd service.
    UninstallSystemd(DaemonRemoteSystemdArgs),
    /// Show Linux systemd service status.
    Status(DaemonRemoteSystemdArgs),
}

impl Execute for DaemonRemoteCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Pair { command } => command.execute(context),
            Self::Clients { command } => command.execute(context),
            Self::Serve(args) => {
                args.remote_auth_scaffold_config()?;
                Err(remote_execution_reserved_error())
            }
            Self::Acme { .. }
            | Self::Doctor
            | Self::InstallSystemd(_)
            | Self::UninstallSystemd(_)
            | Self::Status(_) => Err(remote_execution_reserved_error()),
        }
    }
}

fn remote_execution_reserved_error() -> CliError {
    CliErrorKind::workflow_parse(
        "remote daemon execution is reserved for the next implementation phase",
    )
    .into()
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
        let record = RemotePairingRecord::new(
            pairing_id,
            role,
            &requested_scopes,
            code.expose(),
            created_at,
            expires_at.as_str(),
        )
        .map_err(|error| CliErrorKind::workflow_parse(error.to_string()))?;
        let stored = db.create_remote_pairing_code(&record, audit_event_id)?;
        Ok(DaemonRemotePairCreateResponse {
            pairing_id: stored.pairing_id,
            code: code.expose().to_string(),
            role: stored.role.as_str().to_string(),
            scopes: stored
                .scopes
                .iter()
                .map(|scope| scope.as_str().to_string())
                .collect(),
            created_at: stored.created_at,
            expires_at: stored.expires_at,
            ttl_seconds: self.ttl.as_secs(),
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
}

fn open_remote_daemon_db() -> Result<DaemonDb, CliError> {
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

impl Execute for DaemonRemoteClientsCommand {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_transport_command("daemon-remote-clients");
        let db = open_remote_daemon_db()?;
        let now = utc_now();
        let audit_event_id = format!("remote-clients-{}-{}", self.action_label(), Uuid::new_v4());
        match self {
            Self::List => {
                let response =
                    self.list_clients_with(&db, audit_event_id.as_str(), now.as_str())?;
                print_json(&response)?;
            }
            Self::Revoke(args) => {
                let response =
                    args.revoke_client_with(&db, audit_event_id.as_str(), now.as_str())?;
                print_json(&response)?;
            }
            Self::Rotate(args) => {
                let token = RemoteBearerToken::generate();
                let response = args.rotate_client_with(
                    &db,
                    token.expose(),
                    audit_event_id.as_str(),
                    now.as_str(),
                )?;
                print_json(&response)?;
            }
        }
        Ok(0)
    }
}

impl DaemonRemoteClientsCommand {
    /// List paired remote clients without exposing token hashes or raw tokens.
    ///
    /// # Errors
    /// Returns [`CliError`] when database reads or audit writes fail.
    pub(crate) fn list_clients_with(
        &self,
        db: &DaemonDb,
        audit_event_id: &str,
        now: &str,
    ) -> Result<DaemonRemoteClientsListResponse, CliError> {
        let Self::List = self else {
            return Err(CliErrorKind::workflow_parse("remote clients command must be list").into());
        };
        let clients = db
            .list_remote_clients()?
            .iter()
            .map(DaemonRemoteClientSummary::from_stored_client)
            .collect();
        record_remote_clients_audit(
            db,
            audit_event_id,
            now,
            None,
            "remote.clients.list",
            RemoteAuditOutcome::Success,
            None,
        )?;
        Ok(DaemonRemoteClientsListResponse { clients })
    }

    #[must_use]
    const fn action_label(&self) -> &'static str {
        match self {
            Self::List => "list",
            Self::Revoke(_) => "revoke",
            Self::Rotate(_) => "rotate",
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteClientIdArgs {
    /// Remote client identifier.
    #[arg(long)]
    pub client_id: String,
}

impl DaemonRemoteClientIdArgs {
    /// Revoke a paired remote client.
    ///
    /// # Errors
    /// Returns [`CliError`] when the client is unknown, already revoked, or
    /// persistence/audit fails.
    pub(crate) fn revoke_client_with(
        &self,
        db: &DaemonDb,
        audit_event_id: &str,
        revoked_at: &str,
    ) -> Result<DaemonRemoteClientRevokeResponse, CliError> {
        let client_id = self.trimmed_client_id()?;
        let changed = db.revoke_remote_client(client_id, revoked_at)?;
        if !changed {
            record_remote_clients_audit(
                db,
                audit_event_id,
                revoked_at,
                Some(client_id),
                "remote.clients.revoke",
                RemoteAuditOutcome::Failure,
                Some("remote client not found or already revoked"),
            )?;
            return Err(CliErrorKind::workflow_parse(format!(
                "remote client '{client_id}' not found or already revoked"
            ))
            .into());
        }
        record_remote_clients_audit(
            db,
            audit_event_id,
            revoked_at,
            Some(client_id),
            "remote.clients.revoke",
            RemoteAuditOutcome::Success,
            None,
        )?;
        Ok(DaemonRemoteClientRevokeResponse {
            client_id: client_id.to_string(),
            revoked_at: revoked_at.to_string(),
        })
    }

    /// Rotate a paired remote client's bearer token.
    ///
    /// # Errors
    /// Returns [`CliError`] when the client is unknown, revoked, the new token
    /// is invalid, or persistence/audit fails.
    pub(crate) fn rotate_client_with(
        &self,
        db: &DaemonDb,
        token: &str,
        audit_event_id: &str,
        rotated_at: &str,
    ) -> Result<DaemonRemoteClientRotateResponse, CliError> {
        let client_id = self.trimmed_client_id()?;
        let changed = db.rotate_remote_client_token(client_id, token, rotated_at)?;
        if !changed {
            record_remote_clients_audit(
                db,
                audit_event_id,
                rotated_at,
                Some(client_id),
                "remote.clients.rotate",
                RemoteAuditOutcome::Failure,
                Some("remote client not found or revoked"),
            )?;
            return Err(CliErrorKind::workflow_parse(format!(
                "remote client '{client_id}' not found or revoked"
            ))
            .into());
        }
        record_remote_clients_audit(
            db,
            audit_event_id,
            rotated_at,
            Some(client_id),
            "remote.clients.rotate",
            RemoteAuditOutcome::Success,
            None,
        )?;
        Ok(DaemonRemoteClientRotateResponse {
            client_id: client_id.to_string(),
            token: token.to_string(),
            token_hint: remote_token_hint(token),
            rotated_at: rotated_at.to_string(),
        })
    }

    fn trimmed_client_id(&self) -> Result<&str, CliError> {
        let client_id = self.client_id.trim();
        if client_id.is_empty() {
            return Err(CliErrorKind::workflow_parse("remote client id is required").into());
        }
        Ok(client_id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteClientsListResponse {
    pub clients: Vec<DaemonRemoteClientSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteClientSummary {
    pub client_id: String,
    pub display_name: String,
    pub platform: String,
    pub role: String,
    pub scopes: Vec<String>,
    pub token_hint: String,
    pub created_at: String,
    pub last_seen_at: Option<String>,
    pub revoked_at: Option<String>,
    pub rotated_at: Option<String>,
}

impl DaemonRemoteClientSummary {
    fn from_stored_client(client: &RemoteStoredClient) -> Self {
        Self {
            client_id: client.client_id.clone(),
            display_name: client.display_name.clone(),
            platform: client.platform.clone(),
            role: client.role.as_str().to_string(),
            scopes: client
                .scopes
                .iter()
                .map(|scope| scope.as_str().to_string())
                .collect(),
            token_hint: client.token_hint.clone(),
            created_at: client.created_at.clone(),
            last_seen_at: client.last_seen_at.clone(),
            revoked_at: client.revoked_at.clone(),
            rotated_at: client.rotated_at.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteClientRevokeResponse {
    pub client_id: String,
    pub revoked_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct DaemonRemoteClientRotateResponse {
    pub client_id: String,
    pub token: String,
    pub token_hint: String,
    pub rotated_at: String,
}

fn record_remote_clients_audit(
    db: &DaemonDb,
    event_id: &str,
    recorded_at: &str,
    client_id: Option<&str>,
    route_or_method: &str,
    outcome: RemoteAuditOutcome,
    error_detail: Option<&str>,
) -> Result<(), CliError> {
    db.record_remote_audit_event(&RemoteAuditEvent::new(
        event_id,
        recorded_at,
        None,
        client_id,
        route_or_method,
        RemoteAccessScope::Admin,
        RemoteAuditScopeDecision::Allowed,
        outcome,
        None,
        error_detail,
    ))
}

#[derive(Debug, Clone, Subcommand)]
pub enum DaemonRemoteAcmeCommand {
    /// Show ACME account, challenge, and certificate status.
    Status,
    /// Renew the active certificate.
    Renew,
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteSystemdArgs {
    /// systemd unit name.
    #[arg(long, default_value = "harness-remote-daemon")]
    pub unit: String,
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
            Self::Cloudflare => "cloudflare",
            Self::Route53 => "route53",
            Self::Exec => "exec",
        }
    }
}

impl From<DaemonRemoteDnsProvider> for RemoteDnsProvider {
    fn from(value: DaemonRemoteDnsProvider) -> Self {
        match value {
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
}

impl DaemonRemoteRole {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Admin => "admin",
            Self::Operator => "operator",
            Self::Viewer => "viewer",
        }
    }
}

impl From<DaemonRemoteRole> for RemoteRole {
    fn from(value: DaemonRemoteRole) -> Self {
        match value {
            DaemonRemoteRole::Admin => Self::Admin,
            DaemonRemoteRole::Operator => Self::Operator,
            DaemonRemoteRole::Viewer => Self::Viewer,
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
}

impl DaemonRemoteScope {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Write => "write",
            Self::Admin => "admin",
        }
    }
}

impl From<DaemonRemoteScope> for RemoteAccessScope {
    fn from(value: DaemonRemoteScope) -> Self {
        match value {
            DaemonRemoteScope::Read => Self::Read,
            DaemonRemoteScope::Write => Self::Write,
            DaemonRemoteScope::Admin => Self::Admin,
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
