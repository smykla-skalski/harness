use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::{SinkExt as _, StreamExt as _};
use http::header::{AUTHORIZATION, HeaderValue};
use reqwest::StatusCode;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::pem::PemObject as _;
use rustls::pki_types::{CertificateDer, ServerName};
use rustls::{
    ClientConfig, DigitallySignedStruct, Error as TlsError, RootCertStore, SignatureScheme,
};
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;
use tokio_tungstenite::client_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;

const REMOTE_CLIENT_ID_HEADER: &str = "x-harness-remote-client-id";

#[derive(Debug, Clone)]
pub struct RemoteCredentials {
    pub client_id: String,
    pub token: String,
    pub role: String,
}

pub struct RemoteDaemonClient {
    domain: String,
    port: u16,
    origin: String,
    trust: RemoteDaemonClientTrust,
    http: reqwest::Client,
}

enum RemoteDaemonClientTrust {
    Pem(String),
    #[allow(
        dead_code,
        reason = "used by the public ACME sibling integration target"
    )]
    UntrustedStaging,
}

impl RemoteDaemonClient {
    pub fn new(domain: &str, port: u16, ca_pem: &str) -> Result<Self, String> {
        ensure_rustls_provider();
        let certificate = reqwest::Certificate::from_pem(ca_pem.as_bytes())
            .map_err(|error| format!("parse fake ACME CA: {error}"))?;
        let address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
        let http = reqwest::Client::builder()
            .add_root_certificate(certificate)
            .resolve(domain, address)
            .timeout(Duration::from_secs(5))
            .build()
            .map_err(|error| format!("build remote HTTPS client: {error}"))?;
        Ok(Self {
            domain: domain.to_string(),
            port,
            origin: format!("https://{domain}:{port}"),
            trust: RemoteDaemonClientTrust::Pem(ca_pem.to_string()),
            http,
        })
    }

    #[allow(
        dead_code,
        reason = "used by the public ACME sibling integration target"
    )]
    pub fn new_untrusted_staging(domain: &str, port: u16) -> Result<Self, String> {
        ensure_rustls_provider();
        let address = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port);
        let http = reqwest::Client::builder()
            .danger_accept_invalid_certs(true)
            .resolve(domain, address)
            .timeout(Duration::from_secs(10))
            .build()
            .map_err(|error| format!("build staging HTTPS client: {error}"))?;
        Ok(Self {
            domain: domain.to_string(),
            port,
            origin: format!("https://{domain}:{port}"),
            trust: RemoteDaemonClientTrust::UntrustedStaging,
            http,
        })
    }

    pub async fn wait_until_listening(&self) -> Result<(), String> {
        self.wait_until_listening_for(Duration::from_secs(15)).await
    }

    pub async fn wait_until_listening_for(&self, wait_timeout: Duration) -> Result<(), String> {
        let deadline = Instant::now() + wait_timeout;
        let mut last_error = "remote HTTPS listener did not answer".to_string();
        while Instant::now() < deadline {
            match self.http.get(self.url("/v1/health")).send().await {
                Ok(response) if response.status() == StatusCode::UNAUTHORIZED => return Ok(()),
                Ok(response) => {
                    last_error = format!("unexpected health status {}", response.status());
                }
                Err(error) => last_error = error.to_string(),
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        Err(format!("remote HTTPS listener not ready: {last_error}"))
    }

    pub async fn claim_pairing(
        &self,
        code: &str,
        client_id: &str,
        role: &str,
    ) -> Result<RemoteCredentials, String> {
        let response = self
            .http
            .post(self.url("/v1/remote/pair/claim"))
            .json(&json!({
                "code": code,
                "domain": self.domain,
                "client_id": client_id,
                "display_name": format!("Remote E2E {role}"),
                "platform": "e2e",
            }))
            .send()
            .await
            .map_err(|error| format!("claim remote pairing: {error}"))?;
        let status = response.status();
        let body = response
            .json::<Value>()
            .await
            .map_err(|error| format!("decode pairing response: {error}"))?;
        if !status.is_success() {
            return Err(format!("pairing claim returned {status}: {body}"));
        }
        Ok(RemoteCredentials {
            client_id: required_string(&body, "client_id")?.to_string(),
            token: required_string(&body, "token")?.to_string(),
            role: required_string(&body, "role")?.to_string(),
        })
    }

    pub async fn expect_health(
        &self,
        credentials: &RemoteCredentials,
        expected: u16,
    ) -> Result<(), String> {
        let response = Self::authenticated(self.http.get(self.url("/v1/health")), credentials)
            .send()
            .await
            .map_err(|error| format!("send authenticated health request: {error}"))?;
        expect_status("GET /v1/health", response, expected).await
    }

    pub async fn expect_telemetry(
        &self,
        credentials: &RemoteCredentials,
        expected: u16,
    ) -> Result<(), String> {
        let request = self
            .http
            .post(self.url("/v1/daemon/telemetry"))
            .json(&json!({
                "kind": "decode_failure",
                "source": "remote-daemon-e2e",
                "message": "remote e2e telemetry proof",
            }));
        let response = Self::authenticated(request, credentials)
            .send()
            .await
            .map_err(|error| format!("send remote telemetry: {error}"))?;
        expect_status("POST /v1/daemon/telemetry", response, expected).await
    }

    pub async fn expect_log_level_update(
        &self,
        credentials: &RemoteCredentials,
        expected: u16,
    ) -> Result<(), String> {
        let request = self
            .http
            .put(self.url("/v1/daemon/log-level"))
            .json(&json!({ "level": "debug" }));
        let response = Self::authenticated(request, credentials)
            .send()
            .await
            .map_err(|error| format!("send remote admin request: {error}"))?;
        expect_status("PUT /v1/daemon/log-level", response, expected).await
    }

    pub async fn expect_websocket_health_and_admin_denial(
        &self,
        credentials: &RemoteCredentials,
    ) -> Result<(), String> {
        let tls = self.connect_tls().await?;
        let mut request = format!("wss://{}:{}/v1/ws", self.domain, self.port)
            .into_client_request()
            .map_err(|error| format!("build WSS request: {error}"))?;
        request.headers_mut().insert(
            REMOTE_CLIENT_ID_HEADER,
            HeaderValue::from_str(&credentials.client_id)
                .map_err(|error| format!("build WSS client id header: {error}"))?,
        );
        request.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {}", credentials.token))
                .map_err(|error| format!("build WSS auth header: {error}"))?,
        );
        let (mut socket, _) = client_async(request, tls)
            .await
            .map_err(|error| format!("upgrade WSS connection: {error}"))?;

        let health = websocket_rpc(&mut socket, "e2e-health", "health").await?;
        if !health["error"].is_null() || health["result"].is_null() {
            return Err(format!("WSS health failed: {health}"));
        }
        let denied = websocket_rpc(&mut socket, "e2e-admin-denied", "daemon.stop").await?;
        if denied["error"]["status_code"].as_u64() != Some(403) {
            return Err(format!("WSS admin denial missing: {denied}"));
        }
        socket
            .close(None)
            .await
            .map_err(|error| format!("close WSS connection: {error}"))
    }

    #[allow(
        dead_code,
        reason = "used by the public ACME sibling integration target"
    )]
    pub async fn leaf_certificate_der(&self) -> Result<Vec<u8>, String> {
        let tls = self.connect_tls().await?;
        tls.get_ref()
            .1
            .peer_certificates()
            .and_then(|certificates| certificates.first())
            .map(|certificate| certificate.to_vec())
            .ok_or_else(|| "remote TLS handshake omitted the leaf certificate".to_string())
    }

    pub async fn stop(&self, credentials: &RemoteCredentials) -> Result<(), String> {
        let response =
            Self::authenticated(self.http.post(self.url("/v1/daemon/stop")), credentials)
                .send()
                .await
                .map_err(|error| format!("send remote daemon stop: {error}"))?;
        expect_status("POST /v1/daemon/stop", response, 200).await
    }

    fn authenticated(
        request: reqwest::RequestBuilder,
        credentials: &RemoteCredentials,
    ) -> reqwest::RequestBuilder {
        request
            .header(REMOTE_CLIENT_ID_HEADER, &credentials.client_id)
            .bearer_auth(&credentials.token)
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.origin)
    }

    async fn connect_tls(&self) -> Result<tokio_rustls::client::TlsStream<TcpStream>, String> {
        ensure_rustls_provider();
        let mut tls_config = match &self.trust {
            RemoteDaemonClientTrust::Pem(ca_pem) => {
                let mut roots = RootCertStore::empty();
                for certificate in CertificateDer::pem_slice_iter(ca_pem.as_bytes()) {
                    roots
                        .add(certificate.map_err(|error| format!("parse WSS root CA: {error}"))?)
                        .map_err(|error| format!("add WSS root CA: {error}"))?;
                }
                ClientConfig::builder()
                    .with_root_certificates(roots)
                    .with_no_client_auth()
            }
            RemoteDaemonClientTrust::UntrustedStaging => ClientConfig::builder()
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(UntrustedStagingVerifier))
                .with_no_client_auth(),
        };
        tls_config.alpn_protocols = vec![b"http/1.1".to_vec()];
        let stream = TcpStream::connect(("127.0.0.1", self.port))
            .await
            .map_err(|error| format!("connect WSS TCP stream: {error}"))?;
        let server_name = ServerName::try_from(self.domain.clone())
            .map_err(|error| format!("build WSS server name: {error}"))?;
        TlsConnector::from(Arc::new(tls_config))
            .connect(server_name, stream)
            .await
            .map_err(|error| format!("connect WSS TLS stream: {error}"))
    }
}

fn ensure_rustls_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

#[derive(Debug)]
struct UntrustedStagingVerifier;

impl ServerCertVerifier for UntrustedStagingVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _certificate: &CertificateDer<'_>,
        _signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _certificate: &CertificateDer<'_>,
        _signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::ED25519,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
        ]
    }
}

async fn websocket_rpc<S>(socket: &mut S, id: &str, method: &str) -> Result<Value, String>
where
    S: futures_util::Sink<Message, Error = tokio_tungstenite::tungstenite::Error>
        + futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
        + Unpin,
{
    socket
        .send(Message::Text(
            json!({ "id": id, "method": method, "params": {} })
                .to_string()
                .into(),
        ))
        .await
        .map_err(|error| format!("send WSS {method}: {error}"))?;
    let response = tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(frame) = socket.next().await {
            let frame = frame.map_err(|error| format!("read WSS {method}: {error}"))?;
            if let Message::Text(text) = frame {
                let value = serde_json::from_str::<Value>(&text)
                    .map_err(|error| format!("decode WSS {method}: {error}"))?;
                if value["id"].as_str() == Some(id) {
                    return Ok(value);
                }
            }
        }
        Err(format!("WSS closed before {method} response"))
    })
    .await
    .map_err(|_| format!("timed out waiting for WSS {method}"))??;
    Ok(response)
}

async fn expect_status(
    operation: &str,
    response: reqwest::Response,
    expected: u16,
) -> Result<(), String> {
    let status = response.status();
    if status.as_u16() == expected {
        return Ok(());
    }
    let body = response.text().await.unwrap_or_default();
    Err(format!(
        "{operation} returned {status}, expected {expected}: {body}"
    ))
}

fn required_string<'a>(value: &'a Value, field: &str) -> Result<&'a str, String> {
    value[field]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("response omitted {field}: {value}"))
}
