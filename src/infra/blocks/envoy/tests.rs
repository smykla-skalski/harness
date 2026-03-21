use super::*;

#[test]
fn fake_proxy_returns_canned_dump() {
    let fake = FakeProxyIntrospector::new("{\"configs\":[]}");
    let request = CaptureRequest {
        namespace: "ns",
        workload: "deploy/x",
        container: "sidecar",
        admin_host: "127.0.0.1",
        admin_port: 9901,
        admin_path: "/config_dump",
        kubeconfig: None,
    };
    let result = fake.capture_config_dump(&request).expect("should succeed");
    assert_eq!(result, "{\"configs\":[]}");
}

#[test]
fn extract_bootstrap_filters_by_grep() {
    let fake = FakeProxyIntrospector::new("");
    let payload = "line one\nbootstrap: true\nline three\nbootstrap: false";
    let filtered = fake.extract_bootstrap(payload, Some("bootstrap"));
    assert_eq!(filtered, "bootstrap: true\nbootstrap: false");
}

#[test]
fn extract_bootstrap_returns_full_without_grep() {
    let fake = FakeProxyIntrospector::new("");
    let payload = "line one\nline two";
    let result = fake.extract_bootstrap(payload, None);
    assert_eq!(result, payload);
}

#[test]
fn find_route_returns_none_for_empty_config() {
    let fake = FakeProxyIntrospector::new("");
    assert!(fake.find_route("{\"configs\":[]}", "/test").is_none());
}

#[test]
fn proxy_introspector_is_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<EnvoyIntrospector>();
    assert_send_sync::<FakeProxyIntrospector>();
}
