use super::*;

#[test]
fn default_cp_addr_uses_api_port() {
    assert_eq!(default_cp_addr("172.57.0.2"), "http://172.57.0.2:5681");
}

#[test]
fn default_xds_addr_uses_xds_port() {
    assert_eq!(default_xds_addr("172.57.0.2"), "https://172.57.0.2:5678");
}

#[test]
fn universal_env_contains_expected_keys() {
    let env = universal_env(STORE_MEMORY);
    assert!(
        env.iter()
            .any(|(k, v)| k == ENV_KUMA_ENVIRONMENT && v == UNIVERSAL_ENVIRONMENT)
    );
    assert!(
        env.iter()
            .any(|(k, v)| k == ENV_KUMA_MODE && v == ZONE_MODE)
    );
    assert!(
        env.iter()
            .any(|(k, v)| k == ENV_KUMA_STORE_TYPE && v == STORE_MEMORY)
    );
}

#[test]
fn global_zone_settings_include_expected_entries() {
    let settings = global_zone_helm_settings();
    assert!(settings.contains(&HELM_CONTROL_PLANE_MODE_GLOBAL.to_string()));
    assert!(settings.contains(&HELM_GLOBAL_ZONE_SYNC_NODE_PORT.to_string()));
}

#[test]
fn zone_settings_include_zone_and_kds() {
    let settings = zone_helm_settings("zone-a", "grpcs://10.0.0.1:1234");
    assert!(settings.contains(&"controlPlane.zone=zone-a".to_string()));
    assert!(settings.contains(&"controlPlane.kdsGlobalAddress=grpcs://10.0.0.1:1234".to_string()));
    assert!(settings.contains(&HELM_KDS_SKIP_VERIFY.to_string()));
}

#[test]
fn looks_like_kuma_cp_image_detects_expected_shape() {
    assert!(looks_like_kuma_cp_image("docker.io/kumahq/kuma-cp:2.12.0"));
    assert!(!looks_like_kuma_cp_image("docker.io/library/nginx:latest"));
}

#[test]
fn derive_universal_service_image_rewrites_cp_name() {
    let derived = derive_universal_service_image("docker.io/kumahq/kuma-cp:2.12.0").unwrap();
    assert_eq!(derived, "docker.io/kumahq/kuma-universal:2.12.0");
}
