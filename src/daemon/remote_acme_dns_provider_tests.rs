use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use http::Method;

use super::{
    AwsRoute53Credentials, CloudflareDns01Provider, ExecDns01Provider, RemoteDnsCommandRunner,
    RemoteDnsHttpClient, RemoteDnsHttpRequest, RemoteDnsHttpResponse, Route53Dns01Provider,
};

#[tokio::test]
async fn cloudflare_dns01_creates_and_deletes_the_issued_record() {
    let http = RecordingDnsHttpClient::new([
        RemoteDnsHttpResponse::new(200, r#"{"success":true,"result":{"id":"record-123"}}"#),
        RemoteDnsHttpResponse::new(200, r#"{"success":true,"result":{"id":"record-123"}}"#),
    ]);
    let provider = CloudflareDns01Provider::new(
        http.clone(),
        "https://cloudflare.test/client/v4",
        "zone-456",
        "cloudflare-token-secret",
    )
    .expect("configure Cloudflare provider");

    let lease = provider
        .present("_acme-challenge.daemon.example.com", "dns-proof-value")
        .await
        .expect("present Cloudflare challenge");
    provider
        .cleanup(lease)
        .await
        .expect("cleanup Cloudflare challenge");

    let requests = http.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method(), Method::POST);
    assert_eq!(
        requests[0].url(),
        "https://cloudflare.test/client/v4/zones/zone-456/dns_records"
    );
    assert_eq!(
        requests[0].header("authorization"),
        Some("Bearer cloudflare-token-secret")
    );
    let create_body = requests[0].json_body().expect("Cloudflare create JSON");
    assert_eq!(create_body["type"], "TXT");
    assert_eq!(create_body["name"], "_acme-challenge.daemon.example.com");
    assert_eq!(create_body["content"], "dns-proof-value");
    assert_eq!(requests[1].method(), Method::DELETE);
    assert_eq!(
        requests[1].url(),
        "https://cloudflare.test/client/v4/zones/zone-456/dns_records/record-123"
    );
    assert!(!format!("{provider:?}").contains("cloudflare-token-secret"));
}

#[tokio::test]
async fn route53_dns01_signs_upsert_and_delete_requests() {
    let http = RecordingDnsHttpClient::new([
        RemoteDnsHttpResponse::new(200, "<ChangeResourceRecordSetsResponse/>"),
        RemoteDnsHttpResponse::new(200, "<ChangeResourceRecordSetsResponse/>"),
    ]);
    let credentials = AwsRoute53Credentials::new(
        "AKIDEXAMPLE",
        "route53-secret-key",
        Some("session-token-value"),
    )
    .expect("configure Route53 credentials");
    let provider = Route53Dns01Provider::new(
        http.clone(),
        "https://route53.test:8443",
        "Z123456",
        credentials,
    )
    .expect("configure Route53 provider");

    let lease = provider
        .present_at(
            "_acme-challenge.daemon.example.com",
            "dns-proof-value",
            "20260709T180000Z",
        )
        .await
        .expect("present Route53 challenge");
    provider
        .cleanup_at(lease, "20260709T180100Z")
        .await
        .expect("cleanup Route53 challenge");

    let requests = http.requests();
    assert_eq!(requests.len(), 2);
    for request in &requests {
        assert_eq!(request.method(), Method::POST);
        assert_eq!(
            request.url(),
            "https://route53.test:8443/2013-04-01/hostedzone/Z123456/rrset/"
        );
        assert_eq!(request.header("host"), Some("route53.test:8443"));
        assert_eq!(
            request.header("x-amz-security-token"),
            Some("session-token-value")
        );
        let authorization = request
            .header("authorization")
            .expect("authorization header");
        assert!(authorization.starts_with("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"));
        assert!(authorization.contains("/us-east-1/route53/aws4_request"));
        assert!(!authorization.contains("route53-secret-key"));
    }
    assert!(requests[0].body().contains("<Action>UPSERT</Action>"));
    assert!(requests[1].body().contains("<Action>DELETE</Action>"));
    assert!(
        requests[0]
            .body()
            .contains("<Value>\"dns-proof-value\"</Value>")
    );
    assert!(!format!("{provider:?}").contains("route53-secret-key"));
}

#[tokio::test]
async fn exec_dns01_runs_present_and_cleanup_with_exact_arguments() {
    let runner = RecordingCommandRunner::default();
    let provider = ExecDns01Provider::new(runner.clone(), "/usr/local/bin/acme-dns-hook")
        .expect("configure exec provider");

    let lease = provider
        .present("_acme-challenge.daemon.example.com", "dns-proof-value")
        .await
        .expect("present exec challenge");
    provider
        .cleanup(lease)
        .await
        .expect("cleanup exec challenge");

    assert_eq!(
        runner.calls(),
        vec![
            vec![
                "/usr/local/bin/acme-dns-hook".to_string(),
                "present".to_string(),
                "_acme-challenge.daemon.example.com".to_string(),
                "dns-proof-value".to_string(),
            ],
            vec![
                "/usr/local/bin/acme-dns-hook".to_string(),
                "cleanup".to_string(),
                "_acme-challenge.daemon.example.com".to_string(),
                "dns-proof-value".to_string(),
            ],
        ]
    );
}

#[derive(Clone)]
struct RecordingDnsHttpClient {
    inner: Arc<Mutex<RecordingDnsHttpState>>,
}

struct RecordingDnsHttpState {
    responses: VecDeque<RemoteDnsHttpResponse>,
    requests: Vec<RemoteDnsHttpRequest>,
}

impl RecordingDnsHttpClient {
    fn new<const N: usize>(responses: [RemoteDnsHttpResponse; N]) -> Self {
        Self {
            inner: Arc::new(Mutex::new(RecordingDnsHttpState {
                responses: responses.into(),
                requests: Vec::new(),
            })),
        }
    }

    fn requests(&self) -> Vec<RemoteDnsHttpRequest> {
        self.inner.lock().expect("lock DNS HTTP").requests.clone()
    }
}

#[async_trait]
impl RemoteDnsHttpClient for RecordingDnsHttpClient {
    async fn send(&self, request: RemoteDnsHttpRequest) -> Result<RemoteDnsHttpResponse, String> {
        let mut state = self.inner.lock().map_err(|error| error.to_string())?;
        state.requests.push(request);
        state
            .responses
            .pop_front()
            .ok_or_else(|| "missing fake DNS HTTP response".to_string())
    }
}

#[derive(Clone, Default)]
struct RecordingCommandRunner {
    calls: Arc<Mutex<Vec<Vec<String>>>>,
}

impl RecordingCommandRunner {
    fn calls(&self) -> Vec<Vec<String>> {
        self.calls.lock().expect("lock command calls").clone()
    }
}

#[async_trait]
impl RemoteDnsCommandRunner for RecordingCommandRunner {
    async fn run(&self, program: &str, args: &[String]) -> Result<(), String> {
        let mut call = vec![program.to_string()];
        call.extend_from_slice(args);
        self.calls
            .lock()
            .map_err(|error| error.to_string())?
            .push(call);
        Ok(())
    }
}
