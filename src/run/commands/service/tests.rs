use crate::kernel::topology::{ClusterSpec, Platform};
use crate::platform::runtime::ClusterRuntime;
use crate::run::services::service_lifecycle::extract_pem_certificates;

#[test]
fn resolve_image_explicit_wins() {
    let spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/r",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    let runtime = ClusterRuntime::from_spec(&spec);
    let result = runtime.service_image(Some("my-image:v1")).unwrap();
    assert_eq!(result, "my-image:v1");
}

#[test]
fn resolve_image_derives_from_cp_image() {
    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/r",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.cp_image = Some("kuma-cp:dev".into());
    let runtime = ClusterRuntime::from_spec(&spec);
    let result = runtime.service_image(None).unwrap();
    assert_eq!(result, "kuma-universal:dev");
}

#[test]
fn extract_pem_certificates_finds_certs() {
    let raw = "CONNECTED\n\
        depth=0 CN=kuma-cp\n\
        ---\n\
        -----BEGIN CERTIFICATE-----\n\
        MIIB1234==\n\
        -----END CERTIFICATE-----\n\
        ---\n\
        other noise\n";
    let cert = extract_pem_certificates(raw);
    assert!(cert.contains("BEGIN CERTIFICATE"));
    assert!(cert.contains("MIIB1234=="));
    assert!(!cert.contains("CONNECTED"));
}

#[test]
fn extract_pem_certificates_empty_on_no_cert() {
    let raw = "CONNECTED\nno cert here\n";
    assert!(extract_pem_certificates(raw).is_empty());
}

#[test]
fn resolve_image_errors_when_no_cp_image() {
    let spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/r",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    let runtime = ClusterRuntime::from_spec(&spec);
    let result = runtime.service_image(None);
    assert!(result.is_err());
}
