use std::error::Error;
use std::fmt;
use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use axum::extract::connect_info::Connected;
use axum::serve::IncomingStream;
use axum::serve::Listener;
use rustls::ServerConfig;
use rustls::crypto::ring::default_provider;
use rustls::pki_types::pem::PemObject as _;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use tokio::net::{TcpListener, TcpStream, ToSocketAddrs};
use tokio::task::yield_now;
use tokio::time::sleep;
use tokio_rustls::TlsAcceptor;
use tokio_rustls::server::TlsStream;

use super::http::DaemonConnectInfo;
use super::remote_acme::RemoteCertificateBundle;

#[cfg(test)]
#[path = "remote_tls_tests.rs"]
mod tests;

static RUSTLS_PROVIDER: OnceLock<()> = OnceLock::new();

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoteTlsConfigError {
    MissingCertificate,
    MissingPrivateKey,
    InvalidCertificatePem(String),
    InvalidPrivateKeyPem(String),
    InvalidServerConfig(String),
}

impl fmt::Display for RemoteTlsConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingCertificate => write!(f, "remote TLS certificate PEM is required"),
            Self::MissingPrivateKey => write!(f, "remote TLS private key PEM is required"),
            Self::InvalidCertificatePem(error) => {
                write!(f, "remote TLS certificate PEM is invalid: {error}")
            }
            Self::InvalidPrivateKeyPem(error) => {
                write!(f, "remote TLS private key PEM is invalid: {error}")
            }
            Self::InvalidServerConfig(error) => {
                write!(f, "remote TLS server config is invalid: {error}")
            }
        }
    }
}

impl Error for RemoteTlsConfigError {}

/// Build the rustls server config used by the internet-facing daemon listener.
///
/// # Errors
/// Returns [`RemoteTlsConfigError`] when the persisted ACME certificate bundle
/// is missing, malformed, or rejected by rustls.
pub fn build_remote_tls_server_config(
    bundle: &RemoteCertificateBundle,
) -> Result<Arc<ServerConfig>, RemoteTlsConfigError> {
    ensure_rustls_provider();
    let cert_chain = parse_certificate_chain(bundle.certificate_pem())?;
    let private_key = parse_private_key(bundle.private_key_pem())?;
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(cert_chain, private_key)
        .map_err(|error| RemoteTlsConfigError::InvalidServerConfig(error.to_string()))?;
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}

pub struct RemoteTlsListener {
    listener: TcpListener,
    acceptor: TlsAcceptor,
}

impl RemoteTlsListener {
    /// Bind a TCP socket and wrap each accepted stream in rustls.
    ///
    /// # Errors
    /// Returns [`io::Error`] when the TCP listener cannot bind.
    pub async fn bind<A>(addr: A, config: Arc<ServerConfig>) -> io::Result<Self>
    where
        A: ToSocketAddrs,
    {
        Ok(Self {
            listener: TcpListener::bind(addr).await?,
            acceptor: TlsAcceptor::from(config),
        })
    }
}

impl Listener for RemoteTlsListener {
    type Io = TlsStream<TcpStream>;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            let (stream, addr) = match self.listener.accept().await {
                Ok(connection) => connection,
                Err(error) => {
                    handle_tcp_accept_error(error).await;
                    continue;
                }
            };
            match self.acceptor.accept(stream).await {
                Ok(tls_stream) => return (tls_stream, addr),
                Err(error) => handle_tls_handshake_error(addr, &error),
            }
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        self.listener.local_addr()
    }
}

impl Connected<IncomingStream<'_, RemoteTlsListener>> for DaemonConnectInfo {
    fn connect_info(stream: IncomingStream<'_, RemoteTlsListener>) -> Self {
        Self::new(*stream.remote_addr())
    }
}

fn parse_certificate_chain(
    pem: &str,
) -> Result<Vec<CertificateDer<'static>>, RemoteTlsConfigError> {
    if pem.trim().is_empty() {
        return Err(RemoteTlsConfigError::MissingCertificate);
    }
    let certs = CertificateDer::pem_slice_iter(pem.as_bytes())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| RemoteTlsConfigError::InvalidCertificatePem(error.to_string()))?;
    if certs.is_empty() {
        return Err(RemoteTlsConfigError::InvalidCertificatePem(
            "no certificate PEM blocks found".to_string(),
        ));
    }
    Ok(certs)
}

fn parse_private_key(pem: &str) -> Result<PrivateKeyDer<'static>, RemoteTlsConfigError> {
    if pem.trim().is_empty() {
        return Err(RemoteTlsConfigError::MissingPrivateKey);
    }
    PrivateKeyDer::from_pem_slice(pem.as_bytes())
        .map_err(|error| RemoteTlsConfigError::InvalidPrivateKeyPem(error.to_string()))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
async fn handle_tcp_accept_error(error: io::Error) {
    if is_transient_accept_error(&error) {
        yield_now().await;
        return;
    }
    tracing::error!(%error, "remote TLS TCP accept failed");
    sleep(Duration::from_secs(1)).await;
}

fn is_transient_accept_error(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::ConnectionRefused
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::Interrupted
            | io::ErrorKind::WouldBlock
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn handle_tls_handshake_error(addr: SocketAddr, error: &io::Error) {
    tracing::debug!(
        remote_addr = %addr,
        %error,
        "remote TLS handshake failed"
    );
}

fn ensure_rustls_provider() {
    RUSTLS_PROVIDER.get_or_init(install_remote_tls_rustls_provider);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn install_remote_tls_rustls_provider() {
    if default_provider().install_default().is_err() {
        tracing::warn!("rustls crypto provider was already installed before remote TLS setup");
    }
}
