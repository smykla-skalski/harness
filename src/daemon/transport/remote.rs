use std::{num::NonZeroU64, str::FromStr};

use clap::{Args, Subcommand, ValueEnum};

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::remote::{
    RemoteAccessScope, RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider, RemoteRole,
    validate_remote_serve_config,
};
use crate::daemon::service::DaemonServeConfig;
use crate::errors::{CliError, CliErrorKind};

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
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        if let Self::Serve(args) = self {
            args.daemon_serve_config()?;
        }
        Err(CliErrorKind::workflow_parse(
            "remote daemon execution is reserved for the next implementation phase",
        )
        .into())
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

    /// Build the daemon service config for remote serve execution.
    ///
    /// # Errors
    /// Returns [`CliError`] when the remote TLS or ACME contract is invalid.
    pub fn daemon_serve_config(&self) -> Result<DaemonServeConfig, CliError> {
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
