use std::fmt;
use std::net::Ipv4Addr;
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde_json::Value;

use super::aftermarket_http::{
    PublicDnsHttpClient, PublicDnsHttpRequest, PublicDnsHttpResponse, ReqwestPublicDnsHttpClient,
};
use super::config::PublicAcmeConfig;
use super::dns::{PublicDnsApi, PublicDnsRecordLease};
use super::visibility::AuthoritativeARecordVisibility;

#[async_trait]
pub trait PublicARecordVisibility: Send + Sync {
    async fn wait_for(&self, name: &str, address: Ipv4Addr, present: bool) -> Result<(), String>;
}

pub struct AftermarketPublicDnsApi<Client, Visibility> {
    http: Client,
    visibility: Visibility,
    api_base: String,
    zone_name: String,
    api_key: String,
    api_secret: String,
}

impl<Client, Visibility> AftermarketPublicDnsApi<Client, Visibility> {
    pub fn new_with(
        http: Client,
        visibility: Visibility,
        api_base: &str,
        zone_name: &str,
        api_key: &str,
        api_secret: &str,
    ) -> Self {
        Self {
            http,
            visibility,
            api_base: api_base.to_string(),
            zone_name: zone_name.to_string(),
            api_key: api_key.to_string(),
            api_secret: api_secret.to_string(),
        }
    }
}

pub type LiveAftermarketPublicDnsApi =
    AftermarketPublicDnsApi<ReqwestPublicDnsHttpClient, AuthoritativeARecordVisibility>;

impl LiveAftermarketPublicDnsApi {
    pub fn new_live(config: &PublicAcmeConfig) -> Result<Self, String> {
        Ok(Self::new_with(
            ReqwestPublicDnsHttpClient::new(Duration::from_secs(30))?,
            AuthoritativeARecordVisibility::from_environment(&config.zone_name)?,
            &config.api_base,
            &config.zone_name,
            &config.api_key,
            &config.api_secret,
        ))
    }
}

impl<Client, Visibility> AftermarketPublicDnsApi<Client, Visibility>
where
    Client: PublicDnsHttpClient,
{
    async fn send(
        &self,
        path: &str,
        fields: &[(&str, String)],
    ) -> Result<PublicDnsHttpResponse, String> {
        let body = serde_urlencoded::to_string(fields)
            .map_err(|error| format!("encode Aftermarket public DNS request: {error}"))?;
        let credentials = BASE64_STANDARD.encode(format!("{}:{}", self.api_key, self.api_secret));
        self.http
            .send(PublicDnsHttpRequest {
                url: format!("{}{path}", self.api_base.trim_end_matches('/')),
                authorization: format!("Basic {credentials}"),
                body,
            })
            .await
    }
}

impl<Client, Visibility> fmt::Debug for AftermarketPublicDnsApi<Client, Visibility> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AftermarketPublicDnsApi")
            .field("api_base", &self.api_base)
            .field("zone_name", &self.zone_name)
            .field("api_key", &"<redacted>")
            .field("api_secret", &"<redacted>")
            .finish_non_exhaustive()
    }
}

#[async_trait]
impl<Client, Visibility> PublicDnsApi for AftermarketPublicDnsApi<Client, Visibility>
where
    Client: PublicDnsHttpClient,
    Visibility: PublicARecordVisibility,
{
    async fn add_a_record(
        &self,
        name: &str,
        address: Ipv4Addr,
    ) -> Result<PublicDnsRecordLease, String> {
        let response = self
            .send(
                "/domain/dns/add",
                &[
                    ("name", self.zone_name.clone()),
                    ("host", name.to_string()),
                    ("type", "A".to_string()),
                    ("value", address.to_string()),
                ],
            )
            .await?;
        let body = successful_body("add", &response)?;
        let entry_id = entry_id(&body["data"])
            .filter(|entry_id| *entry_id > 0)
            .ok_or_else(|| "Aftermarket public DNS add omitted entry id".to_string())?;
        Ok(PublicDnsRecordLease {
            entry_id,
            name: name.to_string(),
            address,
        })
    }

    async fn wait_for_a_record(
        &self,
        name: &str,
        address: Ipv4Addr,
        present: bool,
    ) -> Result<(), String> {
        self.visibility.wait_for(name, address, present).await
    }

    async fn remove_record(&self, lease: &PublicDnsRecordLease) -> Result<(), String> {
        let response = self
            .send(
                "/domain/dns/remove",
                &[
                    ("name", self.zone_name.clone()),
                    ("entryId", lease.entry_id.to_string()),
                ],
            )
            .await?;
        let body = successful_body("remove", &response)?;
        if body["data"].as_bool() != Some(true) {
            return Err(format!(
                "Aftermarket public DNS remove did not remove entry {}",
                lease.entry_id
            ));
        }
        Ok(())
    }
}

fn successful_body(operation: &str, response: &PublicDnsHttpResponse) -> Result<Value, String> {
    let body = serde_json::from_str::<Value>(&response.body).map_err(|_| {
        format!(
            "Aftermarket public DNS {operation} returned invalid JSON with status {}",
            response.status
        )
    })?;
    let ok = body["ok"]
        .as_bool()
        .unwrap_or_else(|| body["ok"].as_i64().is_some_and(|value| value != 0));
    if (200..300).contains(&response.status) && ok {
        Ok(body)
    } else {
        Err(format!(
            "Aftermarket public DNS {operation} failed with status {}",
            response.status
        ))
    }
}

fn entry_id(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Mutex;

    use super::*;

    #[tokio::test]
    async fn aftermarket_public_dns_adds_exact_a_record_and_returns_lease_immediately() {
        let http = RecordingHttpClient::new([response(r#"{"ok":1,"data":91}"#)]);
        let visibility = RecordingVisibility::default();
        let provider = provider(&http, &visibility);

        let lease = provider
            .add_a_record("tls.remote.example.com", address())
            .await
            .expect("add verified A record");

        assert_eq!(lease.entry_id, 91);
        assert_eq!(lease.name, "tls.remote.example.com");
        assert_eq!(lease.address, address());
        let requests = http.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].url(), "https://aftermarket.test/domain/dns/add");
        assert_eq!(
            requests[0].body(),
            "name=example.com&host=tls.remote.example.com&type=A&value=8.8.8.8"
        );
        assert_eq!(
            requests[0].authorization(),
            "Basic cHVibGljLWtleTpzZWNyZXQta2V5"
        );
        assert!(!format!("{:?}", requests[0]).contains("secret-key"));
    }

    #[tokio::test]
    async fn aftermarket_public_dns_removes_exact_leased_entry() {
        let http = RecordingHttpClient::new([response(r#"{"ok":1,"data":true}"#)]);
        let visibility = RecordingVisibility::default();
        let provider = provider(&http, &visibility);
        let lease = PublicDnsRecordLease {
            entry_id: 91,
            name: "tls.remote.example.com".to_string(),
            address: address(),
        };

        provider
            .remove_record(&lease)
            .await
            .expect("remove verified A record");

        let requests = http.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].url(),
            "https://aftermarket.test/domain/dns/remove"
        );
        assert_eq!(requests[0].body(), "name=example.com&entryId=91");
    }

    #[tokio::test]
    async fn aftermarket_public_dns_delegates_authoritative_visibility() {
        let http = RecordingHttpClient::new([]);
        let visibility = RecordingVisibility::default();
        let provider = provider(&http, &visibility);

        provider
            .wait_for_a_record("dns.remote.example.com", address(), false)
            .await
            .expect("wait for authoritative absence");

        assert_eq!(
            visibility.calls(),
            ["absent:dns.remote.example.com:8.8.8.8"]
        );
    }

    #[test]
    fn aftermarket_public_dns_debug_redacts_credentials() {
        let http = RecordingHttpClient::new([]);
        let visibility = RecordingVisibility::default();
        let provider = provider(&http, &visibility);

        let debug = format!("{provider:?}");
        assert!(!debug.contains("public-key"));
        assert!(!debug.contains("secret-key"));
        assert_eq!(debug.matches("<redacted>").count(), 2);
    }

    fn provider<'a>(
        http: &'a RecordingHttpClient,
        visibility: &'a RecordingVisibility,
    ) -> AftermarketPublicDnsApi<&'a RecordingHttpClient, &'a RecordingVisibility> {
        AftermarketPublicDnsApi::new_with(
            http,
            visibility,
            "https://aftermarket.test",
            "example.com",
            "public-key",
            "secret-key",
        )
    }

    fn address() -> Ipv4Addr {
        Ipv4Addr::new(8, 8, 8, 8)
    }

    fn response(body: &str) -> PublicDnsHttpResponse {
        PublicDnsHttpResponse {
            status: 200,
            body: body.to_string(),
        }
    }

    struct RecordingHttpClient {
        responses: Mutex<VecDeque<PublicDnsHttpResponse>>,
        requests: Mutex<Vec<PublicDnsHttpRequest>>,
    }

    impl RecordingHttpClient {
        fn new<const N: usize>(responses: [PublicDnsHttpResponse; N]) -> Self {
            Self {
                responses: Mutex::new(responses.into()),
                requests: Mutex::default(),
            }
        }

        fn requests(&self) -> Vec<PublicDnsHttpRequest> {
            self.requests.lock().expect("request lock").clone()
        }
    }

    #[async_trait]
    impl PublicDnsHttpClient for &RecordingHttpClient {
        async fn send(
            &self,
            request: PublicDnsHttpRequest,
        ) -> Result<PublicDnsHttpResponse, String> {
            self.requests.lock().expect("request lock").push(request);
            self.responses
                .lock()
                .expect("response lock")
                .pop_front()
                .ok_or_else(|| "missing fake Aftermarket response".to_string())
        }
    }

    #[derive(Default)]
    struct RecordingVisibility {
        calls: Mutex<Vec<String>>,
    }

    impl RecordingVisibility {
        fn calls(&self) -> Vec<String> {
            self.calls.lock().expect("visibility lock").clone()
        }
    }

    #[async_trait]
    impl PublicARecordVisibility for &RecordingVisibility {
        async fn wait_for(
            &self,
            name: &str,
            address: Ipv4Addr,
            present: bool,
        ) -> Result<(), String> {
            self.calls.lock().expect("visibility lock").push(format!(
                "{}:{name}:{address}",
                if present { "present" } else { "absent" }
            ));
            Ok(())
        }
    }
}
