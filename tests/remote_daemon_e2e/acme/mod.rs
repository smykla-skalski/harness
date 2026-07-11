mod protocol;
mod validation;

use std::io;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::Router;
use axum::serve::Listener;
use rcgen::{
    BasicConstraints, CertificateParams, CertifiedIssuer, DistinguishedName, DnType, IsCa, KeyPair,
    KeyUsagePurpose,
};
use rustls::ServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio_rustls::TlsAcceptor;
use tokio_rustls::server::TlsStream;

pub(super) const HTTP_TOKEN: &str = "remote-e2e-http-token";
pub(super) const DNS_TOKEN: &str = "remote-e2e-dns-token";
pub(super) const TLS_TOKEN: &str = "remote-e2e-tls-token";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcmeChallenge {
    TlsAlpn,
    Http,
    Dns,
}

impl AcmeChallenge {
    pub const ALL: [Self; 3] = [Self::TlsAlpn, Self::Http, Self::Dns];

    pub const fn cli_name(self) -> &'static str {
        match self {
            Self::TlsAlpn => "tls-alpn",
            Self::Http => "http",
            Self::Dns => "dns",
        }
    }

    pub(super) fn challenge_path(self) -> &'static str {
        match self {
            Self::TlsAlpn => "/challenge/tls/1",
            Self::Http => "/challenge/http/1",
            Self::Dns => "/challenge/dns/1",
        }
    }
}

#[derive(Clone)]
pub struct AcmeChallengeConfig {
    pub challenge: AcmeChallenge,
    pub domain: String,
    pub http_port: u16,
    pub https_port: u16,
    pub dns_log: PathBuf,
    pub ca_root: PathBuf,
}

pub struct FakeAcmeServer {
    state: Arc<FakeAcmeState>,
    directory_url: String,
    ca_pem: String,
    shutdown: Option<oneshot::Sender<()>>,
    task: JoinHandle<Result<(), std::io::Error>>,
}

impl FakeAcmeServer {
    pub async fn start(config: AcmeChallengeConfig) -> Result<Self, String> {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .map_err(|error| format!("bind fake ACME server: {error}"))?;
        let address = listener
            .local_addr()
            .map_err(|error| format!("read fake ACME address: {error}"))?;
        let (issuer, ca_pem) = fake_ca()?;
        std::fs::write(&config.ca_root, ca_pem.as_bytes())
            .map_err(|error| format!("write fake ACME CA root: {error}"))?;
        let tls_config = fake_acme_server_tls_config(&issuer)?;
        let listener = FakeAcmeTlsListener::new(listener, tls_config);
        let origin = format!("https://localhost:{}", address.port());
        let state = Arc::new(FakeAcmeState {
            origin: origin.clone(),
            config,
            issuer,
            progress: Mutex::new(FakeAcmeProgress::default()),
        });
        let app = Router::new()
            .fallback(protocol::handle_acme_request)
            .with_state(Arc::clone(&state));
        let (shutdown, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(async move {
                    let _ = shutdown_rx.await;
                })
                .await
        });
        Ok(Self {
            state,
            directory_url: format!("{origin}/directory"),
            ca_pem,
            shutdown: Some(shutdown),
            task,
        })
    }

    pub fn directory_url(&self) -> &str {
        &self.directory_url
    }

    pub fn ca_pem(&self) -> &str {
        &self.ca_pem
    }

    pub fn validation_error(&self) -> Result<Option<String>, String> {
        self.state
            .progress
            .lock()
            .map_err(|_| "fake ACME progress lock poisoned".to_string())
            .map(|progress| progress.validation_error.clone())
    }

    pub async fn assert_complete(&self) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let (protocol_complete, validation_error) = {
                let progress = self
                    .state
                    .progress
                    .lock()
                    .map_err(|_| "fake ACME progress lock poisoned".to_string())?;
                (
                    progress.challenge_validated && progress.certificate_downloaded,
                    progress.validation_error.clone(),
                )
            };
            if let Some(error) = validation_error {
                return Err(format!("fake ACME validation failed: {error}"));
            }
            let dns_complete = self.state.config.challenge != AcmeChallenge::Dns
                || validation::dns_lifecycle_complete(&self.state.config.dns_log)?;
            if protocol_complete && dns_complete {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(
                    "fake ACME flow did not finish challenge, issuance, and cleanup".to_string(),
                );
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }

    pub async fn shutdown(mut self) -> Result<(), String> {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        (&mut self.task)
            .await
            .map_err(|error| format!("join fake ACME server: {error}"))?
            .map_err(|error| format!("serve fake ACME server: {error}"))
    }
}

impl Drop for FakeAcmeServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        self.task.abort();
    }
}

pub(super) struct FakeAcmeState {
    pub(super) origin: String,
    pub(super) config: AcmeChallengeConfig,
    pub(super) issuer: CertifiedIssuer<'static, KeyPair>,
    pub(super) progress: Mutex<FakeAcmeProgress>,
}

#[derive(Default)]
pub(super) struct FakeAcmeProgress {
    pub(super) challenge_validated: bool,
    pub(super) finalized: bool,
    pub(super) certificate_pem: Option<String>,
    pub(super) certificate_downloaded: bool,
    pub(super) validation_error: Option<String>,
}

fn fake_ca() -> Result<(CertifiedIssuer<'static, KeyPair>, String), String> {
    let mut params = CertificateParams::default();
    params.distinguished_name = DistinguishedName::new();
    params
        .distinguished_name
        .push(DnType::CommonName, "Harness Remote E2E CA");
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyCertSign,
        KeyUsagePurpose::CrlSign,
    ];
    let issuer = CertifiedIssuer::self_signed(
        params,
        KeyPair::generate().map_err(|error| format!("generate fake ACME CA key: {error}"))?,
    )
    .map_err(|error| format!("generate fake ACME CA certificate: {error}"))?;
    let pem = issuer.pem();
    Ok((issuer, pem))
}

fn fake_acme_server_tls_config(
    issuer: &CertifiedIssuer<'static, KeyPair>,
) -> Result<Arc<ServerConfig>, String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let signing_key =
        KeyPair::generate().map_err(|error| format!("generate fake ACME server key: {error}"))?;
    let certificate = CertificateParams::new(["localhost".to_string()])
        .map_err(|error| format!("build fake ACME server certificate: {error}"))?
        .signed_by(&signing_key, issuer)
        .map_err(|error| format!("sign fake ACME server certificate: {error}"))?;
    let chain = vec![
        CertificateDer::from(certificate.der().to_vec()),
        CertificateDer::from(issuer.der().to_vec()),
    ];
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(signing_key.serialize_der()));
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(chain, key)
        .map_err(|error| format!("build fake ACME TLS config: {error}"))?;
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

struct FakeAcmeTlsListener {
    listener: TcpListener,
    acceptor: TlsAcceptor,
}

impl FakeAcmeTlsListener {
    fn new(listener: TcpListener, config: Arc<ServerConfig>) -> Self {
        Self {
            listener,
            acceptor: TlsAcceptor::from(config),
        }
    }
}

impl Listener for FakeAcmeTlsListener {
    type Io = TlsStream<TcpStream>;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            let Ok((stream, address)) = self.listener.accept().await else {
                tokio::task::yield_now().await;
                continue;
            };
            if let Ok(stream) = self.acceptor.accept(stream).await {
                return (stream, address);
            }
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        self.listener.local_addr()
    }
}
