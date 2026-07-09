use std::io;
use std::net::SocketAddr;

use super::{
    RemoteTlsConfigError, build_remote_tls_server_config, handle_tcp_accept_error,
    handle_tls_handshake_error, is_transient_accept_error,
};
use crate::daemon::remote_acme::RemoteCertificateBundle;

#[test]
fn remote_tls_server_config_rejects_blank_certificate_material() {
    let bundle = RemoteCertificateBundle::new_for_tests("   ", TEST_PRIVATE_KEY_PEM);
    let error = build_remote_tls_server_config(&bundle)
        .expect_err("blank certificate should not build remote TLS config");

    assert_eq!(error, RemoteTlsConfigError::MissingCertificate);
}

#[test]
fn remote_tls_server_config_rejects_blank_private_key_material() {
    let bundle = RemoteCertificateBundle::new_for_tests(TEST_CERTIFICATE_PEM, "\n\t");
    let error = build_remote_tls_server_config(&bundle)
        .expect_err("blank key should not build remote TLS config");

    assert_eq!(error, RemoteTlsConfigError::MissingPrivateKey);
}

#[test]
fn remote_tls_server_config_builds_http_alpn_from_pem_material() {
    let bundle = RemoteCertificateBundle::new_for_tests(TEST_CERTIFICATE_PEM, TEST_PRIVATE_KEY_PEM);
    let config = build_remote_tls_server_config(&bundle).expect("valid remote TLS config");

    assert_eq!(
        config.alpn_protocols,
        vec![b"h2".to_vec(), b"http/1.1".to_vec()]
    );
}

#[test]
fn remote_tls_accept_retries_transient_tcp_errors_without_backoff() {
    for kind in [
        io::ErrorKind::ConnectionRefused,
        io::ErrorKind::ConnectionAborted,
        io::ErrorKind::ConnectionReset,
        io::ErrorKind::Interrupted,
        io::ErrorKind::WouldBlock,
    ] {
        assert!(is_transient_accept_error(&io::Error::from(kind)));
    }
}

#[tokio::test]
async fn remote_tls_accept_transient_errors_do_not_backoff() {
    handle_tcp_accept_error(io::Error::from(io::ErrorKind::WouldBlock)).await;
}

#[test]
fn remote_tls_handshake_failures_do_not_delay_accept_loop() {
    let error = io::Error::from(io::ErrorKind::InvalidData);
    handle_tls_handshake_error(
        SocketAddr::from(([127, 0, 0, 1], 443)),
        &error,
    );
}

const TEST_CERTIFICATE_PEM: &str = r#"-----BEGIN CERTIFICATE-----
MIIDGzCCAgOgAwIBAgIUO6qbgSSvho2GLuSvxiWE6x7/H+wwDQYJKoZIhvcNAQEL
BQAwHTEbMBkGA1UEAwwSZGFlbW9uLmV4YW1wbGUuY29tMB4XDTI2MDcwOTExNTAx
MloXDTI2MDcxMDExNTAxMlowHTEbMBkGA1UEAwwSZGFlbW9uLmV4YW1wbGUuY29t
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApCKXa4o1OtABLolsV/fs
E1njTM+x0qBJFKYVW+3Pi8MCAnnQZ+yYzQ4D8Wfv1zjOy1Y/UYdIiqxBFLNp0erD
xW+b4kuHSKuGDb15ZAys6iRA5bcTKnz8QGKVzmFIwAbS4dPJNzRb7AuDqpOE0Hxh
E6kF/sa/GFz+aW1adDvZZkYrszUPn/3C2DvBjZFEwQgmEX4CUuNySw43tHh+EjFP
nt+Bl5yRazZ/WNfDM3pjjnJcxaYNgP8wv1Hf4AAZqnVi17sH9Z7e3ChJZQF/fNgJ
0+IOd5z9Q9QTlmDgeVgTIn4cgPFs9VKmCsjByek0bIRlybwl4jhuut6KhvrnXCFY
DwIDAQABo1MwUTAdBgNVHQ4EFgQUEQWSux09fVAsGngLhkNIpOgPzj0wHwYDVR0j
BBgwFoAUEQWSux09fVAsGngLhkNIpOgPzj0wDwYDVR0TAQH/BAUwAwEB/zANBgkq
hkiG9w0BAQsFAAOCAQEAEPjbUJyM/J/wBxMIK4JrAJEX2hmkhpHGCp88OKavf6W/
IalWjl70Df+FSc5yBePFKjUUo6S96r5Q4CXBx+DNfRgN26HDk2w55eivYnmi1nNc
VHs+G7SrVjiNijOgozt45HQR4CvAgPxcZoGu1U4lmprrx7HaWIC+56y6MFghb4Kg
+InZkMWy6ySoFbYjMSsPBifaKnuF1NUTPjL0VE8oNyNftIvFjjZuctvHjhlK+FMP
Tys9LeCcV0h6PMHH+/hQLJC4R3RuS2uu55KtmTnhHMjNB3M56XfWb/y18n3GVkys
yy4u0xXmF216ZT32j2SxkTQxQOVG9EqmwaZUcuACYQ==
-----END CERTIFICATE-----"#;

const TEST_PRIVATE_KEY_PEM: &str = r#"-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCkIpdrijU60AEu
iWxX9+wTWeNMz7HSoEkUphVb7c+LwwICedBn7JjNDgPxZ+/XOM7LVj9Rh0iKrEEU
s2nR6sPFb5viS4dIq4YNvXlkDKzqJEDltxMqfPxAYpXOYUjABtLh08k3NFvsC4Oq
k4TQfGETqQX+xr8YXP5pbVp0O9lmRiuzNQ+f/cLYO8GNkUTBCCYRfgJS43JLDje0
eH4SMU+e34GXnJFrNn9Y18MzemOOclzFpg2A/zC/Ud/gABmqdWLXuwf1nt7cKEll
AX982AnT4g53nP1D1BOWYOB5WBMifhyA8Wz1UqYKyMHJ6TRshGXJvCXiOG663oqG
+udcIVgPAgMBAAECggEAOfp2HmitsN607Cli+hf7bkJ8Ri+/krVH22FnfhedDrON
zC4Xbf5nY1emEOo0EIRil/UZXMU63LFIM/XEVYBmMyHfoKopWYQtUEEz1iGcGwE/
Y2WuAX4w5NVuMX6v4hUG/PqAw11dcx4GHoUJj1PAPt+f3IV8DzEaNUeJgjF58+QY
SmSyjvCqhri6CzZD7Ypu6y3RkoAHzWsBC0L3BDzChNSIjYnPIEWr+VZQoQ2LQjR9
tzrmffalCQReePpfoAhHhWY0ECMx1gQY9XKUMqrVhptpIswS3WPz2tY864Px24qq
KL72TdodRiyG0oBbygUvB2uiQ6IeSrN4NGJtzuxjYQKBgQDfBg6FUMEjm7dYd78k
n4vRHS4Sh6dVx0xCJalZ9V/tri6crY/yih48VYWxzAiBEh/yKhr6Q+SduoIf37Jn
5MQQyIAdN6rdYJvNdP/HIQcuIQO4eWvlf5Ztsoecyww90rtQLFbhnfLQVm9e+rmX
qZuYONz123lLe0qJKI8yJcdc+QKBgQC8Z3jkX1imUguDNKXhMGNmvYsXIsbeJuGJ
YemLlT7UVPpwVjIUL1tREWfabdtVVw7lLli9o0UjRGdG1NW/z9K4unt1kHeqmFhp
KmCrt14Gyb+1DERFjc2Av1rv1uSONlfYb07k0PHhbFFHv9LwwZJWZRLVWzSwO5mL
7l7xxlnHRwKBgBZeOCSc1dIpcvkXgX891TsS7yUCoADVbUuRFWwlVQq0lo42RiKw
QZoRhcgwS4YOeE/Ec1I4bvx20Ug7GlybMCLyyQ6lH6j2YIn5uxGQuXSh8QqWewDY
jBDSgBF0t/SXZxwCZnBYdBr7IE5pXSXd5/IbeeXark6ovfAFtl70NQuZAoGBAJXQ
LahjTOnMWc02QyVCxff/hqeaBsrF3hfRXNWaksBi5lYHpIC6e4GGNq/RJVTCCl0h
Mn1xY9u8W+dN/L4usqAj4WJFw3JK/Bp8ESzafZEmQiPkIjGwpZXYE6admVagTdAU
CocWww/+gs9r8H9zXTsH2icABHCSo/FKVgMpN2CnAoGBAKyhHuD2+HadpZ+H6GaL
2pPNV9/lqGJ+CgHUmf1xvPr6zOHQWRYAZ2J3/SslZyyNC1J+dBW+Fps3nnQ3lG62
JBpZ8TiiuDYnOqjZTHejjLdFPS2py0ID0IfBlRE+m9oMFJsZbOR91Ra3zHHKBqMJ
r3onbxBi+otiVHYyfV7mz6XW
-----END PRIVATE KEY-----"#;
