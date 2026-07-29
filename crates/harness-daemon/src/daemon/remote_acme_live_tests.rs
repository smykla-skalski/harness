use crate::daemon::remote::{RemoteAcmeChallenge, RemoteDaemonServeConfig};
use crate::daemon::remote_acme::RemoteCertificateBundle;
use crate::daemon::remote_acme_challenge::SystemRemoteAcmeChallengeLease;
use crate::daemon::remote_acme_issuer::{
    RemoteAcmeChallengeMaterial, RemoteAcmeChallengeProvisioner,
};
use crate::daemon::remote_tls::RemoteTlsConfigHandle;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpStream;

use super::{LiveRemoteAcmeChallengeLease, LiveRemoteAcmeChallengeProvisioner};

#[tokio::test]
async fn live_acme_provisioner_publishes_tls_alpn_on_existing_listener() {
    let tls = RemoteTlsConfigHandle::new(generated_bundle()).expect("TLS config");
    let provisioner =
        LiveRemoteAcmeChallengeProvisioner::from_environment(&serve_config(), tls.clone())
            .expect("live challenge provisioner");

    let lease = provisioner
        .present(RemoteAcmeChallengeMaterial::TlsAlpn01 {
            domain: "daemon.example.com".to_string(),
            bind_host: "0.0.0.0".to_string(),
            port: 443,
            digest: vec![7_u8; 32],
        })
        .await
        .expect("present live TLS challenge");

    assert!(tls.tls_alpn_challenge_active());
    provisioner.cleanup(lease).await.expect("cleanup challenge");
    assert!(!tls.tls_alpn_challenge_active());
}

#[tokio::test]
async fn live_acme_provisioner_rejects_tls_alpn_for_wrong_bound_port() {
    let tls = RemoteTlsConfigHandle::new(generated_bundle()).expect("TLS config");
    let provisioner =
        LiveRemoteAcmeChallengeProvisioner::from_environment(&serve_config(), tls.clone())
            .expect("live challenge provisioner");

    let error = provisioner
        .present(RemoteAcmeChallengeMaterial::TlsAlpn01 {
            domain: "daemon.example.com".to_string(),
            bind_host: "0.0.0.0".to_string(),
            port: 8443,
            digest: vec![7_u8; 32],
        })
        .await
        .expect_err("wrong bound port must fail closed");

    assert!(error.contains("does not match the active listener"));
    assert!(!tls.tls_alpn_challenge_active());
}

#[tokio::test]
async fn live_acme_provisioner_delegates_http01_to_standalone_listener() {
    let tls = RemoteTlsConfigHandle::new(generated_bundle()).expect("TLS config");
    let mut config = serve_config();
    config.acme_challenge = RemoteAcmeChallenge::Http;
    config.http_port = 0;
    let provisioner = LiveRemoteAcmeChallengeProvisioner::from_environment(&config, tls)
        .expect("live challenge provisioner");

    let lease = provisioner
        .present(RemoteAcmeChallengeMaterial::Http01 {
            domain: "daemon.example.com".to_string(),
            bind_host: "127.0.0.1".to_string(),
            port: 0,
            token: "http-token".to_string(),
            key_authorization: "http-token.key-authorization".to_string(),
        })
        .await
        .expect("present HTTP-01 challenge");
    let LiveRemoteAcmeChallengeLease::System(SystemRemoteAcmeChallengeLease::Http(server)) = &lease
    else {
        panic!("HTTP-01 must use the standalone system listener");
    };
    let mut stream = TcpStream::connect(server.local_addr())
        .await
        .expect("connect HTTP-01 listener");
    stream
        .write_all(
            b"GET /.well-known/acme-challenge/http-token HTTP/1.1\r\nHost: daemon.example.com\r\nConnection: close\r\n\r\n",
        )
        .await
        .expect("write HTTP-01 request");
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .await
        .expect("read HTTP-01 response");

    assert!(response.starts_with("HTTP/1.1 200 OK"));
    assert!(response.ends_with("http-token.key-authorization"));
    provisioner.cleanup(lease).await.expect("cleanup challenge");
}

fn serve_config() -> RemoteDaemonServeConfig {
    RemoteDaemonServeConfig {
        domain: "daemon.example.com".to_string(),
        host: "0.0.0.0".to_string(),
        https_port: 443,
        http_port: 80,
        acme_email: "ops@example.com".to_string(),
        acme_challenge: RemoteAcmeChallenge::TlsAlpn,
        acme_dns_provider: None,
    }
}

fn generated_bundle() -> RemoteCertificateBundle {
    let key = rcgen::KeyPair::generate().expect("generate key");
    let certificate = rcgen::CertificateParams::new(["daemon.example.com".to_string()])
        .expect("certificate params")
        .self_signed(&key)
        .expect("self-sign certificate");
    RemoteCertificateBundle::new(certificate.pem().as_str(), &key.serialize_pem())
}
