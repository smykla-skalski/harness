use std::collections::BTreeMap;
use std::fmt;
use std::fmt::Write as _;

use hmac::{Hmac, KeyInit as _, Mac as _};
use http::Method;
use sha2::{Digest as _, Sha256};

use super::{RemoteDnsHttpClient, RemoteDnsHttpRequest};
use crate::daemon::remote_redaction::redact_secret_detail;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone)]
pub(crate) struct AwsRoute53Credentials {
    access_key_id: String,
    secret_access_key: String,
    session_token: Option<String>,
}

impl fmt::Debug for AwsRoute53Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AwsRoute53Credentials")
            .field("access_key_id", &self.access_key_id)
            .field("secret_access_key", &"<redacted>")
            .field(
                "session_token",
                &self.session_token.as_ref().map(|_| "<redacted>"),
            )
            .finish()
    }
}

impl AwsRoute53Credentials {
    pub(crate) fn new(
        access_key_id: &str,
        secret_access_key: &str,
        session_token: Option<&str>,
    ) -> Result<Self, String> {
        let access_key_id = required("AWS access key id", access_key_id)?;
        let secret_access_key = required("AWS secret access key", secret_access_key)?;
        Ok(Self {
            access_key_id: access_key_id.to_string(),
            secret_access_key: secret_access_key.to_string(),
            session_token: session_token
                .map(str::trim)
                .filter(|token| !token.is_empty())
                .map(ToOwned::to_owned),
        })
    }
}

pub(crate) struct Route53Dns01Provider<C> {
    http: C,
    endpoint: String,
    hosted_zone_id: String,
    credentials: AwsRoute53Credentials,
}

impl<C> fmt::Debug for Route53Dns01Provider<C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Route53Dns01Provider")
            .field("endpoint", &self.endpoint)
            .field("hosted_zone_id", &self.hosted_zone_id)
            .field("credentials", &self.credentials)
            .finish_non_exhaustive()
    }
}

impl<C> Route53Dns01Provider<C>
where
    C: RemoteDnsHttpClient,
{
    pub(crate) fn new(
        http: C,
        endpoint: &str,
        hosted_zone_id: &str,
        credentials: AwsRoute53Credentials,
    ) -> Result<Self, String> {
        let endpoint = required("Route53 endpoint", endpoint)?;
        let hosted_zone_id =
            required("Route53 hosted zone id", hosted_zone_id)?.trim_start_matches("/hostedzone/");
        if hosted_zone_id.contains('/') {
            return Err("Route53 hosted zone id is invalid".to_string());
        }
        Ok(Self {
            http,
            endpoint: endpoint.trim_end_matches('/').to_string(),
            hosted_zone_id: hosted_zone_id.to_string(),
            credentials,
        })
    }

    pub(crate) async fn present_at(
        &self,
        record_name: &str,
        record_value: &str,
        timestamp: &str,
    ) -> Result<Route53Dns01Lease, String> {
        let lease = Route53Dns01Lease::new(record_name, record_value)?;
        self.change_at("UPSERT", &lease, timestamp).await?;
        Ok(lease)
    }

    pub(crate) async fn cleanup_at(
        &self,
        lease: Route53Dns01Lease,
        timestamp: &str,
    ) -> Result<(), String> {
        self.change_at("DELETE", &lease, timestamp).await
    }

    async fn change_at(
        &self,
        action: &str,
        lease: &Route53Dns01Lease,
        timestamp: &str,
    ) -> Result<(), String> {
        let request = self.signed_request(action, lease, timestamp)?;
        let response = self.http.send(request).await?;
        if response.is_success() {
            return Ok(());
        }
        Err(format!(
            "Route53 DNS request failed with status {}: {}",
            response.status(),
            redact_secret_detail(response.body())
        ))
    }

    fn signed_request(
        &self,
        action: &str,
        lease: &Route53Dns01Lease,
        timestamp: &str,
    ) -> Result<RemoteDnsHttpRequest, String> {
        let date = aws_date(timestamp)?;
        let path = format!("/2013-04-01/hostedzone/{}/rrset/", self.hosted_zone_id);
        let url = format!("{}{}", self.endpoint, path);
        let parsed_url = reqwest::Url::parse(&url)
            .map_err(|error| format!("parse Route53 endpoint: {error}"))?;
        let host_name = parsed_url
            .host_str()
            .ok_or_else(|| "Route53 endpoint host is required".to_string())?;
        let host = parsed_url.port().map_or_else(
            || host_name.to_string(),
            |port| format!("{host_name}:{port}"),
        );
        let body = route53_change_xml(action, lease);
        let payload_hash = sha256_hex(body.as_bytes());
        let mut headers = BTreeMap::from([
            ("content-type".to_string(), "application/xml".to_string()),
            ("host".to_string(), host),
            ("x-amz-content-sha256".to_string(), payload_hash.clone()),
            ("x-amz-date".to_string(), timestamp.to_string()),
        ]);
        if let Some(token) = &self.credentials.session_token {
            headers.insert("x-amz-security-token".to_string(), token.clone());
        }
        let signed_headers = headers.keys().cloned().collect::<Vec<_>>().join(";");
        let mut canonical_headers = String::new();
        for (name, value) in &headers {
            writeln!(&mut canonical_headers, "{name}:{}", value.trim())
                .map_err(|error| format!("build Route53 canonical headers: {error}"))?;
        }
        // SigV4 requires a blank separator after the newline-terminated header block.
        let canonical_request =
            format!("POST\n{path}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}");
        let scope = format!("{date}/us-east-1/route53/aws4_request");
        let string_to_sign = format!(
            "AWS4-HMAC-SHA256\n{timestamp}\n{scope}\n{}",
            sha256_hex(canonical_request.as_bytes())
        );
        let signature = route53_signature(
            &self.credentials.secret_access_key,
            date,
            string_to_sign.as_bytes(),
        )?;
        headers.insert(
            "authorization".to_string(),
            format!(
                "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed_headers}, Signature={signature}",
                self.credentials.access_key_id
            ),
        );
        Ok(RemoteDnsHttpRequest::new(Method::POST, url, headers, body))
    }
}

pub(crate) struct Route53Dns01Lease {
    record_name: String,
    record_value: String,
}

impl Route53Dns01Lease {
    fn new(record_name: &str, record_value: &str) -> Result<Self, String> {
        Ok(Self {
            record_name: required("Route53 DNS record name", record_name)?.to_string(),
            record_value: required("Route53 DNS record value", record_value)?.to_string(),
        })
    }
}

fn route53_change_xml(action: &str, lease: &Route53Dns01Lease) -> String {
    format!(
        "<ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\"><ChangeBatch><Changes><Change><Action>{action}</Action><ResourceRecordSet><Name>{}</Name><Type>TXT</Type><TTL>60</TTL><ResourceRecords><ResourceRecord><Value>\"{}\"</Value></ResourceRecord></ResourceRecords></ResourceRecordSet></Change></Changes></ChangeBatch></ChangeResourceRecordSetsRequest>",
        xml_escape(&lease.record_name),
        xml_escape(&lease.record_value)
    )
}

fn route53_signature(secret: &str, date: &str, string_to_sign: &[u8]) -> Result<String, String> {
    let date_key = hmac(format!("AWS4{secret}").as_bytes(), date.as_bytes())?;
    let region_key = hmac(&date_key, b"us-east-1")?;
    let service_key = hmac(&region_key, b"route53")?;
    let signing_key = hmac(&service_key, b"aws4_request")?;
    Ok(hex::encode(hmac(&signing_key, string_to_sign)?))
}

fn hmac(key: &[u8], value: &[u8]) -> Result<Vec<u8>, String> {
    let mut mac = HmacSha256::new_from_slice(key)
        .map_err(|error| format!("initialize Route53 request signing: {error}"))?;
    mac.update(value);
    Ok(mac.finalize().into_bytes().to_vec())
}

fn sha256_hex(value: &[u8]) -> String {
    hex::encode(Sha256::digest(value))
}

fn aws_date(timestamp: &str) -> Result<&str, String> {
    if timestamp.len() == 16
        && timestamp.as_bytes().get(8) == Some(&b'T')
        && timestamp.ends_with('Z')
        && timestamp[..8].bytes().all(|byte| byte.is_ascii_digit())
        && timestamp[9..15].bytes().all(|byte| byte.is_ascii_digit())
    {
        Ok(&timestamp[..8])
    } else {
        Err("Route53 signing timestamp must use YYYYMMDDTHHMMSSZ".to_string())
    }
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn required<'a>(label: &str, value: &'a str) -> Result<&'a str, String> {
    let value = value.trim();
    if value.is_empty() {
        Err(format!("{label} is required"))
    } else {
        Ok(value)
    }
}
