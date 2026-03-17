mod deploy;
mod record;
mod spec;

pub use deploy::CurrentDeployPayload;
pub use record::ClusterRecordPayload;
pub use spec::{ClusterSpec, HelmSetting};

use std::collections::HashSet;
use std::env;
use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Deployment platform for a cluster: Kubernetes (k3d) or Universal (Docker).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum Platform {
    #[default]
    Kubernetes,
    Universal,
}

impl fmt::Display for Platform {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl Platform {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Kubernetes => "kubernetes",
            Self::Universal => "universal",
        }
    }
}

impl FromStr for Platform {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "kubernetes" | "k8s" => Ok(Self::Kubernetes),
            "universal" => Ok(Self::Universal),
            _ => Err(format!("unsupported platform: {s}")),
        }
    }
}

/// Cluster deployment mode describing the topology and lifecycle direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum ClusterMode {
    SingleUp,
    SingleDown,
    GlobalZoneUp,
    GlobalZoneDown,
    GlobalTwoZonesUp,
    GlobalTwoZonesDown,
}

impl ClusterMode {
    #[must_use]
    pub fn is_up(self) -> bool {
        matches!(
            self,
            Self::SingleUp | Self::GlobalZoneUp | Self::GlobalTwoZonesUp
        )
    }

    #[must_use]
    pub fn is_single(self) -> bool {
        matches!(self, Self::SingleUp | Self::SingleDown)
    }

    #[must_use]
    pub fn is_global(self) -> bool {
        !self.is_single()
    }
}

impl fmt::Display for ClusterMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl ClusterMode {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SingleUp => "single-up",
            Self::SingleDown => "single-down",
            Self::GlobalZoneUp => "global-zone-up",
            Self::GlobalZoneDown => "global-zone-down",
            Self::GlobalTwoZonesUp => "global-two-zones-up",
            Self::GlobalTwoZonesDown => "global-two-zones-down",
        }
    }
}

impl FromStr for ClusterMode {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "single-up" => Ok(Self::SingleUp),
            "single-down" => Ok(Self::SingleDown),
            "global-zone-up" => Ok(Self::GlobalZoneUp),
            "global-zone-down" => Ok(Self::GlobalZoneDown),
            "global-two-zones-up" => Ok(Self::GlobalTwoZonesUp),
            "global-two-zones-down" => Ok(Self::GlobalTwoZonesDown),
            _ => Err(format!("unsupported cluster mode: {s}")),
        }
    }
}

/// A member of a cluster deployment (zone or global).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClusterMember {
    pub name: String,
    pub role: String,
    pub kubeconfig: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zone_name: Option<String>,
    /// Docker container ID (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container_id: Option<String>,
    /// IP address on the Docker network (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container_ip: Option<String>,
    /// Published CP API port (universal mode only, default 5681).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_api_port: Option<u16>,
    /// XDS port (universal mode only, default 5678).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xds_port: Option<u16>,
    /// KDS port for global CP (universal mode only, default 5685).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kds_port: Option<u16>,
}

impl ClusterMember {
    /// Build a member, generating a default kubeconfig path when none is given.
    #[must_use]
    pub fn named(
        name: &str,
        role: &str,
        kubeconfig: Option<&str>,
        zone_name: Option<&str>,
    ) -> Self {
        Self {
            name: name.into(),
            role: role.into(),
            kubeconfig: kubeconfig.map_or_else(|| kubeconfig_for_cluster(name), Into::into),
            zone_name: zone_name.map(Into::into),
            container_id: None,
            container_ip: None,
            cp_api_port: None,
            xds_port: None,
            kds_port: None,
        }
    }

    /// Build a universal-mode member with empty kubeconfig.
    #[must_use]
    pub fn universal(name: &str, role: &str, zone_name: Option<&str>) -> Self {
        Self {
            name: name.into(),
            role: role.into(),
            kubeconfig: String::new(),
            zone_name: zone_name.map(Into::into),
            container_id: None,
            container_ip: None,
            cp_api_port: Some(5681),
            xds_port: Some(5678),
            kds_port: None,
        }
    }

    pub(crate) fn from_value(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("member must be an object")?;
        let name = obj
            .get("name")
            .and_then(Value::as_str)
            .ok_or("member missing name")?;
        let role = obj
            .get("role")
            .and_then(Value::as_str)
            .ok_or("member missing role")?;
        let kubeconfig = obj.get("kubeconfig").and_then(Value::as_str);
        let zone_name = obj.get("zone_name").and_then(Value::as_str);
        let mut member = Self::named(name, role, kubeconfig, zone_name);
        member.container_id = obj
            .get("container_id")
            .and_then(Value::as_str)
            .map(Into::into);
        member.container_ip = obj
            .get("container_ip")
            .and_then(Value::as_str)
            .map(Into::into);
        member.cp_api_port = obj
            .get("cp_api_port")
            .and_then(Value::as_u64)
            .map(|v| u16::try_from(v).unwrap_or(5681));
        member.xds_port = obj
            .get("xds_port")
            .and_then(Value::as_u64)
            .map(|v| u16::try_from(v).unwrap_or(5678));
        member.kds_port = obj
            .get("kds_port")
            .and_then(Value::as_u64)
            .map(|v| u16::try_from(v).unwrap_or(5685));
        Ok(member)
    }
}

// ---------------------------------------------------------------------------
// Parser utilities
// ---------------------------------------------------------------------------

fn kubeconfig_for_cluster(cluster: &str) -> String {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    format!("{home}/.kube/kind-{cluster}-config")
}

fn parse_string_vec(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default()
}

fn parse_helm_settings(obj: &serde_json::Map<String, Value>) -> Vec<HelmSetting> {
    let Some(arr) = obj.get("helm_settings").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut settings: Vec<HelmSetting> = arr
        .iter()
        .filter_map(|v| {
            let o = v.as_object()?;
            Some(HelmSetting {
                key: o.get("key")?.as_str()?.into(),
                value: o.get("value")?.as_str()?.into(),
            })
        })
        .collect();
    settings.sort_by(|a, b| a.key.cmp(&b.key));
    settings
}

fn dedup_preserving_order(items: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    items
        .into_iter()
        .filter(|s| seen.insert(s.clone()))
        .collect()
}

fn members_for_mode(mode: ClusterMode, args: &[String]) -> Result<Vec<ClusterMember>, String> {
    if mode.is_single() {
        if args.len() != 1 {
            return Err(format!(
                "{mode} expects exactly 1 cluster name, got {args:?}"
            ));
        }
        return Ok(vec![ClusterMember::named(&args[0], "primary", None, None)]);
    }
    match mode {
        ClusterMode::GlobalZoneUp => {
            if args.len() != 3 {
                return Err(format!(
                    "{mode} expects global, zone, and zone name, got {args:?}"
                ));
            }
            Ok(vec![
                ClusterMember::named(&args[0], "global", None, None),
                ClusterMember::named(&args[1], "zone", None, Some(&args[2])),
            ])
        }
        ClusterMode::GlobalZoneDown => {
            if args.len() != 2 {
                return Err(format!(
                    "{mode} expects global and zone cluster names, got {args:?}"
                ));
            }
            Ok(vec![
                ClusterMember::named(&args[0], "global", None, None),
                ClusterMember::named(&args[1], "zone", None, None),
            ])
        }
        ClusterMode::GlobalTwoZonesUp => {
            if args.len() != 5 {
                return Err(format!(
                    "{mode} expects global, two zones, and two zone names, got {args:?}"
                ));
            }
            Ok(vec![
                ClusterMember::named(&args[0], "global", None, None),
                ClusterMember::named(&args[1], "zone", None, Some(&args[3])),
                ClusterMember::named(&args[2], "zone", None, Some(&args[4])),
            ])
        }
        ClusterMode::GlobalTwoZonesDown => {
            if args.len() != 3 {
                return Err(format!(
                    "{mode} expects global and two zone cluster names, got {args:?}"
                ));
            }
            Ok(vec![
                ClusterMember::named(&args[0], "global", None, None),
                ClusterMember::named(&args[1], "zone", None, None),
                ClusterMember::named(&args[2], "zone", None, None),
            ])
        }
        ClusterMode::SingleUp | ClusterMode::SingleDown => {
            unreachable!("single modes return early above")
        }
    }
}

fn universal_members_for_mode(
    mode: ClusterMode,
    args: &[String],
) -> Result<Vec<ClusterMember>, String> {
    if mode.is_single() {
        if args.len() != 1 {
            return Err(format!(
                "{mode} expects exactly 1 cluster name, got {args:?}"
            ));
        }
        return Ok(vec![ClusterMember::universal(&args[0], "cp", None)]);
    }
    match mode {
        ClusterMode::GlobalZoneUp => {
            if args.len() != 3 {
                return Err(format!(
                    "{mode} expects global, zone, and zone name, got {args:?}"
                ));
            }
            let mut global = ClusterMember::universal(&args[0], "global-cp", None);
            global.kds_port = Some(5685);
            Ok(vec![
                global,
                ClusterMember::universal(&args[1], "zone-cp", Some(&args[2])),
            ])
        }
        ClusterMode::GlobalZoneDown => {
            if args.len() != 2 {
                return Err(format!(
                    "{mode} expects global and zone cluster names, got {args:?}"
                ));
            }
            Ok(vec![
                ClusterMember::universal(&args[0], "global-cp", None),
                ClusterMember::universal(&args[1], "zone-cp", None),
            ])
        }
        ClusterMode::GlobalTwoZonesUp => {
            if args.len() != 5 {
                return Err(format!(
                    "{mode} expects global, two zones, and two zone names, got {args:?}"
                ));
            }
            let mut global = ClusterMember::universal(&args[0], "global-cp", None);
            global.kds_port = Some(5685);
            Ok(vec![
                global,
                ClusterMember::universal(&args[1], "zone-cp", Some(&args[3])),
                ClusterMember::universal(&args[2], "zone-cp", Some(&args[4])),
            ])
        }
        ClusterMode::GlobalTwoZonesDown => {
            if args.len() != 3 {
                return Err(format!(
                    "{mode} expects global and two zone cluster names, got {args:?}"
                ));
            }
            Ok(vec![
                ClusterMember::universal(&args[0], "global-cp", None),
                ClusterMember::universal(&args[1], "zone-cp", None),
                ClusterMember::universal(&args[2], "zone-cp", None),
            ])
        }
        ClusterMode::SingleUp | ClusterMode::SingleDown => {
            unreachable!("single modes return early above")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn from_object_requires_mode() {
        let result = ClusterSpec::from_object(&json!({"repo_root": "/r"}));
        assert!(result.is_err());
    }

    #[test]
    fn current_deploy_round_trip() {
        let spec = ClusterSpec::from_object(&json!({
            "mode": "single-up",
            "mode_args": ["kuma-test"],
            "members": [{"name": "kuma-test", "role": "primary", "kubeconfig": "/tmp/kuma-test-config"}],
            "helm_settings": [{"key": "cp.mode", "value": "standalone"}],
            "restart_namespaces": ["kuma-system"],
            "repo_root": "/repo",
        }))
        .unwrap();

        let payload = spec.to_current_deploy_dict("now");
        let hs = payload["helm_settings"].as_array().unwrap();
        assert_eq!(hs[0]["key"].as_str().unwrap(), "cp.mode");
        assert_eq!(hs[0]["value"].as_str().unwrap(), "standalone");
        assert!(spec.matches_deploy_dict(&payload));
    }

    #[test]
    fn helm_setting_from_cli_arg() {
        let s = HelmSetting::from_cli_arg("controlPlane.mode=global").unwrap();
        assert_eq!(s.key, "controlPlane.mode");
        assert_eq!(s.value, "global");
        assert_eq!(s.to_cli_arg(), "controlPlane.mode=global");
    }

    #[test]
    fn helm_setting_from_cli_arg_rejects_invalid() {
        assert!(HelmSetting::from_cli_arg("noequals").is_err());
        assert!(HelmSetting::from_cli_arg("=value").is_err());
    }

    #[test]
    fn from_value_rejects_corrupt_member() {
        let result = ClusterRecordPayload::from_value(&json!({
            "mode": "single-up",
            "mode_args": ["kuma-1"],
            "members": [{"not_a_name": "bad"}],
            "repo_root": "/r",
        }));
        assert!(result.is_err(), "expected Err for corrupt member, got Ok");
    }

    #[test]
    fn from_mode_single_up() {
        let spec = ClusterSpec::from_mode("single-up", &["kuma-1".into()], "/repo", vec![], vec![])
            .unwrap();
        assert_eq!(spec.cluster_names(), vec!["kuma-1"]);
        assert_eq!(spec.members[0].role, "primary");
        assert!(spec.primary_kubeconfig().ends_with("kind-kuma-1-config"));
    }

    #[test]
    fn from_mode_global_zone_up() {
        let spec = ClusterSpec::from_mode(
            "global-zone-up",
            &["g".into(), "z".into(), "zone-1".into()],
            "/repo",
            vec![],
            vec![],
        )
        .unwrap();
        assert_eq!(spec.members.len(), 2);
        assert_eq!(spec.members[0].role, "global");
        assert_eq!(spec.members[1].role, "zone");
        assert_eq!(spec.members[1].zone_name.as_deref(), Some("zone-1"));
    }

    #[test]
    fn from_mode_rejects_invalid_mode() {
        assert!(ClusterSpec::from_mode("bad-mode", &[], "/r", vec![], vec![]).is_err());
    }

    #[test]
    fn dedup_restart_namespaces() {
        let spec = ClusterSpec::from_mode(
            "single-up",
            &["k".into()],
            "/r",
            vec![],
            vec!["ns".into(), "ns".into(), "other".into()],
        )
        .unwrap();
        assert_eq!(spec.restart_namespaces, vec!["ns", "other"]);
    }

    // --- Platform tests ---

    #[test]
    fn platform_display_roundtrip() {
        for (text, expected) in [
            ("kubernetes", Platform::Kubernetes),
            ("universal", Platform::Universal),
        ] {
            assert_eq!(expected.to_string(), text);
            assert_eq!(text.parse::<Platform>().unwrap(), expected);
        }
    }

    #[test]
    fn platform_k8s_alias() {
        assert_eq!("k8s".parse::<Platform>().unwrap(), Platform::Kubernetes);
    }

    #[test]
    fn platform_default_is_kubernetes() {
        assert_eq!(Platform::default(), Platform::Kubernetes);
    }

    #[test]
    fn platform_rejects_invalid() {
        assert!("docker".parse::<Platform>().is_err());
    }

    #[test]
    fn platform_serde_roundtrip() {
        let json = serde_json::to_string(&Platform::Universal).unwrap();
        assert_eq!(json, "\"universal\"");
        let back: Platform = serde_json::from_str(&json).unwrap();
        assert_eq!(back, Platform::Universal);
    }

    // --- Universal member tests ---

    #[test]
    fn from_mode_universal_single_up() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["test-cp".into()],
            "/repo",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        assert_eq!(spec.platform, Platform::Universal);
        assert_eq!(spec.members.len(), 1);
        assert_eq!(spec.members[0].role, "cp");
        assert!(spec.members[0].kubeconfig.is_empty());
        assert_eq!(spec.members[0].cp_api_port, Some(5681));
        assert_eq!(spec.docker_network.as_deref(), Some("harness-test-cp"));
    }

    #[test]
    fn from_mode_universal_global_zone_up() {
        let spec = ClusterSpec::from_mode_with_platform(
            "global-zone-up",
            &["g".into(), "z".into(), "zone-1".into()],
            "/repo",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        assert_eq!(spec.members.len(), 2);
        assert_eq!(spec.members[0].role, "global-cp");
        assert_eq!(spec.members[0].kds_port, Some(5685));
        assert_eq!(spec.members[1].role, "zone-cp");
        assert_eq!(spec.members[1].zone_name.as_deref(), Some("zone-1"));
    }

    #[test]
    fn primary_api_url_none_for_k8s() {
        let spec =
            ClusterSpec::from_mode("single-up", &["k".into()], "/r", vec![], vec![]).unwrap();
        assert!(spec.primary_api_url().is_none());
    }

    #[test]
    fn primary_api_url_some_for_universal() {
        let mut spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        spec.members[0].container_ip = Some("172.57.0.2".into());
        spec.members[0].cp_api_port = Some(5681);
        assert_eq!(
            spec.primary_api_url().as_deref(),
            Some("http://172.57.0.2:5681")
        );
    }

    #[test]
    fn primary_api_url_none_when_no_ip() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        assert!(spec.primary_api_url().is_none());
    }

    #[test]
    #[allow(clippy::cognitive_complexity)]
    fn universal_spec_serialization_roundtrip() {
        let mut spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        spec.store_type = Some("memory".into());
        spec.cp_image = Some("kuma-cp:latest".into());
        spec.admin_token = Some("test-admin-token-xyz".into());
        spec.members[0].container_id = Some("abc123".into());
        spec.members[0].container_ip = Some("172.57.0.2".into());

        let json_val = spec.to_json_dict();
        let back = ClusterSpec::from_object(&json_val).unwrap();
        assert_eq!(back.platform, Platform::Universal);
        assert_eq!(back.docker_network.as_deref(), Some("harness-cp"));
        assert_eq!(back.store_type.as_deref(), Some("memory"));
        assert_eq!(back.cp_image.as_deref(), Some("kuma-cp:latest"));
        assert_eq!(back.admin_token.as_deref(), Some("test-admin-token-xyz"));
        assert_eq!(back.members[0].container_id.as_deref(), Some("abc123"));
        assert_eq!(back.members[0].container_ip.as_deref(), Some("172.57.0.2"));
    }

    #[test]
    fn admin_token_accessor() {
        let mut spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        assert!(spec.admin_token().is_none());
        spec.admin_token = Some("tok-123".into());
        assert_eq!(spec.admin_token(), Some("tok-123"));
    }

    #[test]
    fn admin_token_skipped_when_none() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        let json = spec.to_json_dict();
        assert!(json.get("admin_token").is_none());
    }

    // --- is_compose_managed tests ---

    #[test]
    fn is_compose_managed_false_for_single_memory() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        assert!(!spec.is_compose_managed());
    }

    #[test]
    fn is_compose_managed_true_for_multi_zone() {
        let spec = ClusterSpec::from_mode_with_platform(
            "global-zone-up",
            &["g".into(), "z".into(), "zone-1".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        assert!(spec.is_compose_managed());
    }

    #[test]
    fn is_compose_managed_true_for_single_postgres() {
        let mut spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        spec.store_type = Some("postgres".into());
        assert!(spec.is_compose_managed());
    }

    #[test]
    fn k8s_from_mode_produces_kubernetes_platform() {
        let spec =
            ClusterSpec::from_mode("single-up", &["k".into()], "/r", vec![], vec![]).unwrap();
        assert_eq!(spec.platform, Platform::Kubernetes);
        assert!(spec.docker_network.is_none());
    }
}
