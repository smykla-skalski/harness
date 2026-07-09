use std::fmt;

use http::Method;
use serde_json::json;

use super::{RemoteDnsHttpClient, RemoteDnsHttpRequest, RemoteDnsHttpResponse};
use crate::daemon::remote_redaction::redact_secret_detail;

pub(crate) struct CloudflareDns01Provider<C> {
    http: C,
    api_base: String,
    zone_id: String,
    token: String,
}

impl<C> fmt::Debug for CloudflareDns01Provider<C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudflareDns01Provider")
            .field("api_base", &self.api_base)
            .field("zone_id", &self.zone_id)
            .field("token", &"<redacted>")
            .finish_non_exhaustive()
    }
}

impl<C> CloudflareDns01Provider<C>
where
    C: RemoteDnsHttpClient,
{
    pub(crate) fn new(http: C, api_base: &str, zone_id: &str, token: &str) -> Result<Self, String> {
        let api_base = required("Cloudflare API base URL", api_base)?;
        let zone_id = required("Cloudflare zone id", zone_id)?;
        let token = required("Cloudflare API token", token)?;
        Ok(Self {
            http,
            api_base: api_base.trim_end_matches('/').to_string(),
            zone_id: zone_id.to_string(),
            token: token.to_string(),
        })
    }

    pub(crate) async fn present(
        &self,
        record_name: &str,
        record_value: &str,
    ) -> Result<CloudflareDns01Lease, String> {
        let record_name = required("Cloudflare DNS record name", record_name)?;
        let record_value = required("Cloudflare DNS record value", record_value)?;
        let body = json!({
            "type": "TXT",
            "name": record_name,
            "content": record_value,
            "ttl": 120,
        })
        .to_string();
        let response = self
            .http
            .send(RemoteDnsHttpRequest::new(
                Method::POST,
                self.records_url(),
                self.headers(),
                body,
            ))
            .await?;
        let record_id = cloudflare_record_id(&response)?;
        Ok(CloudflareDns01Lease { record_id })
    }

    pub(crate) async fn cleanup(&self, lease: CloudflareDns01Lease) -> Result<(), String> {
        let response = self
            .http
            .send(RemoteDnsHttpRequest::new(
                Method::DELETE,
                format!("{}/{}", self.records_url(), lease.record_id),
                self.headers(),
                String::new(),
            ))
            .await?;
        ensure_cloudflare_success(&response)
    }

    fn records_url(&self) -> String {
        format!("{}/zones/{}/dns_records", self.api_base, self.zone_id)
    }

    fn headers(&self) -> Vec<(String, String)> {
        vec![
            (
                "authorization".to_string(),
                format!("Bearer {}", self.token),
            ),
            ("content-type".to_string(), "application/json".to_string()),
        ]
    }
}

pub(crate) struct CloudflareDns01Lease {
    record_id: String,
}

fn cloudflare_record_id(response: &RemoteDnsHttpResponse) -> Result<String, String> {
    ensure_cloudflare_success(response)?;
    let value = serde_json::from_str::<serde_json::Value>(response.body())
        .map_err(|error| format!("parse Cloudflare DNS response: {error}"))?;
    value["result"]["id"]
        .as_str()
        .filter(|id| !id.trim().is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| "Cloudflare DNS response omitted record id".to_string())
}

fn ensure_cloudflare_success(response: &RemoteDnsHttpResponse) -> Result<(), String> {
    let success = serde_json::from_str::<serde_json::Value>(response.body())
        .ok()
        .and_then(|value| value["success"].as_bool())
        .unwrap_or(false);
    if response.is_success() && success {
        return Ok(());
    }
    Err(format!(
        "Cloudflare DNS request failed with status {}: {}",
        response.status(),
        redact_secret_detail(response.body())
    ))
}

fn required<'a>(label: &str, value: &'a str) -> Result<&'a str, String> {
    let value = value.trim();
    if value.is_empty() {
        Err(format!("{label} is required"))
    } else {
        Ok(value)
    }
}
