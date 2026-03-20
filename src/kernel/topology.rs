use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[path = "topology/parsing.rs"]
mod parsing;

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
            kubeconfig: kubeconfig
                .map_or_else(|| parsing::kubeconfig_for_cluster(name), Into::into),
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
            mode_args: parsing::parse_string_vec(obj.get("mode_args")),
            helm_settings: parsing::parse_helm_settings(obj),
            restart_namespaces: parsing::parse_string_vec(obj.get("restart_namespaces")),
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

#[cfg(test)]
#[path = "topology/tests.rs"]
mod tests;
