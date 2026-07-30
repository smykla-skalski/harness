use std::env;
use std::fmt;

use async_trait::async_trait;
use http::Method;

#[path = "remote_acme_dns_aftermarket.rs"]
mod aftermarket;
#[path = "remote_acme_dns_cloudflare.rs"]
mod cloudflare;
#[path = "remote_acme_dns_exec.rs"]
mod exec;
#[path = "remote_acme_dns_route53.rs"]
mod route53;
#[path = "remote_acme_dns_visibility.rs"]
mod visibility;

pub use aftermarket::{AftermarketDns01Lease, AftermarketDns01Provider};
pub use cloudflare::CloudflareDns01Lease;
pub use cloudflare::CloudflareDns01Provider;
#[cfg(test)]
pub use exec::RemoteDnsCommandRunner;
pub use exec::{ExecDns01Lease, ExecDns01Provider, TokioRemoteDnsCommandRunner};
pub use route53::Route53Dns01Lease;
pub use route53::{AwsRoute53Credentials, Route53Dns01Provider};
#[cfg(test)]
pub use visibility::{DnsTxtRecordState, DnsTxtVisibilityWaiter};

use super::remote_acme_dns::RemoteDnsProvider;

#[derive(Clone, PartialEq, Eq)]
pub struct RemoteDnsHttpRequest {
    method: Method,
    url: String,
    headers: Vec<(String, String)>,
    body: String,
}

impl fmt::Debug for RemoteDnsHttpRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RemoteDnsHttpRequest")
            .field("method", &self.method)
            .field("url", &self.url)
            .field("headers", &"<redacted>")
            .field("body", &"<redacted>")
            .finish()
    }
}

impl RemoteDnsHttpRequest {
    pub fn new(
        method: Method,
        url: impl Into<String>,
        headers: impl IntoIterator<Item = (impl Into<String>, impl Into<String>)>,
        body: impl Into<String>,
    ) -> Self {
        Self {
            method,
            url: url.into(),
            headers: headers
                .into_iter()
                .map(|(name, value)| (name.into().to_ascii_lowercase(), value.into()))
                .collect(),
            body: body.into(),
        }
    }

    #[must_use]
    #[cfg(test)]
    pub fn method(&self) -> Method {
        self.method.clone()
    }

    #[must_use]
    #[cfg(test)]
    pub fn url(&self) -> &str {
        &self.url
    }

    #[must_use]
    #[cfg(test)]
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(header, _)| header.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    #[must_use]
    #[cfg(test)]
    pub fn body(&self) -> &str {
        &self.body
    }

    #[cfg(test)]
    pub fn json_body(&self) -> Result<serde_json::Value, serde_json::Error> {
        serde_json::from_str(&self.body)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteDnsHttpResponse {
    status: u16,
    body: String,
}

impl RemoteDnsHttpResponse {
    #[must_use]
    #[cfg(test)]
    pub fn new(status: u16, body: &str) -> Self {
        Self {
            status,
            body: body.to_string(),
        }
    }

    #[must_use]
    pub const fn status(&self) -> u16 {
        self.status
    }

    #[must_use]
    pub fn body(&self) -> &str {
        &self.body
    }

    #[must_use]
    pub const fn is_success(&self) -> bool {
        self.status >= 200 && self.status < 300
    }
}

#[async_trait]
pub trait RemoteDnsHttpClient: Send + Sync {
    async fn send(&self, request: RemoteDnsHttpRequest) -> Result<RemoteDnsHttpResponse, String>;
}

#[derive(Debug, Clone, Default)]
pub struct ReqwestRemoteDnsHttpClient {
    client: reqwest::Client,
}

#[async_trait]
impl RemoteDnsHttpClient for ReqwestRemoteDnsHttpClient {
    async fn send(&self, request: RemoteDnsHttpRequest) -> Result<RemoteDnsHttpResponse, String> {
        let mut builder = self
            .client
            .request(request.method.clone(), request.url.as_str())
            .body(request.body);
        for (name, value) in request.headers {
            builder = builder.header(name, value);
        }
        let response = builder
            .send()
            .await
            .map_err(|error| format!("send remote DNS provider request: {error}"))?;
        let status = response.status().as_u16();
        let body = response
            .text()
            .await
            .map_err(|error| format!("read remote DNS provider response: {error}"))?;
        Ok(RemoteDnsHttpResponse { status, body })
    }
}

#[derive(Debug)]
pub enum SystemDns01Provider {
    Aftermarket(AftermarketDns01Provider<ReqwestRemoteDnsHttpClient>),
    Cloudflare(CloudflareDns01Provider<ReqwestRemoteDnsHttpClient>),
    Route53(Route53Dns01Provider<ReqwestRemoteDnsHttpClient>),
    Exec(ExecDns01Provider<TokioRemoteDnsCommandRunner>),
}

pub enum SystemDns01Lease {
    Aftermarket(AftermarketDns01Lease),
    Cloudflare(CloudflareDns01Lease),
    Route53(Route53Dns01Lease),
    Exec(ExecDns01Lease),
}

impl SystemDns01Provider {
    /// Build the configured DNS-01 provider client from its environment
    /// variables.
    ///
    /// # Errors
    /// Returns a detail string when a required credential or endpoint
    /// variable for `provider` is missing or invalid.
    pub fn from_environment(provider: RemoteDnsProvider) -> Result<Self, String> {
        match provider {
            RemoteDnsProvider::Aftermarket => Ok(Self::Aftermarket(AftermarketDns01Provider::new(
                ReqwestRemoteDnsHttpClient::default(),
                &optional_env(
                    "HARNESS_REMOTE_ACME_AFTERMARKET_API_BASE",
                    "https://json.aftermarket.pl",
                ),
                &required_env("AFTERMARKET_ZONE_NAME")?,
                &required_env("AFTERMARKET_API_KEY")?,
                &required_env("AFTERMARKET_API_SECRET")?,
            )?)),
            RemoteDnsProvider::Cloudflare => Ok(Self::Cloudflare(CloudflareDns01Provider::new(
                ReqwestRemoteDnsHttpClient::default(),
                &optional_env(
                    "HARNESS_REMOTE_ACME_CLOUDFLARE_API_BASE",
                    "https://api.cloudflare.com/client/v4",
                ),
                &required_env("CLOUDFLARE_ZONE_ID")?,
                &required_env("CLOUDFLARE_API_TOKEN")?,
            )?)),
            RemoteDnsProvider::Route53 => {
                let credentials = AwsRoute53Credentials::new(
                    &required_env("AWS_ACCESS_KEY_ID")?,
                    &required_env("AWS_SECRET_ACCESS_KEY")?,
                    env::var("AWS_SESSION_TOKEN").ok().as_deref(),
                )?;
                Ok(Self::Route53(Route53Dns01Provider::new(
                    ReqwestRemoteDnsHttpClient::default(),
                    &optional_env(
                        "HARNESS_REMOTE_ACME_ROUTE53_ENDPOINT",
                        "https://route53.amazonaws.com",
                    ),
                    &required_env("AWS_ROUTE53_HOSTED_ZONE_ID")?,
                    credentials,
                )?))
            }
            RemoteDnsProvider::Exec => Ok(Self::Exec(ExecDns01Provider::new(
                TokioRemoteDnsCommandRunner,
                &required_env("HARNESS_REMOTE_ACME_DNS_EXEC")?,
            )?)),
        }
    }

    /// Present a DNS-01 TXT record through the configured provider.
    ///
    /// # Errors
    /// Returns a detail string when `provider` does not match the configured
    /// provider or the underlying request fails.
    pub async fn present(
        &self,
        provider: RemoteDnsProvider,
        record_name: &str,
        record_value: &str,
    ) -> Result<SystemDns01Lease, String> {
        match (self, provider) {
            (Self::Aftermarket(client), RemoteDnsProvider::Aftermarket) => client
                .present(record_name, record_value)
                .await
                .map(SystemDns01Lease::Aftermarket),
            (Self::Cloudflare(client), RemoteDnsProvider::Cloudflare) => client
                .present(record_name, record_value)
                .await
                .map(SystemDns01Lease::Cloudflare),
            (Self::Route53(client), RemoteDnsProvider::Route53) => client
                .present_at(record_name, record_value, &aws_timestamp())
                .await
                .map(SystemDns01Lease::Route53),
            (Self::Exec(client), RemoteDnsProvider::Exec) => client
                .present(record_name, record_value)
                .await
                .map(SystemDns01Lease::Exec),
            _ => Err("remote ACME DNS provider changed during issuance".to_string()),
        }
    }

    /// Wait for the leased record to become authoritative, when the provider
    /// requires it. Returns whether a wait was performed.
    ///
    /// # Errors
    /// Returns a detail string when `lease` does not match the configured
    /// provider or the wait fails.
    pub async fn wait_ready(&self, lease: &SystemDns01Lease) -> Result<bool, String> {
        match (self, lease) {
            (Self::Aftermarket(client), SystemDns01Lease::Aftermarket(lease)) => {
                client.wait_ready(lease).await?;
                Ok(true)
            }
            (Self::Cloudflare(_), SystemDns01Lease::Cloudflare(_))
            | (Self::Route53(_), SystemDns01Lease::Route53(_))
            | (Self::Exec(_), SystemDns01Lease::Exec(_)) => Ok(false),
            _ => Err("remote DNS provider lease does not match configured provider".to_string()),
        }
    }

    /// Clean up the leased DNS-01 TXT record through the configured provider.
    ///
    /// # Errors
    /// Returns a detail string when `lease` does not match the configured
    /// provider or the underlying request fails.
    pub async fn cleanup(&self, lease: SystemDns01Lease) -> Result<(), String> {
        match (self, lease) {
            (Self::Aftermarket(client), SystemDns01Lease::Aftermarket(lease)) => {
                client.cleanup(lease).await
            }
            (Self::Cloudflare(client), SystemDns01Lease::Cloudflare(lease)) => {
                client.cleanup(lease).await
            }
            (Self::Route53(client), SystemDns01Lease::Route53(lease)) => {
                client.cleanup_at(lease, &aws_timestamp()).await
            }
            (Self::Exec(client), SystemDns01Lease::Exec(lease)) => client.cleanup(lease).await,
            _ => Err("remote ACME DNS cleanup lease has wrong provider".to_string()),
        }
    }
}

fn required_env(name: &str) -> Result<String, String> {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("remote ACME DNS provider requires {name}"))
}

fn optional_env(name: &str, default: &str) -> String {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| default.to_string())
}

fn aws_timestamp() -> String {
    chrono::Utc::now().format("%Y%m%dT%H%M%SZ").to_string()
}

#[cfg(test)]
#[path = "remote_acme_dns_provider_tests.rs"]
mod tests;
