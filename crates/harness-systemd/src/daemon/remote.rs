use std::error::Error;
use std::fmt;

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
pub struct RemoteDaemonServeConfig {
    pub domain: String,
    pub host: String,
    pub https_port: u16,
    pub http_port: u16,
    pub acme_email: String,
    pub acme_challenge: RemoteAcmeChallenge,
    pub acme_dns_provider: Option<RemoteDnsProvider>,
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
            Ok(())
        }
    }
}
