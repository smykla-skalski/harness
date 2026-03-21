use super::*;

#[test]
fn files_for_uses_standard_temp_paths() {
    let files = KumaService::files_for("demo");

    assert_eq!(files.token_path, "/tmp/demo-token");
    assert_eq!(files.dataplane_path, "/tmp/demo-dp.yaml");
    assert_eq!(files.ca_cert_path, "/tmp/demo-ca.crt");
}

#[test]
fn readiness_url_uses_envoy_ready_port() {
    assert_eq!(
        KumaService::readiness_url("172.57.0.10"),
        "http://172.57.0.10:9902/ready"
    );
}

#[test]
fn xds_cp_address_formats_https_endpoint() {
    let xds = XdsAccess {
        ip: "172.57.0.2",
        port: 5678,
    };

    assert_eq!(KumaService::xds_cp_address(xds), "https://172.57.0.2:5678");
}

#[test]
fn derive_service_image_rewrites_cp_image() {
    let image = KumaService::derive_service_image("docker.io/kumahq/kuma-cp:2.12.0")
        .expect("expected derived image");

    assert_eq!(image.as_ref(), "docker.io/kumahq/kuma-universal:2.12.0");
}

#[test]
fn derive_service_image_rejects_unknown_image_shape() {
    let error =
        KumaService::derive_service_image("custom/image:latest").expect_err("expected error");

    assert!(error.to_string().contains("derive_service_image"));
}

#[test]
fn render_dataplane_template_renders_expected_fields() {
    let spec = KumaServiceSpec {
        name: "demo".to_string(),
        mesh: "default".to_string(),
        address: "172.57.0.10".to_string(),
        port: 8080,
        transparent_proxy: false,
    };

    let rendered = KumaService::render_dataplane_template(
        "dataplane",
        "{{ name }} {{ mesh }} {{ address }} {{ port }} {{ protocol }}",
        &spec,
    )
    .expect("expected template render");

    assert_eq!(rendered, "demo default 172.57.0.10 8080 http");
}

#[test]
fn render_dataplane_uses_standard_template_without_transparent_proxy() {
    let rendered =
        render_dataplane("demo", "default", "172.57.0.10", 8080, false).expect("expected render");

    assert!(rendered.contains("type: Dataplane"));
    assert!(rendered.contains("mesh: default"));
    assert!(rendered.contains("name: demo"));
    assert!(rendered.contains("address: 172.57.0.10"));
    assert!(rendered.contains("- port: 8080"));
    assert!(!rendered.contains("transparentProxying"));
}

#[test]
fn render_dataplane_uses_transparent_proxy_template_when_requested() {
    let rendered =
        render_dataplane("demo", "default", "172.57.0.10", 8080, true).expect("expected render");

    assert!(rendered.contains("type: Dataplane"));
    assert!(rendered.contains("transparentProxying"));
    assert!(rendered.contains("redirectPortInbound: 15006"));
}

#[test]
fn launch_for_builds_kuma_dp_args() {
    let files = KumaService::files_for("demo");
    let launch = KumaService::launch_for(
        "demo",
        &files,
        XdsAccess {
            ip: "172.57.0.2",
            port: 5678,
        },
    );

    assert_eq!(launch.cp_address, "https://172.57.0.2:5678");
    assert!(launch.args.iter().any(|arg| arg == "kuma-dp"));
    assert!(
        launch
            .args
            .iter()
            .any(|arg| arg == "--dataplane-token-file=/tmp/demo-token")
    );
}
