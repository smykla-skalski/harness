//! Default values and small helpers for the Kuma control-plane block.
//!
//! This module centralizes stable Kuma defaults that are shared across the
//! block-oriented control-plane abstractions. The goal is to give callers a
//! single source of truth for well-known namespaces, ports, environment names,
//! and image-shape helpers instead of duplicating magic values throughout the
//! codebase.

use std::borrow::Cow;

use crate::infra::blocks::BlockError;
use crate::infra::blocks::kuma::service::KumaService;

/// Default Kuma system namespace for Kubernetes deployments.
pub const SYSTEM_NAMESPACE: &str = "kuma-system";

/// Default Kuma environment name used for universal-mode control planes.
pub const UNIVERSAL_ENVIRONMENT: &str = "universal";

/// Default single-zone mode used by standalone universal control planes.
pub const ZONE_MODE: &str = "zone";

/// Default global mode used by multi-zone setups.
pub const GLOBAL_MODE: &str = "global";

/// Default in-memory store type for lightweight local runs.
pub const STORE_MEMORY: &str = "memory";

/// Default Kuma control-plane admin/API port.
pub const CP_API_PORT: u16 = 5681;

/// Default Kuma XDS port used by universal dataplanes.
pub const XDS_PORT: u16 = 5678;

/// Default Envoy admin port used by sidecars.
pub const ENVOY_ADMIN_PORT: u16 = 9901;

/// Default Envoy readiness/admin probe port used by universal service helpers.
pub const DATAPLANE_READY_PORT: u16 = 9902;

/// Default mesh name for local harness flows.
pub const DEFAULT_MESH: &str = "default";

/// Default dataplane token validity used by current service bootstrap flows.
pub const DEFAULT_TOKEN_VALID_FOR: &str = "24h";

/// Environment variable used to configure Kuma runtime environment.
pub const ENV_KUMA_ENVIRONMENT: &str = "KUMA_ENVIRONMENT";

/// Environment variable used to configure control-plane mode.
pub const ENV_KUMA_MODE: &str = "KUMA_MODE";

/// Environment variable used to configure the backing store type.
pub const ENV_KUMA_STORE_TYPE: &str = "KUMA_STORE_TYPE";

/// Helm setting that switches the control plane into global mode.
pub const HELM_CONTROL_PLANE_MODE_GLOBAL: &str = "controlPlane.mode=global";

/// Helm setting that exposes global zone sync via a `NodePort` in `k3d` flows.
pub const HELM_GLOBAL_ZONE_SYNC_NODE_PORT: &str =
    "controlPlane.globalZoneSyncService.type=NodePort";

/// Helm setting key prefix used to configure a zone name.
pub const HELM_ZONE_NAME_PREFIX: &str = "controlPlane.zone=";

/// Helm setting key prefix used to configure a KDS global address.
pub const HELM_KDS_GLOBAL_ADDRESS_PREFIX: &str = "controlPlane.kdsGlobalAddress=";

/// Helm setting that disables KDS TLS verification for local disposable setups.
pub const HELM_KDS_SKIP_VERIFY: &str = "controlPlane.tls.kdsZoneClient.skipVerify=true";

/// Returns the default API base address for a given control-plane IP.
#[must_use]
pub fn default_cp_addr(ip: &str) -> String {
    format!("http://{ip}:{CP_API_PORT}")
}

/// Returns the default XDS address for a given control-plane IP.
#[must_use]
pub fn default_xds_addr(ip: &str) -> String {
    format!("https://{ip}:{XDS_PORT}")
}

/// Returns the standard Kuma environment tuple used for universal mode.
#[must_use]
pub fn universal_env(store: &str) -> Vec<(String, String)> {
    vec![
        (
            ENV_KUMA_ENVIRONMENT.to_string(),
            UNIVERSAL_ENVIRONMENT.to_string(),
        ),
        (ENV_KUMA_MODE.to_string(), ZONE_MODE.to_string()),
        (ENV_KUMA_STORE_TYPE.to_string(), store.to_string()),
    ]
}

/// Returns the standard local global-zone Helm settings.
#[must_use]
pub fn global_zone_helm_settings() -> Vec<String> {
    vec![
        HELM_CONTROL_PLANE_MODE_GLOBAL.to_string(),
        HELM_GLOBAL_ZONE_SYNC_NODE_PORT.to_string(),
    ]
}

/// Returns the standard local zone Helm settings for a zone connected to a
/// disposable global control plane.
#[must_use]
pub fn zone_helm_settings(zone_name: &str, kds_address: &str) -> Vec<String> {
    vec![
        format!("{HELM_ZONE_NAME_PREFIX}{zone_name}"),
        format!("{HELM_KDS_GLOBAL_ADDRESS_PREFIX}{kds_address}"),
        HELM_KDS_SKIP_VERIFY.to_string(),
    ]
}

/// Returns `true` when the provided image reference looks like a Kuma CP image.
#[must_use]
pub fn looks_like_kuma_cp_image(image: &str) -> bool {
    image.contains("kuma-cp")
}

/// Derive the default universal service image from a Kuma CP image.
///
/// # Errors
///
/// Returns `BlockError` if the image does not look like a supported Kuma CP
/// image.
pub fn derive_universal_service_image(cp_image: &str) -> Result<String, BlockError> {
    KumaService::derive_service_image(cp_image).map(Cow::into_owned)
}

#[cfg(test)]
mod tests {
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
        assert!(
            settings.contains(&"controlPlane.kdsGlobalAddress=grpcs://10.0.0.1:1234".to_string())
        );
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
}
