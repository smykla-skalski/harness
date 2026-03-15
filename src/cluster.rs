use std::collections::{HashMap, HashSet};
use std::env;
use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};
use serde_json::Value;

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
        match self {
            Self::SingleUp => f.write_str("single-up"),
            Self::SingleDown => f.write_str("single-down"),
            Self::GlobalZoneUp => f.write_str("global-zone-up"),
            Self::GlobalZoneDown => f.write_str("global-zone-down"),
            Self::GlobalTwoZonesUp => f.write_str("global-two-zones-up"),
            Self::GlobalTwoZonesDown => f.write_str("global-two-zones-down"),
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
    if let Some(arr) = obj.get("helm_settings").and_then(Value::as_array) {
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
        return settings;
    }
    if let Some(map) = obj.get("helm_values").and_then(Value::as_object) {
        let mut settings: Vec<HelmSetting> = map
            .iter()
            .filter_map(|(k, v)| {
                Some(HelmSetting {
                    key: k.clone(),
                    value: v.as_str()?.into(),
                })
            })
            .collect();
        settings.sort_by(|a, b| a.key.cmp(&b.key));
        return settings;
    }
    Vec::new()
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

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A member of a cluster deployment (zone or global).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClusterMember {
    pub name: String,
    pub role: String,
    pub kubeconfig: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zone_name: Option<String>,
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
        Ok(Self::named(name, role, kubeconfig, zone_name))
    }
}

/// A helm setting (key=value for --set flags).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelmSetting {
    pub key: String,
    pub value: String,
}

impl HelmSetting {
    /// Parse from a "key=value" CLI argument.
    ///
    /// # Errors
    /// Returns an error if the format is invalid.
    pub fn from_cli_arg(raw: &str) -> Result<Self, String> {
        let (key, value) = raw
            .split_once('=')
            .filter(|(k, _)| !k.is_empty())
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
    pub members: Vec<ClusterMember>,
    pub mode_args: Vec<String>,
    pub helm_settings: Vec<HelmSetting>,
    pub restart_namespaces: Vec<String>,
    pub repo_root: String,
}

impl ClusterSpec {
    /// Parse from a JSON value, handling both legacy and modern formats.
    ///
    /// # Errors
    /// Returns an error if the value cannot be parsed.
    pub fn from_object(value: &Value) -> Result<Self, String> {
        ClusterRecordPayload::from_value(value)?.to_spec()
    }

    /// Build from mode and arguments, auto-generating members.
    ///
    /// # Errors
    /// Returns an error if the mode/args combination is invalid.
    pub fn from_mode(
        mode: &str,
        mode_args: &[String],
        repo_root: &str,
        helm_settings: Vec<HelmSetting>,
        restart_namespaces: Vec<String>,
    ) -> Result<Self, String> {
        let mode: ClusterMode = mode.parse()?;
        let members = members_for_mode(mode, mode_args)?;
        let mut sorted_helm = helm_settings;
        sorted_helm.sort_by(|a, b| a.key.cmp(&b.key));
        Ok(Self {
            mode,
            members,
            mode_args: mode_args.to_vec(),
            helm_settings: sorted_helm,
            restart_namespaces: dedup_preserving_order(restart_namespaces),
            repo_root: repo_root.into(),
        })
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
    pub fn primary_kubeconfig(&self) -> &str {
        &self.primary_member().kubeconfig
    }

    #[must_use]
    pub fn cluster_names(&self) -> Vec<&str> {
        self.members.iter().map(|m| m.name.as_str()).collect()
    }

    #[must_use]
    pub fn kubeconfigs(&self) -> HashMap<&str, &str> {
        self.members
            .iter()
            .map(|m| (m.name.as_str(), m.kubeconfig.as_str()))
            .collect()
    }

    #[must_use]
    pub fn helm_values(&self) -> HashMap<&str, &str> {
        self.helm_settings
            .iter()
            .map(|s| (s.key.as_str(), s.value.as_str()))
            .collect()
    }

    #[must_use]
    pub fn to_json_dict(&self) -> Value {
        ClusterRecordPayload::from_spec(self).to_json_dict()
    }

    #[must_use]
    pub fn to_current_deploy_dict(&self, updated_at: &str) -> Value {
        CurrentDeployPayload::from_spec(self, updated_at).to_json_dict()
    }

    #[must_use]
    pub fn matches_deploy_dict(&self, payload: &Value) -> bool {
        CurrentDeployPayload::from_value(payload).is_ok_and(|d| d.matches(self))
    }
}

/// Cluster record payload for serialization (handles legacy compat).
#[derive(Debug, Clone, Serialize)]
pub struct ClusterRecordPayload {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<ClusterMode>,
    pub mode_args: Vec<String>,
    pub members: Vec<ClusterMember>,
    pub clusters: Vec<String>,
    pub kubeconfigs: HashMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub primary_kubeconfig: Option<String>,
    pub helm_values: HashMap<String, String>,
    pub helm_settings: Vec<HelmSetting>,
    pub restart_namespaces: Vec<String>,
    pub repo_root: String,
}

impl ClusterRecordPayload {
    /// Parse from a JSON value.
    ///
    /// # Errors
    /// Returns an error if the value is not an object.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("expected object")?;
        let mode = obj
            .get("mode")
            .and_then(Value::as_str)
            .map(str::parse)
            .transpose()?;
        let mode_args = parse_string_vec(obj.get("mode_args"));
        let members: Vec<ClusterMember> = obj
            .get("members")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| ClusterMember::from_value(v).ok())
                    .collect()
            })
            .unwrap_or_default();
        let clusters = parse_string_vec(obj.get("clusters"));
        let kubeconfigs: HashMap<String, String> = obj
            .get("kubeconfigs")
            .and_then(Value::as_object)
            .map(|m| {
                m.iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.into())))
                    .collect()
            })
            .unwrap_or_default();
        let primary_kubeconfig = obj
            .get("primary_kubeconfig")
            .and_then(Value::as_str)
            .map(String::from);
        let helm_settings = parse_helm_settings(obj);
        let helm_values = helm_settings
            .iter()
            .map(|s| (s.key.clone(), s.value.clone()))
            .collect();
        let restart_namespaces = parse_string_vec(obj.get("restart_namespaces"));
        let repo_root = obj
            .get("repo_root")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        Ok(Self {
            mode,
            mode_args,
            members,
            clusters,
            kubeconfigs,
            primary_kubeconfig,
            helm_values,
            helm_settings,
            restart_namespaces,
            repo_root,
        })
    }

    #[must_use]
    pub fn from_spec(spec: &ClusterSpec) -> Self {
        let members = spec.members.clone();
        let clusters = members.iter().map(|m| m.name.clone()).collect();
        let kubeconfigs = members
            .iter()
            .map(|m| (m.name.clone(), m.kubeconfig.clone()))
            .collect();
        let helm_values = spec
            .helm_settings
            .iter()
            .map(|s| (s.key.clone(), s.value.clone()))
            .collect();
        Self {
            mode: Some(spec.mode),
            mode_args: spec.mode_args.clone(),
            members,
            clusters,
            kubeconfigs,
            primary_kubeconfig: Some(spec.primary_kubeconfig().to_string()),
            helm_values,
            helm_settings: spec.helm_settings.clone(),
            restart_namespaces: spec.restart_namespaces.clone(),
            repo_root: spec.repo_root.clone(),
        }
    }

    fn legacy_members(&self) -> Vec<ClusterMember> {
        let Some(mode) = &self.mode else {
            return Vec::new();
        };
        self.clusters
            .iter()
            .enumerate()
            .map(|(i, cluster)| {
                let role = if i == 0 && mode.is_global() {
                    "global"
                } else if mode.is_global() {
                    "zone"
                } else {
                    "primary"
                };
                let kc = self
                    .kubeconfigs
                    .get(cluster)
                    .cloned()
                    .unwrap_or_else(|| kubeconfig_for_cluster(cluster));
                ClusterMember::named(cluster, role, Some(&kc), None)
            })
            .collect()
    }

    /// Convert to a `ClusterSpec`.
    ///
    /// # Errors
    /// Returns an error if the record is invalid.
    pub fn to_spec(&self) -> Result<ClusterSpec, String> {
        match &self.mode {
            None => {
                let kc = self
                    .primary_kubeconfig
                    .as_deref()
                    .ok_or("cluster mode must be a string")?;
                Ok(ClusterSpec {
                    mode: ClusterMode::SingleUp,
                    mode_args: vec!["current".into()],
                    members: vec![ClusterMember::named("current", "primary", Some(kc), None)],
                    helm_settings: Vec::new(),
                    restart_namespaces: Vec::new(),
                    repo_root: self.repo_root.clone(),
                })
            }
            Some(mode) => {
                let members = if self.members.is_empty() {
                    self.legacy_members()
                } else {
                    self.members.clone()
                };
                if members.is_empty() {
                    return Err("cluster members must be non-empty".into());
                }
                Ok(ClusterSpec {
                    mode: *mode,
                    mode_args: self.mode_args.clone(),
                    members,
                    helm_settings: self.helm_settings.clone(),
                    restart_namespaces: self.restart_namespaces.clone(),
                    repo_root: self.repo_root.clone(),
                })
            }
        }
    }

    #[must_use]
    pub fn to_json_dict(&self) -> Value {
        serde_json::to_value(self).unwrap_or_else(|_| Value::Object(serde_json::Map::new()))
    }
}

/// Current deploy state, written to current-deploy.json.
#[derive(Debug, Clone, PartialEq)]
pub struct CurrentDeployPayload {
    pub mode: ClusterMode,
    pub updated_at: String,
    pub mode_args: Vec<String>,
    pub helm_settings: Vec<HelmSetting>,
    pub restart_namespaces: Vec<String>,
}

impl CurrentDeployPayload {
    #[must_use]
    pub fn from_spec(spec: &ClusterSpec, updated_at: &str) -> Self {
        Self {
            mode: spec.mode,
            updated_at: updated_at.into(),
            mode_args: spec.mode_args.clone(),
            helm_settings: spec.helm_settings.clone(),
            restart_namespaces: spec.restart_namespaces.clone(),
        }
    }

    /// Parse from a JSON value.
    ///
    /// # Errors
    /// Returns an error if the value is not a valid deploy payload.
    pub fn from_value(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("expected object")?;
        let mode: ClusterMode = obj
            .get("mode")
            .and_then(Value::as_str)
            .ok_or("missing mode")?
            .parse()?;
        let updated_at = obj
            .get("updated_at")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let mode_args = parse_string_vec(obj.get("mode_args"));
        let helm_settings = parse_helm_settings(obj);
        let restart_namespaces = parse_string_vec(obj.get("restart_namespaces"));
        Ok(Self {
            mode,
            updated_at,
            mode_args,
            helm_settings,
            restart_namespaces,
        })
    }

    #[must_use]
    pub fn matches(&self, spec: &ClusterSpec) -> bool {
        self.mode == spec.mode
            && self.mode_args == spec.mode_args
            && self.helm_settings == spec.helm_settings
    }

    #[must_use]
    pub fn to_json_dict(&self) -> Value {
        let mut map = serde_json::Map::new();
        map.insert("mode".into(), Value::String(self.mode.to_string()));
        map.insert("updated_at".into(), Value::String(self.updated_at.clone()));
        map.insert(
            "mode_args".into(),
            Value::Array(
                self.mode_args
                    .iter()
                    .map(|s| Value::String(s.clone()))
                    .collect(),
            ),
        );
        let hv: serde_json::Map<String, Value> = self
            .helm_settings
            .iter()
            .map(|s| (s.key.clone(), Value::String(s.value.clone())))
            .collect();
        map.insert("helm_values".into(), Value::Object(hv));
        map.insert(
            "restart_namespaces".into(),
            Value::Array(
                self.restart_namespaces
                    .iter()
                    .map(|s| Value::String(s.clone()))
                    .collect(),
            ),
        );
        Value::Object(map)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn loads_legacy_clusters_and_helm_values() {
        let spec = ClusterSpec::from_object(&json!({
            "mode": "global-zone-up",
            "mode_args": ["kuma-global", "kuma-zone", "zone-1"],
            "clusters": ["kuma-global", "kuma-zone"],
            "kubeconfigs": {"kuma-zone": "/tmp/kuma-zone-config"},
            "helm_values": {"controlPlane.mode": "global"},
            "restart_namespaces": ["kuma-system"],
            "repo_root": "/repo",
        }))
        .unwrap();

        assert_eq!(spec.cluster_names(), vec!["kuma-global", "kuma-zone"]);
        assert!(
            spec.primary_kubeconfig()
                .ends_with("kind-kuma-global-config")
        );
        assert_eq!(spec.kubeconfigs()["kuma-zone"], "/tmp/kuma-zone-config");
        assert_eq!(
            spec.helm_settings,
            vec![HelmSetting {
                key: "controlPlane.mode".into(),
                value: "global".into()
            }]
        );
        let record = ClusterRecordPayload::from_spec(&spec);
        assert_eq!(record.kubeconfigs["kuma-global"], spec.primary_kubeconfig());
        assert_eq!(record.kubeconfigs["kuma-zone"], "/tmp/kuma-zone-config");
    }

    #[test]
    fn legacy_primary_kubeconfig_fallback() {
        let spec = ClusterSpec::from_object(&json!({"primary_kubeconfig": "/tmp/current-config"}))
            .unwrap();
        assert_eq!(spec.mode, ClusterMode::SingleUp);
        assert_eq!(spec.mode_args, vec!["current"]);
        assert_eq!(spec.primary_kubeconfig(), "/tmp/current-config");
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
        let hv = payload["helm_values"].as_object().unwrap();
        assert_eq!(hv["cp.mode"].as_str().unwrap(), "standalone");
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
}
