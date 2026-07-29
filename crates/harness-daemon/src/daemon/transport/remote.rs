use std::path::PathBuf;

use clap::{Args, Subcommand, ValueEnum};
use serde::Serialize;
use uuid::Uuid;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::db::DaemonDb;
use crate::daemon::http::companion::CompanionAuthToken;
use crate::daemon::http::{
    CompanionRouteConfig, DEFAULT_COMPANION_PATH_PREFIX, DaemonHttpAuthMode,
    RemoteRequestLimitConfig,
};
use crate::daemon::remote::{
    RemoteAccessScope, RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider, RemoteRole,
    validate_remote_serve_config,
};
mod values;
pub use values::{DaemonRemotePairTtl, DaemonRemoteRole, DaemonRemoteScope};

use crate::daemon::remote_pairing::{
    RemotePairingCode, RemotePairingCreateParams, create_remote_pairing, pairing_expires_at,
};
use crate::daemon::service::DaemonServeConfig;
use crate::daemon::state;
use crate::reviews::ReviewsQueryRequest;
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::control::{adopt_daemon_root_for_transport_command, print_json};
use super::remote_doctor::execute_remote_doctor;
use super::remote_pair_reviews::DaemonRemotePairReviewsArgs;
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
    /// Loopback origin of a companion web service.
    #[arg(long, hide = true)]
    pub companion_upstream: Option<String>,
    /// Private credential file for the daemon-to-companion loopback hop.
    #[arg(long, hide = true)]
    pub companion_auth_token_file: Option<PathBuf>,
    /// Internal marker emitted by the systemd socket-activated deployment.
    #[arg(long, hide = true)]
    pub companion_systemd_socket_activated: bool,
    /// Path subtree handed to the companion service.
    #[arg(long, default_value = DEFAULT_COMPANION_PATH_PREFIX, hide = true)]
    pub companion_path_prefix: String,
}

impl DaemonRemoteServeArgs {
    /// Build the static remote serve config used by later implementation phases.
    ///
    /// # Errors
    /// Returns [`CliError`] when remote TLS, ACME, or companion settings are invalid.
    pub fn contract_config(&self) -> Result<RemoteDaemonServeConfig, CliError> {
        self.companion_config()?;
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
    /// # Errors
    /// Returns [`CliError`] when the remote TLS, ACME, or companion contract is invalid.
    pub fn remote_auth_scaffold_config(&self) -> Result<DaemonServeConfig, CliError> {
        let remote_config = self.contract_config()?;
        Ok(DaemonServeConfig {
            host: remote_config.host,
            port: remote_config.https_port,
            auth_mode: DaemonHttpAuthMode::Remote,
            remote_domain: Some(remote_config.domain),
            remote_request_limits: Some(RemoteRequestLimitConfig::default()),
            companion: self.companion_config()?,
            ..DaemonServeConfig::default()
        })
    }

    fn companion_config(&self) -> Result<Option<CompanionRouteConfig>, CliError> {
        if self.companion_systemd_socket_activated != self.companion_upstream.is_some() {
            let message = if self.companion_upstream.is_some() {
                "companion routing is supported only through the harness-systemd socket-activated deployment"
            } else {
                "internal companion socket-activation marker requires --companion-upstream"
            };
            return Err(CliErrorKind::workflow_parse(message).into());
        }
        let (upstream, token_file) = match (
            self.companion_upstream.as_deref(),
            self.companion_auth_token_file.as_deref(),
        ) {
            (None, None) => return Ok(None),
            (Some(_), None) => {
                return Err(CliErrorKind::workflow_parse(
                    "--companion-auth-token-file is required with --companion-upstream",
                )
                .into());
            }
            (None, Some(_)) => {
                return Err(CliErrorKind::workflow_parse(
                    "--companion-auth-token-file requires --companion-upstream",
                )
                .into());
            }
            (Some(upstream), Some(token_file)) => (upstream, token_file),
        };
        let auth_token = CompanionAuthToken::read_private_file(token_file)
            .map_err(|error| CliErrorKind::workflow_parse(error.to_string()))?;
        CompanionRouteConfig::new(upstream, self.companion_path_prefix.as_str(), auth_token)
            .map(Some)
            .map_err(|error| CliErrorKind::workflow_parse(error.to_string()).into())
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
        let expires_at = pairing_expires_at(created_at, self.ttl.as_secs())?;
        let reviews_query = self.reviews_query()?;
        let requested_scopes = self
            .scopes
            .iter()
            .copied()
            .map(RemoteAccessScope::from)
            .collect::<Vec<_>>();
        let created = create_remote_pairing(
            db,
            &RemotePairingCreateParams {
                pairing_id,
                audit_event_id,
                code,
                created_at,
                expires_at: expires_at.as_str(),
                ttl_seconds: self.ttl.as_secs(),
                role: RemoteRole::from(self.role),
                requested_scopes: &requested_scopes,
                reviews_query: reviews_query.as_ref(),
                minted_for: None,
                // Created on the host, so no remote client owns it.
                minted_by: None,
                extra_audit: None,
            },
        )?;
        Ok(DaemonRemotePairCreateResponse {
            pairing_id: created.pairing_id,
            // The operator ran this on the host, so the raw code goes back to
            // the terminal that asked for it. The mint route deliberately does
            // not do this.
            code: code.expose().to_string(),
            role: created.role,
            scopes: created.scopes,
            created_at: created.created_at,
            expires_at: created.expires_at,
            ttl_seconds: created.ttl_seconds,
            endpoint: created.endpoint,
            server_spki_sha256: created.server_spki_sha256,
            pairing_url: created.pairing_url,
            reviews_query: created.reviews_query,
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
