use std::fs;

use tempfile::TempDir;

use super::*;

fn write_go_mod(dir: &TempDir, content: &str) {
    fs::write(dir.path().join("go.mod"), content).unwrap();
}

#[test]
fn detect_version_parses_standard_entry() {
    let dir = TempDir::new().unwrap();
    write_go_mod(
        &dir,
        "module example.com/foo\n\nrequire (\n\tsigs.k8s.io/gateway-api v1.2.1\n)\n",
    );
    assert_eq!(detect_gateway_version(dir.path()).unwrap(), "v1.2.1");
}

#[test]
fn detect_version_strips_no_extra_v_prefix() {
    // Ensure we don't produce "vv1.2.1" - the regex captures after the `v`.
    let dir = TempDir::new().unwrap();
    write_go_mod(&dir, "require sigs.k8s.io/gateway-api v0.8.0 // indirect\n");
    let version = detect_gateway_version(dir.path()).unwrap();
    assert_eq!(version, "v0.8.0");
    assert!(!version.starts_with("vv"));
}

#[test]
fn detect_version_errors_on_missing_go_mod() {
    let dir = TempDir::new().unwrap();
    let err = detect_gateway_version(dir.path()).unwrap_err();
    assert_eq!(err.code(), "KSRCLI014"); // MissingFile
}

#[test]
fn detect_version_errors_when_pattern_absent() {
    let dir = TempDir::new().unwrap();
    write_go_mod(
        &dir,
        "module example.com/foo\n\nrequire (\n\tsome.other/dep v1.0.0\n)\n",
    );
    let err = detect_gateway_version(dir.path()).unwrap_err();
    assert_eq!(err.code(), "KSRCLI032"); // GatewayVersionMissing
}

#[test]
fn install_url_contains_version_and_standard_path() {
    let url = gateway_install_url("v1.2.1");
    assert_eq!(
        url,
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
    );
}

#[test]
fn install_url_embeds_arbitrary_version() {
    let url = gateway_install_url("v0.99.0-rc.1");
    assert!(url.contains("v0.99.0-rc.1"));
    assert!(url.ends_with("/standard-install.yaml"));
}
