use std::env;
use std::fmt;

use async_trait::async_trait;
use http::Method;

#[path = "remote_acme_dns_cloudflare.rs"]
mod cloudflare;
#[path = "remote_acme_dns_exec.rs"]
mod exec;
#[path = "remote_acme_dns_route53.rs"]
mod route53;

pub(crate) use cloudflare::CloudflareDns01Lease;
pub(crate) use cloudflare::CloudflareDns01Provider;
#[cfg(test)]
pub(crate) use exec::RemoteDnsCommandRunner;
pub(crate) use exec::{ExecDns01Lease, ExecDns01Provider, TokioRemoteDnsCommandRunner};
pub(crate) use route53::Route53Dns01Lease;
pub(crate) use route53::{AwsRoute53Credentials, Route53Dns01Provider};

use super::remote::RemoteDnsProvider;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct RemoteDnsHttpRequest {
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
    pub(crate) fn new(
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
    pub(crate) fn method(&self) -> Method {
        self.method.clone()
    }

    #[must_use]
    #[cfg(test)]
    pub(crate) fn url(&self) -> &str {
        &self.url
    }

    #[must_use]
    #[cfg(test)]
    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(header, _)| header.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    #[must_use]
    #[cfg(test)]
    pub(crate) fn body(&self) -> &str {
        &self.body
    }

    #[cfg(test)]
    pub(crate) fn json_body(&self) -> Result<serde_json::Value, serde_json::Error> {
        serde_json::from_str(&self.body)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteDnsHttpResponse {
    status: u16,
    body: String,
}

impl RemoteDnsHttpResponse {
    #[must_use]
    #[cfg(test)]
    pub(crate) fn new(status: u16, body: &str) -> Self {
        Self {
            status,
            body: body.to_string(),
        }
    }

    #[must_use]
    pub(crate) const fn status(&self) -> u16 {
        self.status
    }

    #[must_use]
    pub(crate) fn body(&self) -> &str {
        &self.body
    }

    #[must_use]
    pub(crate) const fn is_success(&self) -> bool {
        self.status >= 200 && self.status < 300
    }
}

#[async_trait]
pub(crate) trait RemoteDnsHttpClient: Send + Sync {
    async fn send(&self, request: RemoteDnsHttpRequest) -> Result<RemoteDnsHttpResponse, String>;
}

#[derive(Debug, Clone, Default)]
pub(crate) struct ReqwestRemoteDnsHttpClient {
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
pub(crate) enum SystemDns01Provider {
    Cloudflare(CloudflareDns01Provider<ReqwestRemoteDnsHttpClient>),
    Route53(Route53Dns01Provider<ReqwestRemoteDnsHttpClient>),
    Exec(ExecDns01Provider<TokioRemoteDnsCommandRunner>),
}

pub(crate) enum SystemDns01Lease {
    Cloudflare(CloudflareDns01Lease),
    Route53(Route53Dns01Lease),
    Exec(ExecDns01Lease),
}

impl SystemDns01Provider {
    pub(crate) fn from_environment(provider: RemoteDnsProvider) -> Result<Self, String> {
        match provider {
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

    pub(crate) async fn present(
        &self,
        provider: RemoteDnsProvider,
        record_name: &str,
        record_value: &str,
    ) -> Result<SystemDns01Lease, String> {
        match (self, provider) {
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

    pub(crate) async fn cleanup(&self, lease: SystemDns01Lease) -> Result<(), String> {
        match (self, lease) {
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
