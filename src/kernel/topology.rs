use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::env;
use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::workspace::HARNESS_PREFIX;

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

impl fmt::Display for ClusterMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container_ip: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_api_port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xds_port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kds_port: Option<u16>,
}

impl ClusterMember {
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

    fn from_value(value: &Value) -> Result<Self, String> {
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
            .map(|value| u16::try_from(value).unwrap_or(5681));
        member.xds_port = obj
            .get("xds_port")
            .and_then(Value::as_u64)
            .map(|value| u16::try_from(value).unwrap_or(5678));
        member.kds_port = obj
            .get("kds_port")
            .and_then(Value::as_u64)
            .map(|value| u16::try_from(value).unwrap_or(5685));
        Ok(member)
    }
}

/// A helm setting (key=value for --set flags).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelmSetting {
    pub key: String,
    pub value: String,
}

impl HelmSetting {
    /// # Errors
    /// Returns an error if the format is invalid.
    pub fn from_cli_arg(raw: &str) -> Result<Self, String> {
        let (key, value) = raw
            .split_once('=')
            .filter(|(key, _)| !key.is_empty())
            .ok_or_else(|| format!("invalid --helm-setting value: {raw}"))?;
        Ok(Self {
            key: key.into(),
            value: value.into(),
        })
    }

    #[must_use]
    pub fn to_cli_arg(&self) -> String {
        format!("{}={}", self.key, self.value)
    }
}

/// Full cluster specification describing a deployment topology.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClusterSpec {
    pub mode: ClusterMode,
    #[serde(default)]
    pub platform: Platform,
    pub members: Vec<ClusterMember>,
    pub mode_args: Vec<String>,
    pub helm_settings: Vec<HelmSetting>,
    pub restart_namespaces: Vec<String>,
    pub repo_root: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub docker_network: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub store_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_image: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub admin_token: Option<String>,
}

impl ClusterSpec {
    /// # Errors
    /// Returns an error if the value cannot be parsed.
    pub fn from_object(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("expected object")?;
        let mode: ClusterMode = obj
            .get("mode")
            .and_then(Value::as_str)
            .ok_or("missing mode")?
            .parse()?;
        let platform: Platform = obj
            .get("platform")
            .and_then(Value::as_str)
            .unwrap_or("kubernetes")
            .parse()
            .unwrap_or_default();
        let mode_args = parse_string_vec(obj.get("mode_args"));
        let members = obj
            .get("members")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .map(ClusterMember::from_value)
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()?
            .unwrap_or_default();
        if members.is_empty() {
            return Err("cluster members must be non-empty".into());
        }
        let mut helm_settings = parse_helm_settings(obj);
        helm_settings.sort_by(|left, right| left.key.cmp(&right.key));
        Ok(Self {
            mode,
            platform,
            members,
            mode_args,
            helm_settings,
            restart_namespaces: parse_string_vec(obj.get("restart_namespaces")),
            repo_root: obj
                .get("repo_root")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            docker_network: obj
                .get("docker_network")
                .and_then(Value::as_str)
                .map(Into::into),
            store_type: obj
                .get("store_type")
                .and_then(Value::as_str)
                .map(Into::into),
            cp_image: obj.get("cp_image").and_then(Value::as_str).map(Into::into),
            admin_token: obj
                .get("admin_token")
                .and_then(Value::as_str)
                .map(Into::into),
        })
    }

    /// # Errors
    /// Returns an error if the mode or arguments are invalid.
    pub fn from_mode(
        mode: &str,
        mode_args: &[String],
        repo_root: &str,
        helm_settings: Vec<HelmSetting>,
        restart_namespaces: Vec<String>,
    ) -> Result<Self, String> {
        Self::from_mode_with_platform(
            mode,
            mode_args,
            repo_root,
            helm_settings,
            restart_namespaces,
            Platform::Kubernetes,
        )
    }

    /// # Errors
    /// Returns an error if the mode or arguments are invalid.
    pub fn from_mode_with_platform(
        mode: &str,
        mode_args: &[String],
        repo_root: &str,
        helm_settings: Vec<HelmSetting>,
        restart_namespaces: Vec<String>,
        platform: Platform,
    ) -> Result<Self, String> {
        let mode: ClusterMode = mode.parse()?;
        let members = match platform {
            Platform::Kubernetes => members_for_mode(mode, mode_args)?,
            Platform::Universal => universal_members_for_mode(mode, mode_args)?,
        };
        let mut helm_settings = helm_settings;
        helm_settings.sort_by(|left, right| left.key.cmp(&right.key));
        let docker_network = if platform == Platform::Universal {
            let first_name = mode_args.first().map_or("default", String::as_str);
            Some(format!("{HARNESS_PREFIX}{first_name}"))
        } else {
            None
        };
        Ok(Self {
            mode,
            platform,
            members,
            mode_args: mode_args.to_vec(),
            helm_settings,
            restart_namespaces: dedup_preserving_order(restart_namespaces),
            repo_root: repo_root.into(),
            docker_network,
            store_type: None,
            cp_image: None,
            admin_token: None,
        })
    }

    #[must_use]
    pub fn primary_api_url(&self) -> Option<String> {
        if self.platform != Platform::Universal {
            return None;
        }
        let member = self.primary_member();
        let ip = member.container_ip.as_deref()?;
        Some(format!(
            "http://{ip}:{}",
            member.cp_api_port.unwrap_or(5681)
        ))
    }

    #[must_use]
    pub fn primary_api_parts(&self) -> Option<(&str, u16)> {
        if self.platform != Platform::Universal {
            return None;
        }
        let member = self.primary_member();
        let ip = member.container_ip.as_deref()?;
        Some((ip, member.cp_api_port.unwrap_or(5681)))
    }

    #[must_use]
    pub fn admin_token(&self) -> Option<&str> {
        self.admin_token.as_deref()
    }

    #[must_use]
    pub fn primary_member(&self) -> &ClusterMember {
        debug_assert!(
            !self.members.is_empty(),
            "primary_member called on ClusterSpec with no members"
        );
        &self.members[0]
    }

    #[must_use]
    pub fn member(&self, name: &str) -> Option<&ClusterMember> {
        self.members.iter().find(|member| member.name == name)
    }

    #[must_use]
    pub fn resolve_container_name<'a>(&'a self, requested: &'a str) -> Cow<'a, str> {
        if !self.is_compose_managed() || self.member(requested).is_none() {
            return Cow::Borrowed(requested);
        }
        let project = self
            .members
            .first()
            .map_or("default", |member| member.name.as_str());
        Cow::Owned(format!("harness-{project}-{requested}-1"))
    }

    #[must_use]
    pub fn primary_kubeconfig(&self) -> &str {
        &self.primary_member().kubeconfig
    }

    #[must_use]
    pub fn cluster_names(&self) -> Vec<&str> {
        self.members
            .iter()
            .map(|member| member.name.as_str())
            .collect()
    }

    #[must_use]
    pub fn is_compose_managed(&self) -> bool {
        self.members.len() > 1
            || self
                .store_type
                .as_deref()
                .is_some_and(|store| store == "postgres")
    }

    #[must_use]
    pub fn kubeconfigs(&self) -> HashMap<&str, &str> {
        self.members
            .iter()
            .map(|member| (member.name.as_str(), member.kubeconfig.as_str()))
            .collect()
    }

    #[must_use]
    /// # Panics
    /// Panics if the derived `Serialize` impl produces invalid JSON.
    pub fn to_json_dict(&self) -> Value {
        serde_json::to_value(self).expect("derived Serialize impl")
    }

    #[must_use]
    pub fn to_current_deploy_dict(&self, updated_at: &str) -> Value {
        CurrentDeployPayload::from_spec(self, updated_at).to_json_dict()
    }

    #[must_use]
    pub fn matches_deploy_dict(&self, payload: &Value) -> bool {
        CurrentDeployPayload::from_value(payload).is_ok_and(|deploy| deploy.matches(self))
    }
}

#[derive(Debug, Clone, PartialEq)]
struct CurrentDeployPayload {
    mode: ClusterMode,
    updated_at: String,
    mode_args: Vec<String>,
    helm_settings: Vec<HelmSetting>,
    restart_namespaces: Vec<String>,
}

impl CurrentDeployPayload {
    fn from_spec(spec: &ClusterSpec, updated_at: &str) -> Self {
        Self {
            mode: spec.mode,
            updated_at: updated_at.into(),
            mode_args: spec.mode_args.clone(),
            helm_settings: spec.helm_settings.clone(),
            restart_namespaces: spec.restart_namespaces.clone(),
        }
    }

    fn from_value(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("expected object")?;
        Ok(Self {
            mode: obj
                .get("mode")
                .and_then(Value::as_str)
                .ok_or("missing mode")?
                .parse()?,
            updated_at: obj
                .get("updated_at")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            mode_args: parse_string_vec(obj.get("mode_args")),
            helm_settings: parse_helm_settings(obj),
            restart_namespaces: parse_string_vec(obj.get("restart_namespaces")),
        })
    }

    fn matches(&self, spec: &ClusterSpec) -> bool {
        self.mode == spec.mode
            && self.mode_args == spec.mode_args
            && self.helm_settings == spec.helm_settings
    }

    fn to_json_dict(&self) -> Value {
        let mut map = serde_json::Map::new();
        map.insert("mode".into(), Value::String(self.mode.to_string()));
        map.insert("updated_at".into(), Value::String(self.updated_at.clone()));
        map.insert(
            "mode_args".into(),
            Value::Array(
                self.mode_args
                    .iter()
                    .map(|item| Value::String(item.clone()))
                    .collect(),
            ),
        );
        map.insert(
            "helm_settings".into(),
            Value::Array(
                self.helm_settings
                    .iter()
                    .map(|setting| {
                        serde_json::json!({
                            "key": setting.key,
                            "value": setting.value,
                        })
                    })
                    .collect(),
            ),
        );
        map.insert(
            "restart_namespaces".into(),
            Value::Array(
                self.restart_namespaces
                    .iter()
                    .map(|item| Value::String(item.clone()))
                    .collect(),
            ),
        );
        Value::Object(map)
    }
}

fn kubeconfig_for_cluster(cluster: &str) -> String {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    format!("{home}/.kube/kind-{cluster}-config")
}

fn parse_string_vec(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        })
        .unwrap_or_default()
}

fn parse_helm_settings(obj: &serde_json::Map<String, Value>) -> Vec<HelmSetting> {
    let Some(items) = obj.get("helm_settings").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut settings = items
        .iter()
        .filter_map(|value| {
            let item = value.as_object()?;
            Some(HelmSetting {
                key: item.get("key")?.as_str()?.into(),
                value: item.get("value")?.as_str()?.into(),
            })
        })
        .collect::<Vec<_>>();
    settings.sort_by(|left, right| left.key.cmp(&right.key));
    settings
}

fn dedup_preserving_order(items: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    items
        .into_iter()
        .filter(|item| seen.insert(item.clone()))
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
        ClusterMode::SingleUp | ClusterMode::SingleDown => unreachable!("single mode handled"),
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
        ClusterMode::SingleUp | ClusterMode::SingleDown => unreachable!("single mode handled"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
    fn cluster_mode_parses_valid_strings() {
        assert_eq!(
            "single-up".parse::<ClusterMode>().unwrap(),
            ClusterMode::SingleUp
        );
        assert_eq!(
            "single-down".parse::<ClusterMode>().unwrap(),
            ClusterMode::SingleDown
        );
        assert_eq!(
            "global-zone-up".parse::<ClusterMode>().unwrap(),
            ClusterMode::GlobalZoneUp
        );
        assert_eq!(
            "global-zone-down".parse::<ClusterMode>().unwrap(),
            ClusterMode::GlobalZoneDown
        );
        assert!("bad-mode".parse::<ClusterMode>().is_err());
    }

    #[test]
    fn from_object_requires_mode() {
        let result = ClusterSpec::from_object(&json!({"repo_root": "/repo"}));
        assert!(result.is_err());
    }

    #[test]
    fn from_object_rejects_legacy_clusters_format() {
        let result = ClusterSpec::from_object(&json!({
            "mode": "global-zone-up",
            "mode_args": ["kuma-global", "kuma-zone", "zone-1"],
            "clusters": ["kuma-global", "kuma-zone"],
            "kubeconfigs": {"kuma-zone": "/tmp/kuma-zone-config"},
            "helm_values": {"controlPlane.mode": "global"},
            "restart_namespaces": ["kuma-system"],
            "repo_root": "/repo"
        }));
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
        let helm_settings = payload["helm_settings"].as_array().unwrap();
        assert_eq!(helm_settings[0]["key"].as_str().unwrap(), "cp.mode");
        assert_eq!(helm_settings[0]["value"].as_str().unwrap(), "standalone");
        assert!(spec.matches_deploy_dict(&payload));
    }

    #[test]
    fn helm_setting_from_cli_arg() {
        let setting = HelmSetting::from_cli_arg("controlPlane.mode=global").unwrap();
        assert_eq!(setting.key, "controlPlane.mode");
        assert_eq!(setting.value, "global");
        assert_eq!(setting.to_cli_arg(), "controlPlane.mode=global");
    }

    #[test]
    fn from_mode_universal_fields_roundtrip() {
        let mut spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["test-cp".into()],
            "/repo",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        spec.admin_token = Some("admin-token-abc123".into());
        spec.docker_network = Some("harness-test-cp".into());
        spec.store_type = Some("memory".into());
        spec.cp_image = Some("kuma-cp:dev".into());
        spec.members[0].container_id = Some("container-xyz".into());
        spec.members[0].container_ip = Some("172.57.0.3".into());

        let json = serde_json::to_string(&spec).unwrap();
        let back: ClusterSpec = serde_json::from_str(&json).unwrap();

        assert_universal_spec_identity(&back);
        assert_universal_spec_runtime(&back);
        assert_universal_spec_member(&back);
    }

    #[test]
    fn from_mode_universal_auto_generates_docker_network() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["my-cp".into()],
            "/repo",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        assert_eq!(spec.docker_network.as_deref(), Some("harness-my-cp"));
    }

    fn assert_universal_spec_identity(spec: &ClusterSpec) {
        assert_eq!(spec.platform, Platform::Universal);
        assert_eq!(spec.admin_token.as_deref(), Some("admin-token-abc123"));
        assert_eq!(spec.docker_network.as_deref(), Some("harness-test-cp"));
    }

    fn assert_universal_spec_runtime(spec: &ClusterSpec) {
        assert_eq!(spec.store_type.as_deref(), Some("memory"));
        assert_eq!(spec.cp_image.as_deref(), Some("kuma-cp:dev"));
    }

    fn assert_universal_spec_member(spec: &ClusterSpec) {
        assert_eq!(
            spec.members[0].container_id.as_deref(),
            Some("container-xyz")
        );
        assert_eq!(spec.members[0].container_ip.as_deref(), Some("172.57.0.3"));
    }

    #[test]
    fn cluster_member_universal_defaults() {
        let member = ClusterMember::universal("test-cp", "cp", None);
        assert_eq!(member.cp_api_port, Some(5681));
        assert_eq!(member.xds_port, Some(5678));
        assert!(member.kds_port.is_none());
    }

    #[test]
    fn cluster_spec_roundtrips_via_json_value() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/repo",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        let json = spec.to_json_dict();
        let back = ClusterSpec::from_object(&json).unwrap();
        assert_eq!(back, spec);
    }
}
