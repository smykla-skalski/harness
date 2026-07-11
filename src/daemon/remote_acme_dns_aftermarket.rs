use std::fmt;
use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use http::Method;
use serde_json::{Value, json};

use super::visibility::{
    AuthoritativeDnsTxtVisibilityWaiter, DnsTxtRecordState, DnsTxtVisibilityWaiter,
};
use super::{RemoteDnsHttpClient, RemoteDnsHttpRequest, RemoteDnsHttpResponse};
use crate::daemon::remote_redaction::redact_secret_detail;

pub(crate) struct AftermarketDns01Provider<C> {
    http: C,
    api_base: String,
    zone_name: String,
    public_key: String,
    secret_key: String,
    visibility: Arc<dyn DnsTxtVisibilityWaiter>,
}

impl<C> fmt::Debug for AftermarketDns01Provider<C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AftermarketDns01Provider")
            .field("api_base", &self.api_base)
            .field("zone_name", &self.zone_name)
            .field("public_key", &"<redacted>")
            .field("secret_key", &"<redacted>")
            .finish_non_exhaustive()
    }
}

impl<C> AftermarketDns01Provider<C>
where
    C: RemoteDnsHttpClient,
{
    pub(crate) fn new(
        http: C,
        api_base: &str,
        zone_name: &str,
        public_key: &str,
        secret_key: &str,
    ) -> Result<Self, String> {
        let zone_name = required("Aftermarket zone name", zone_name)?
            .trim_end_matches('.')
            .to_string();
        let visibility = Arc::new(AuthoritativeDnsTxtVisibilityWaiter::from_environment(
            &zone_name,
        )?);
        Self::new_with_visibility(
            http, api_base, &zone_name, public_key, secret_key, visibility,
        )
    }

    pub(crate) fn new_with_visibility(
        http: C,
        api_base: &str,
        zone_name: &str,
        public_key: &str,
        secret_key: &str,
        visibility: Arc<dyn DnsTxtVisibilityWaiter>,
    ) -> Result<Self, String> {
        let api_base = required("Aftermarket API base URL", api_base)?;
        let zone_name = required("Aftermarket zone name", zone_name)?
            .trim_end_matches('.')
            .to_string();
        let public_key = required("Aftermarket API key", public_key)?;
        let secret_key = required("Aftermarket API secret", secret_key)?;
        Ok(Self {
            http,
            api_base: api_base.trim_end_matches('/').to_string(),
            zone_name,
            public_key: public_key.to_string(),
            secret_key: secret_key.to_string(),
            visibility,
        })
    }

    pub(crate) async fn present(
        &self,
        record_name: &str,
        record_value: &str,
    ) -> Result<AftermarketDns01Lease, String> {
        let host = validated_record_host(record_name, &self.zone_name)?;
        let record_value = required("Aftermarket DNS record value", record_value)?;
        let response = self
            .send(
                "/domain/dns/add",
                json!({
                    "name": self.zone_name,
                    "host": host,
                    "type": "TXT",
                    "value": record_value,
                }),
            )
            .await?;
        let entry_id = aftermarket_entry_id(&response)?;
        Ok(AftermarketDns01Lease {
            entry_id,
            record_name: host,
            record_value: record_value.to_string(),
        })
    }

    pub(crate) async fn wait_ready(&self, lease: &AftermarketDns01Lease) -> Result<(), String> {
        self.visibility
            .wait_for(
                &lease.record_name,
                &lease.record_value,
                DnsTxtRecordState::Present,
            )
            .await
    }

    pub(crate) async fn cleanup(&self, lease: AftermarketDns01Lease) -> Result<(), String> {
        let response = self
            .send(
                "/domain/dns/remove",
                json!({
                    "name": self.zone_name,
                    "entryId": lease.entry_id,
                }),
            )
            .await?;
        ensure_aftermarket_removed(&response, lease.entry_id)?;
        self.visibility
            .wait_for(
                &lease.record_name,
                &lease.record_value,
                DnsTxtRecordState::Absent,
            )
            .await
    }

    async fn send(&self, path: &str, body: Value) -> Result<RemoteDnsHttpResponse, String> {
        self.http
            .send(RemoteDnsHttpRequest::new(
                Method::POST,
                format!("{}{path}", self.api_base),
                self.headers(),
                body.to_string(),
            ))
            .await
    }

    fn headers(&self) -> Vec<(String, String)> {
        let credentials =
            BASE64_STANDARD.encode(format!("{}:{}", self.public_key, self.secret_key));
        vec![
            ("authorization".to_string(), format!("Basic {credentials}")),
            ("content-type".to_string(), "application/json".to_string()),
        ]
    }
}

#[derive(Debug)]
pub(crate) struct AftermarketDns01Lease {
    entry_id: u64,
    record_name: String,
    record_value: String,
}

fn aftermarket_entry_id(response: &RemoteDnsHttpResponse) -> Result<u64, String> {
    let body = ensure_aftermarket_success(response)?;
    body["data"]
        .as_u64()
        .or_else(|| body["data"].as_str().and_then(|value| value.parse().ok()))
        .filter(|entry_id| *entry_id > 0)
        .ok_or_else(|| "Aftermarket DNS response omitted entry id".to_string())
}

fn ensure_aftermarket_removed(
    response: &RemoteDnsHttpResponse,
    entry_id: u64,
) -> Result<(), String> {
    let body = ensure_aftermarket_success(response)?;
    if body["data"].as_bool() == Some(true) {
        Ok(())
    } else {
        Err(format!(
            "Aftermarket DNS response did not remove entry {entry_id}"
        ))
    }
}

fn ensure_aftermarket_success(response: &RemoteDnsHttpResponse) -> Result<Value, String> {
    let body = serde_json::from_str::<Value>(response.body()).map_err(|error| {
        format!(
            "parse Aftermarket DNS response with status {}: {error}",
            response.status()
        )
    })?;
    let ok = body["ok"]
        .as_bool()
        .unwrap_or_else(|| body["ok"].as_i64().is_some_and(|value| value != 0));
    if response.is_success() && ok {
        return Ok(body);
    }
    Err(format!(
        "Aftermarket DNS request failed with status {}: {}",
        response.status(),
        redact_secret_detail(response.body())
    ))
}

fn validated_record_host(record_name: &str, zone_name: &str) -> Result<String, String> {
    let record_name = required("Aftermarket DNS record name", record_name)?.trim_end_matches('.');
    if record_name.eq_ignore_ascii_case(zone_name) {
        return Ok(record_name.to_string());
    }
    let suffix = format!(".{zone_name}");
    if record_name.len() <= suffix.len()
        || !record_name[record_name.len() - suffix.len()..].eq_ignore_ascii_case(&suffix)
    {
        return Err(format!(
            "Aftermarket DNS record {record_name} is outside zone {zone_name}"
        ));
    }
    Ok(record_name.to_string())
}

fn required<'a>(label: &str, value: &'a str) -> Result<&'a str, String> {
    let value = value.trim();
    if value.is_empty() {
        Err(format!("{label} is required"))
    } else {
        Ok(value)
    }
}
