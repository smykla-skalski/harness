use std::env;
use std::io;
#[cfg(test)]
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use axum::Router;
use axum::http::header::CONTENT_TYPE;
use axum::http::{HeaderValue, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use rcgen::{CertificateParams, CustomExtension, DistinguishedName, KeyPair};
use rustls::ServerConfig;
use rustls::crypto::ring::default_provider;
use rustls::crypto::ring::sign::any_supported_type;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio::time::sleep;
use tokio_rustls::TlsAcceptor;

use super::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig};
use super::remote_acme_dns_provider::{SystemDns01Lease, SystemDns01Provider};
use super::remote_acme_issuer::{RemoteAcmeChallengeMaterial, RemoteAcmeChallengeProvisioner};

const HTTP01_PREFIX: &str = "/.well-known/acme-challenge/";

pub(crate) struct Http01ChallengeServer {
    #[cfg(test)]
    local_addr: SocketAddr,
    shutdown: oneshot::Sender<()>,
    task: JoinHandle<io::Result<()>>,
}

impl Http01ChallengeServer {
    pub(crate) async fn start(
        bind_host: &str,
        port: u16,
        token: &str,
        key_authorization: &str,
    ) -> Result<Self, String> {
        validate_http01_material(token, key_authorization)?;
        let listener = TcpListener::bind((bind_host, port))
            .await
            .map_err(|error| format!("bind remote ACME HTTP-01 listener: {error}"))?;
        let local_addr = listener
            .local_addr()
            .map_err(|error| format!("read remote ACME HTTP-01 listener address: {error}"))?;
        #[cfg(not(test))]
        let _ = local_addr;
        let path = format!("{HTTP01_PREFIX}{token}");
        let body = key_authorization.to_string();
        let app = Router::new().route(
            &path,
            get(move || {
                let body = body.clone();
                async move {
                    (
                        StatusCode::OK,
                        [(CONTENT_TYPE, HeaderValue::from_static("text/plain"))],
                        body,
                    )
                        .into_response()
                }
            }),
        );
        let (shutdown, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(async move {
                    let _ = shutdown_rx.await;
                })
                .await
        });
        Ok(Self {
            #[cfg(test)]
            local_addr,
            shutdown,
            task,
        })
    }

    #[must_use]
    #[cfg(test)]
    pub(crate) const fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub(crate) async fn stop(self) -> Result<(), String> {
        let _ = self.shutdown.send(());
        self.task
            .await
            .map_err(|error| format!("join remote ACME HTTP-01 listener: {error}"))?
            .map_err(|error| format!("serve remote ACME HTTP-01 challenge: {error}"))
    }
}

fn validate_http01_material(token: &str, key_authorization: &str) -> Result<(), String> {
    let token = token.trim();
    if token.is_empty()
        || !token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err("remote ACME HTTP-01 token is invalid".to_string());
    }
    if key_authorization.trim().is_empty() {
        return Err("remote ACME HTTP-01 key authorization is required".to_string());
    }
    Ok(())
}

pub(crate) struct TlsAlpn01ChallengeServer {
    #[cfg(test)]
    local_addr: SocketAddr,
    #[cfg(test)]
    certificate_der: Vec<u8>,
    shutdown: oneshot::Sender<()>,
    task: JoinHandle<()>,
}

impl TlsAlpn01ChallengeServer {
    pub(crate) async fn start(
        bind_host: &str,
        port: u16,
        domain: &str,
        digest: &[u8],
    ) -> Result<Self, String> {
        let (config, certificate_der) = tls_alpn01_server_config(domain, digest)?;
        let listener = TcpListener::bind((bind_host, port))
            .await
            .map_err(|error| format!("bind remote ACME TLS-ALPN-01 listener: {error}"))?;
        let local_addr = listener
            .local_addr()
            .map_err(|error| format!("read remote ACME TLS-ALPN-01 listener address: {error}"))?;
        #[cfg(not(test))]
        let _ = local_addr;
        #[cfg(not(test))]
        let _ = certificate_der;
        let (shutdown, mut shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            let acceptor = TlsAcceptor::from(config);
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => break,
                    accepted = listener.accept() => {
                        let Ok((stream, _)) = accepted else { break };
                        let acceptor = acceptor.clone();
                        tokio::spawn(async move {
                            let _ = acceptor.accept(stream).await;
                        });
                    }
                }
            }
        });
        Ok(Self {
            #[cfg(test)]
            local_addr,
            #[cfg(test)]
            certificate_der,
            shutdown,
            task,
        })
    }

    #[must_use]
    #[cfg(test)]
    pub(crate) const fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    #[cfg(test)]
    #[must_use]
    pub(crate) fn certificate_der(&self) -> Vec<u8> {
        self.certificate_der.clone()
    }

    pub(crate) async fn stop(self) -> Result<(), String> {
        let _ = self.shutdown.send(());
        self.task
            .await
            .map_err(|error| format!("join remote ACME TLS-ALPN-01 listener: {error}"))
    }
}

fn tls_alpn01_server_config(
    domain: &str,
    digest: &[u8],
) -> Result<(Arc<ServerConfig>, Vec<u8>), String> {
    let domain = domain.trim();
    if domain.is_empty() {
        return Err("remote ACME TLS-ALPN-01 domain is required".to_string());
    }
    if digest.len() != 32 {
        return Err("remote ACME TLS-ALPN-01 digest must contain 32 bytes".to_string());
    }
    let key = KeyPair::generate()
        .map_err(|error| format!("generate remote ACME TLS-ALPN-01 key: {error}"))?;
    let mut params = CertificateParams::new([domain.to_string()])
        .map_err(|error| format!("build remote ACME TLS-ALPN-01 certificate: {error}"))?;
    params.distinguished_name = DistinguishedName::new();
    params
        .custom_extensions
        .push(CustomExtension::new_acme_identifier(digest));
    let certificate = params
        .self_signed(&key)
        .map_err(|error| format!("sign remote ACME TLS-ALPN-01 certificate: {error}"))?;
    let certificate_der = certificate.der().to_vec();
    let private_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
    let signing_key = any_supported_type(&private_key)
        .map_err(|error| format!("load remote ACME TLS-ALPN-01 key: {error}"))?;
    let certified_key = Arc::new(CertifiedKey::new(
        vec![CertificateDer::from(certificate_der.clone())],
        signing_key,
    ));
    let _ = default_provider().install_default();
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_cert_resolver(Arc::new(TlsAlpn01CertificateResolver {
            domain: domain.to_string(),
            certified_key,
        }));
    config.alpn_protocols = vec![b"acme-tls/1".to_vec()];
    Ok((Arc::new(config), certificate_der))
}

#[derive(Debug)]
struct TlsAlpn01CertificateResolver {
    domain: String,
    certified_key: Arc<CertifiedKey>,
}

impl ResolvesServerCert for TlsAlpn01CertificateResolver {
    fn resolve(&self, client_hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        let matching_name = client_hello.server_name() == Some(self.domain.as_str());
        let offers_acme_alpn = client_hello
            .alpn()
            .is_some_and(|mut protocols| protocols.any(|protocol| protocol == b"acme-tls/1"));
        (matching_name && offers_acme_alpn).then(|| self.certified_key.clone())
    }
}

#[derive(Debug)]
pub(crate) struct SystemRemoteAcmeChallengeProvisioner {
    dns: Option<SystemDns01Provider>,
    dns_propagation_delay: Duration,
}

impl SystemRemoteAcmeChallengeProvisioner {
    pub(crate) fn from_environment(config: &RemoteDaemonServeConfig) -> Result<Self, String> {
        let dns = if config.acme_challenge == RemoteAcmeChallenge::Dns {
            let provider = config
                .acme_dns_provider
                .ok_or_else(|| "remote ACME DNS provider is required".to_string())?;
            Some(SystemDns01Provider::from_environment(provider)?)
        } else {
            None
        };
        let dns_propagation_delay = env::var("HARNESS_REMOTE_ACME_DNS_PROPAGATION_SECONDS")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(|value| {
                value
                    .parse::<u64>()
                    .map(Duration::from_secs)
                    .map_err(|error| {
                        format!("parse HARNESS_REMOTE_ACME_DNS_PROPAGATION_SECONDS: {error}")
                    })
            })
            .transpose()?
            .unwrap_or_else(|| Duration::from_secs(30));
        Ok(Self {
            dns,
            dns_propagation_delay,
        })
    }
}

pub(crate) enum SystemRemoteAcmeChallengeLease {
    Http(Http01ChallengeServer),
    TlsAlpn(TlsAlpn01ChallengeServer),
    Dns(SystemDns01Lease),
}

#[async_trait]
impl RemoteAcmeChallengeProvisioner for SystemRemoteAcmeChallengeProvisioner {
    type Lease = SystemRemoteAcmeChallengeLease;

    async fn present(&self, material: RemoteAcmeChallengeMaterial) -> Result<Self::Lease, String> {
        match material {
            RemoteAcmeChallengeMaterial::Http01 {
                bind_host,
                port,
                token,
                key_authorization,
                ..
            } => Http01ChallengeServer::start(&bind_host, port, &token, &key_authorization)
                .await
                .map(SystemRemoteAcmeChallengeLease::Http),
            RemoteAcmeChallengeMaterial::TlsAlpn01 {
                domain,
                bind_host,
                port,
                digest,
            } => TlsAlpn01ChallengeServer::start(&bind_host, port, &domain, &digest)
                .await
                .map(SystemRemoteAcmeChallengeLease::TlsAlpn),
            RemoteAcmeChallengeMaterial::Dns01 {
                provider,
                record_name,
                record_value,
                ..
            } => {
                let dns = self
                    .dns
                    .as_ref()
                    .ok_or_else(|| "remote ACME DNS provider is not configured".to_string())?;
                let lease = dns.present(provider, &record_name, &record_value).await?;
                sleep(self.dns_propagation_delay).await;
                Ok(SystemRemoteAcmeChallengeLease::Dns(lease))
            }
        }
    }

    async fn cleanup(&self, lease: Self::Lease) -> Result<(), String> {
        match lease {
            SystemRemoteAcmeChallengeLease::Http(server) => server.stop().await,
            SystemRemoteAcmeChallengeLease::TlsAlpn(server) => server.stop().await,
            SystemRemoteAcmeChallengeLease::Dns(lease) => {
                self.dns
                    .as_ref()
                    .ok_or_else(|| "remote ACME DNS provider is not configured".to_string())?
                    .cleanup(lease)
                    .await
            }
        }
    }
}

#[cfg(test)]
#[path = "remote_acme_challenge_tests.rs"]
mod tests;
