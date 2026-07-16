use clap::{Args, ValueEnum};

use crate::daemon::remote::{
    RemoteAcmeChallenge, RemoteDaemonServeConfig, RemoteDnsProvider, validate_remote_serve_config,
};
use crate::errors::{CliError, CliErrorKind};

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteServeArgs {
    /// Public DNS name clients use for the remote daemon.
    #[arg(long)]
    pub domain: String,
    /// Network interface to bind.
    #[arg(long, default_value = "0.0.0.0")]
    pub host: String,
    /// HTTPS/WSS listener port.
    #[arg(long, default_value_t = 443)]
    pub https_port: u16,
    /// HTTP listener port used for HTTP-01.
    #[arg(long, default_value_t = 80)]
    pub http_port: u16,
    /// ACME account email address.
    #[arg(long)]
    pub acme_email: String,
    /// ACME challenge type.
    #[arg(long, value_enum, default_value = "tls-alpn")]
    pub acme_challenge: DaemonRemoteAcmeChallenge,
    /// DNS provider used by DNS-01.
    #[arg(long, value_enum)]
    pub acme_dns_provider: Option<DaemonRemoteDnsProvider>,
}

impl DaemonRemoteServeArgs {
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
}

#[cfg(test)]
#[derive(Debug, Clone, clap::Subcommand)]
pub enum DaemonRemoteCommand {
    InstallSystemd(super::remote_systemd::DaemonRemoteSystemdInstallArgs),
    UpgradeSystemd(super::remote_systemd_upgrade::DaemonRemoteSystemdUpgradeArgs),
    RollbackSystemd(super::remote_systemd_upgrade::DaemonRemoteSystemdRollbackArgs),
    RecoverSystemd(super::remote_systemd_upgrade::DaemonRemoteSystemdRecoverArgs),
    UninstallSystemd(super::remote_systemd::DaemonRemoteSystemdArgs),
    Status(super::remote_systemd::DaemonRemoteSystemdArgs),
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
