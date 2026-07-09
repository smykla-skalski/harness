use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use bytes::Bytes;
use http::header::{HeaderName, HeaderValue, LOCATION};
use http::{Method, Request, Response, StatusCode};
use http_body_util::{BodyExt as _, Full};
use instant_acme::{BodyWrapper, BytesResponse, Error as AcmeError, HttpClient};
use rcgen::{
    BasicConstraints, CertificateParams, CertificateSigningRequestParams, DistinguishedName,
    DnType, IsCa, Issuer, KeyPair,
};
use rustls::pki_types::CertificateSigningRequestDer;

use crate::daemon::remote::RemoteAcmeChallenge;

pub(super) const DIRECTORY_URL: &str = "https://acme.test/directory";
pub(super) const ACCOUNT_URL: &str = "https://acme.test/acct/1";

const ORDER_URL: &str = "https://acme.test/order/1";
const AUTHORIZATION_URL: &str = "https://acme.test/authz/1";
const CHALLENGE_URL: &str = "https://acme.test/challenge/http/1";
const FINALIZE_URL: &str = "https://acme.test/order/1/finalize";
const CERTIFICATE_URL: &str = "https://acme.test/cert/1";
const REPLAY_NONCE: HeaderName = HeaderName::from_static("replay-nonce");

#[derive(Clone)]
pub(super) struct ScriptedAcmeHttp {
    inner: Arc<Mutex<ScriptedAcmeHttpState>>,
}

struct ScriptedAcmeHttpState {
    responses: VecDeque<ScriptedResponse>,
    requests: Vec<RecordedRequest>,
    issued_certificate: Option<String>,
}

impl ScriptedAcmeHttp {
    pub(super) fn new(responses: Vec<ScriptedResponse>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(ScriptedAcmeHttpState {
                responses: responses.into(),
                requests: Vec::new(),
                issued_certificate: None,
            })),
        }
    }

    pub(super) fn requests(&self) -> Vec<RecordedRequest> {
        self.inner
            .lock()
            .expect("lock HTTP script")
            .requests
            .clone()
    }

    pub(super) fn assert_exhausted(&self) {
        assert!(
            self.inner
                .lock()
                .expect("lock HTTP script")
                .responses
                .is_empty(),
            "unconsumed ACME responses"
        );
    }
}

impl HttpClient for ScriptedAcmeHttp {
    fn request(
        &self,
        request: Request<BodyWrapper<Bytes>>,
    ) -> Pin<Box<dyn Future<Output = Result<BytesResponse, AcmeError>> + Send>> {
        let inner = self.inner.clone();
        Box::pin(async move {
            let (parts, body) = request.into_parts();
            let body = body
                .collect()
                .await
                .expect("collect ACME request body")
                .to_bytes();
            let recorded = RecordedRequest {
                method: parts.method,
                uri: parts.uri.to_string(),
                body: body.to_vec(),
            };
            let (response, response_body) = {
                let mut state = inner.lock().expect("lock HTTP script");
                let response = state
                    .responses
                    .pop_front()
                    .expect("unexpected ACME request");
                assert_eq!(recorded.method, response.method);
                assert_eq!(recorded.uri, response.uri);
                if recorded.uri == FINALIZE_URL {
                    state.issued_certificate = Some(sign_finalized_csr(&recorded));
                }
                let response_body = (recorded.uri == CERTIFICATE_URL).then(|| {
                    state
                        .issued_certificate
                        .clone()
                        .expect("finalized certificate before download")
                });
                state.requests.push(recorded);
                (response, response_body)
            };
            Ok(response.into_response(response_body))
        })
    }
}

#[derive(Clone)]
pub(super) struct RecordedRequest {
    method: Method,
    uri: String,
    body: Vec<u8>,
}

pub(super) struct ScriptedResponse {
    method: Method,
    uri: &'static str,
    status: StatusCode,
    body: &'static str,
    nonce: Option<&'static str>,
    location: Option<&'static str>,
}

impl ScriptedResponse {
    fn into_response(self, body_override: Option<String>) -> BytesResponse {
        let mut builder = Response::builder().status(self.status);
        if let Some(nonce) = self.nonce {
            builder = builder.header(REPLAY_NONCE, HeaderValue::from_static(nonce));
        }
        if let Some(location) = self.location {
            builder = builder.header(LOCATION, HeaderValue::from_static(location));
        }
        let body = body_override.unwrap_or_else(|| self.body.to_string());
        BytesResponse::from(
            builder
                .body(Full::new(Bytes::from(body)))
                .expect("build ACME response"),
        )
    }
}

fn response(method: Method, uri: &'static str, body: &'static str) -> ScriptedResponse {
    ScriptedResponse {
        method,
        uri,
        status: StatusCode::OK,
        body,
        nonce: Some("next-nonce"),
        location: None,
    }
}

pub(super) fn acme_happy_path() -> Vec<ScriptedResponse> {
    vec![
        ScriptedResponse {
            method: Method::GET,
            uri: DIRECTORY_URL,
            status: StatusCode::OK,
            body: DIRECTORY_BODY,
            nonce: None,
            location: None,
        },
        response(Method::HEAD, "https://acme.test/new-nonce", ""),
        ScriptedResponse {
            method: Method::POST,
            uri: "https://acme.test/new-account",
            status: StatusCode::CREATED,
            body: "{}",
            nonce: Some("account-nonce"),
            location: Some(ACCOUNT_URL),
        },
        ScriptedResponse {
            method: Method::GET,
            uri: DIRECTORY_URL,
            status: StatusCode::OK,
            body: DIRECTORY_BODY,
            nonce: None,
            location: None,
        },
        response(Method::HEAD, "https://acme.test/new-nonce", ""),
        ScriptedResponse {
            method: Method::POST,
            uri: "https://acme.test/new-order",
            status: StatusCode::CREATED,
            body: ORDER_PENDING_BODY,
            nonce: Some("order-nonce"),
            location: Some(ORDER_URL),
        },
        response(Method::POST, AUTHORIZATION_URL, AUTHORIZATION_PENDING_BODY),
        response(Method::POST, CHALLENGE_URL, CHALLENGE_PENDING_BODY),
        response(Method::POST, ORDER_URL, ORDER_READY_BODY),
        response(Method::POST, AUTHORIZATION_URL, AUTHORIZATION_VALID_BODY),
        response(Method::POST, FINALIZE_URL, ORDER_PROCESSING_BODY),
        response(Method::POST, ORDER_URL, ORDER_VALID_BODY),
        response(Method::POST, CERTIFICATE_URL, TEST_CERTIFICATE_PEM),
    ]
}

pub(super) fn acme_happy_path_for(challenge: RemoteAcmeChallenge) -> Vec<ScriptedResponse> {
    let mut responses = acme_happy_path();
    match challenge {
        RemoteAcmeChallenge::Http => {}
        RemoteAcmeChallenge::Dns => {
            responses[7].uri = "https://acme.test/challenge/dns/1";
            responses[7].body = DNS_CHALLENGE_PENDING_BODY;
        }
        RemoteAcmeChallenge::TlsAlpn => {
            responses[7].uri = "https://acme.test/challenge/tls/1";
            responses[7].body = TLS_CHALLENGE_PENDING_BODY;
        }
    }
    responses
}

pub(super) fn acme_rejected_order_path() -> Vec<ScriptedResponse> {
    let mut responses = acme_happy_path();
    responses[8].body = ORDER_INVALID_BODY;
    responses.truncate(9);
    responses
}

pub(super) fn jws_payload(request: &RecordedRequest) -> serde_json::Value {
    let envelope =
        serde_json::from_slice::<serde_json::Value>(&request.body).expect("decode JWS envelope");
    let payload = envelope["payload"].as_str().expect("JWS payload");
    let decoded = URL_SAFE_NO_PAD.decode(payload).expect("decode JWS payload");
    serde_json::from_slice(&decoded).expect("decode JWS payload JSON")
}

fn sign_finalized_csr(request: &RecordedRequest) -> String {
    let payload = jws_payload(request);
    let csr = payload["csr"].as_str().expect("finalize CSR payload");
    let csr = URL_SAFE_NO_PAD.decode(csr).expect("decode finalize CSR");
    let csr = CertificateSigningRequestDer::from(csr);
    let request =
        CertificateSigningRequestParams::from_der(&csr).expect("parse and verify finalize CSR");
    let mut issuer_params = CertificateParams::default();
    issuer_params.distinguished_name = DistinguishedName::new();
    issuer_params
        .distinguished_name
        .push(DnType::CommonName, "Harness Fake ACME CA");
    issuer_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let issuer = Issuer::new(
        issuer_params,
        KeyPair::generate().expect("generate fake ACME CA key"),
    );
    request
        .signed_by(&issuer)
        .expect("sign finalized CSR")
        .pem()
}

const DIRECTORY_BODY: &str = r#"{
  "newNonce":"https://acme.test/new-nonce",
  "newAccount":"https://acme.test/new-account",
  "newOrder":"https://acme.test/new-order"
}"#;
const ORDER_PENDING_BODY: &str = r#"{
  "status":"pending",
  "authorizations":["https://acme.test/authz/1"],
  "finalize":"https://acme.test/order/1/finalize",
  "certificate":null,
  "error":null
}"#;
const AUTHORIZATION_PENDING_BODY: &str = r#"{
  "identifier":{"type":"dns","value":"daemon.example.com"},
  "status":"pending",
  "challenges":[
    {"type":"http-01","url":"https://acme.test/challenge/http/1","token":"http-token","status":"pending","error":null},
    {"type":"dns-01","url":"https://acme.test/challenge/dns/1","token":"dns-token","status":"pending","error":null},
    {"type":"tls-alpn-01","url":"https://acme.test/challenge/tls/1","token":"tls-token","status":"pending","error":null}
  ]
}"#;
const CHALLENGE_PENDING_BODY: &str = r#"{
  "type":"http-01",
  "url":"https://acme.test/challenge/http/1",
  "token":"http-token",
  "status":"pending",
  "error":null
}"#;
const DNS_CHALLENGE_PENDING_BODY: &str = r#"{
  "type":"dns-01",
  "url":"https://acme.test/challenge/dns/1",
  "token":"dns-token",
  "status":"pending",
  "error":null
}"#;
const TLS_CHALLENGE_PENDING_BODY: &str = r#"{
  "type":"tls-alpn-01",
  "url":"https://acme.test/challenge/tls/1",
  "token":"tls-token",
  "status":"pending",
  "error":null
}"#;
const AUTHORIZATION_VALID_BODY: &str = r#"{
  "identifier":{"type":"dns","value":"daemon.example.com"},
  "status":"valid",
  "challenges":[
    {"type":"http-01","url":"https://acme.test/challenge/http/1","token":"http-token","status":"valid","error":null}
  ]
}"#;
const ORDER_READY_BODY: &str = r#"{
  "status":"ready",
  "authorizations":["https://acme.test/authz/1"],
  "finalize":"https://acme.test/order/1/finalize",
  "certificate":null,
  "error":null
}"#;
const ORDER_PROCESSING_BODY: &str = r#"{
  "status":"processing",
  "authorizations":["https://acme.test/authz/1"],
  "finalize":"https://acme.test/order/1/finalize",
  "certificate":null,
  "error":null
}"#;
const ORDER_VALID_BODY: &str = r#"{
  "status":"valid",
  "authorizations":["https://acme.test/authz/1"],
  "finalize":"https://acme.test/order/1/finalize",
  "certificate":"https://acme.test/cert/1",
  "error":null
}"#;
const ORDER_INVALID_BODY: &str = r#"{
  "status":"invalid",
  "authorizations":["https://acme.test/authz/1"],
  "finalize":"https://acme.test/order/1/finalize",
  "certificate":null,
  "error":{"type":"urn:ietf:params:acme:error:rejectedIdentifier","detail":"test rejection","status":400}
}"#;
const TEST_CERTIFICATE_PEM: &str =
    "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n";
