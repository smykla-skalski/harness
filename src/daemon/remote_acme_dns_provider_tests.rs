use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use http::Method;

use super::{
    AftermarketDns01Provider, AwsRoute53Credentials, CloudflareDns01Provider, DnsTxtRecordState,
    DnsTxtVisibilityWaiter, ExecDns01Provider, RemoteDnsCommandRunner, RemoteDnsHttpClient,
    RemoteDnsHttpRequest, RemoteDnsHttpResponse, Route53Dns01Provider,
};

#[tokio::test]
async fn aftermarket_dns01_creates_and_deletes_the_issued_record() {
    let http = RecordingDnsHttpClient::new([
        RemoteDnsHttpResponse::new(
            200,
            r#"{"ok":1,"status":0,"error":"","data":987,"errtype":""}"#,
        ),
        RemoteDnsHttpResponse::new(
            200,
            r#"{"ok":1,"status":0,"error":"","data":true,"errtype":""}"#,
        ),
    ]);
    let visibility = RecordingDnsTxtVisibility::default();
    let provider = AftermarketDns01Provider::new_with_visibility(
        http.clone(),
        "https://aftermarket.test",
        "example.com",
        "public-key",
        "secret-key",
        Arc::new(visibility.clone()),
    )
    .expect("configure Aftermarket provider");

    let lease = provider
        .present("_acme-challenge.daemon.example.com.", "dns-proof-value")
        .await
        .expect("present Aftermarket challenge");
    provider
        .wait_ready(&lease)
        .await
        .expect("wait for authoritative Aftermarket challenge");
    provider
        .cleanup(lease)
        .await
        .expect("cleanup Aftermarket challenge");

    let requests = http.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method(), Method::POST);
    assert_eq!(requests[0].url(), "https://aftermarket.test/domain/dns/add");
    assert_eq!(
        requests[0].header("authorization"),
        Some("Basic cHVibGljLWtleTpzZWNyZXQta2V5")
    );
    let create_body = requests[0].json_body().expect("Aftermarket create JSON");
    assert_eq!(create_body["name"], "example.com");
    assert_eq!(create_body["host"], "_acme-challenge.daemon.example.com");
    assert_eq!(create_body["type"], "TXT");
    assert_eq!(create_body["value"], "dns-proof-value");
    assert_eq!(requests[1].method(), Method::POST);
    assert_eq!(
        requests[1].url(),
        "https://aftermarket.test/domain/dns/remove"
    );
    let cleanup_body = requests[1].json_body().expect("Aftermarket cleanup JSON");
    assert_eq!(cleanup_body["name"], "example.com");
    assert_eq!(cleanup_body["entryId"], 987);
    assert_eq!(
        visibility.calls(),
        vec![
            (
                "_acme-challenge.daemon.example.com".to_string(),
                "dns-proof-value".to_string(),
                DnsTxtRecordState::Present,
            ),
            (
                "_acme-challenge.daemon.example.com".to_string(),
                "dns-proof-value".to_string(),
                DnsTxtRecordState::Absent,
            ),
        ]
    );
    assert!(!format!("{provider:?}").contains("secret-key"));
}

#[tokio::test]
async fn aftermarket_dns01_rejects_records_outside_the_configured_zone() {
    let http = RecordingDnsHttpClient::new([]);
    let provider = AftermarketDns01Provider::new(
        http.clone(),
        "https://aftermarket.test",
        "example.com",
        "public-key",
        "secret-key",
    )
    .expect("configure Aftermarket provider");

    let error = provider
        .present("_acme-challenge.example.net", "dns-proof-value")
        .await
        .expect_err("reject record outside zone");

    assert!(error.contains("outside zone example.com"));
    assert!(http.requests().is_empty());
}

#[tokio::test]
async fn aftermarket_dns01_redacts_provider_errors() {
    let http = RecordingDnsHttpClient::new([RemoteDnsHttpResponse::new(
        200,
        r#"{"ok":0,"status":500,"error":"token=super-secret failed","data":null}"#,
    )]);
    let provider = AftermarketDns01Provider::new(
        http,
        "https://aftermarket.test",
        "example.com",
        "public-key",
        "secret-key",
    )
    .expect("configure Aftermarket provider");

    let error = provider
        .present("_acme-challenge.example.com", "dns-proof-value")
        .await
        .expect_err("surface provider failure");

    assert!(error.contains("Aftermarket DNS request failed"));
    assert!(!error.contains("super-secret"));
}

#[tokio::test]
async fn aftermarket_dns01_rejects_unsuccessful_cleanup_result() {
    let http = RecordingDnsHttpClient::new([
        RemoteDnsHttpResponse::new(
            200,
            r#"{"ok":1,"status":0,"error":"","data":987,"errtype":""}"#,
        ),
        RemoteDnsHttpResponse::new(
            200,
            r#"{"ok":1,"status":0,"error":"","data":false,"errtype":""}"#,
        ),
    ]);
    let provider = AftermarketDns01Provider::new(
        http,
        "https://aftermarket.test",
        "example.com",
        "public-key",
        "secret-key",
    )
    .expect("configure Aftermarket provider");

    let lease = provider
        .present("_acme-challenge.example.com", "dns-proof-value")
        .await
        .expect("present Aftermarket challenge");
    let error = provider
        .cleanup(lease)
        .await
        .expect_err("reject unsuccessful cleanup result");

    assert_eq!(error, "Aftermarket DNS response did not remove entry 987");
}

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
    assert_eq!(
        requests[0].header("authorization"),
        Some(
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260709/us-east-1/route53/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=4ea0787ad4a5797fea9f06bb72201e114668208352f9cc91a80ab33f0197df29"
        )
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
struct RecordingDnsTxtVisibility {
    calls: Arc<Mutex<Vec<(String, String, DnsTxtRecordState)>>>,
}

impl RecordingDnsTxtVisibility {
    fn calls(&self) -> Vec<(String, String, DnsTxtRecordState)> {
        self.calls.lock().expect("lock DNS visibility").clone()
    }
}

#[async_trait]
impl DnsTxtVisibilityWaiter for RecordingDnsTxtVisibility {
    async fn wait_for(
        &self,
        record_name: &str,
        record_value: &str,
        state: DnsTxtRecordState,
    ) -> Result<(), String> {
        self.calls.lock().map_err(|error| error.to_string())?.push((
            record_name.to_string(),
            record_value.to_string(),
            state,
        ));
        Ok(())
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
