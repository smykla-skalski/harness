use serde::Serialize;
use serde_json::Value;

use super::spec::{ClusterSpec, HelmSetting};
use super::{parse_helm_settings, parse_string_vec, ClusterMember, ClusterMode, Platform};

/// Cluster record payload for serialization.
#[derive(Debug, Clone, Serialize)]
pub struct ClusterRecordPayload {
    pub mode: ClusterMode,
    #[serde(default)]
    pub platform: Platform,
    pub mode_args: Vec<String>,
    pub members: Vec<ClusterMember>,
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

impl ClusterRecordPayload {
    /// Parse from a JSON value.
    ///
    /// # Errors
    /// Returns an error if the value is not a valid cluster record.
    pub fn from_value(value: &Value) -> Result<Self, String> {
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
        let members: Vec<ClusterMember> = obj
            .get("members")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .map(ClusterMember::from_value)
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()?
            .unwrap_or_default();
        let helm_settings = parse_helm_settings(obj);
        let restart_namespaces = parse_string_vec(obj.get("restart_namespaces"));
        let repo_root = obj
            .get("repo_root")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let docker_network = obj
            .get("docker_network")
            .and_then(Value::as_str)
            .map(Into::into);
        let store_type = obj
            .get("store_type")
            .and_then(Value::as_str)
            .map(Into::into);
        let cp_image = obj.get("cp_image").and_then(Value::as_str).map(Into::into);
        let admin_token = obj
            .get("admin_token")
            .and_then(Value::as_str)
            .map(Into::into);
        Ok(Self {
            mode,
            platform,
            mode_args,
            members,
            helm_settings,
            restart_namespaces,
            repo_root,
            docker_network,
            store_type,
            cp_image,
            admin_token,
        })
    }

    #[must_use]
    pub fn from_spec(spec: &ClusterSpec) -> Self {
        Self {
            mode: spec.mode,
            platform: spec.platform,
            mode_args: spec.mode_args.clone(),
            members: spec.members.clone(),
            helm_settings: spec.helm_settings.clone(),
            restart_namespaces: spec.restart_namespaces.clone(),
            repo_root: spec.repo_root.clone(),
            docker_network: spec.docker_network.clone(),
            store_type: spec.store_type.clone(),
            cp_image: spec.cp_image.clone(),
            admin_token: spec.admin_token.clone(),
        }
    }

    /// Convert to a `ClusterSpec`.
    ///
    /// # Errors
    /// Returns an error if the record is invalid.
    pub fn to_spec(&self) -> Result<ClusterSpec, String> {
        if self.members.is_empty() {
            return Err("cluster members must be non-empty".into());
        }
        Ok(ClusterSpec {
            mode: self.mode,
            platform: self.platform,
            mode_args: self.mode_args.clone(),
            members: self.members.clone(),
            helm_settings: self.helm_settings.clone(),
            restart_namespaces: self.restart_namespaces.clone(),
            repo_root: self.repo_root.clone(),
            docker_network: self.docker_network.clone(),
            store_type: self.store_type.clone(),
            cp_image: self.cp_image.clone(),
            admin_token: self.admin_token.clone(),
        })
    }

    /// # Panics
    /// Panics if the derived `Serialize` impl produces invalid JSON (should never happen).
    #[must_use]
    pub fn to_json_dict(&self) -> Value {
        serde_json::to_value(self).expect("derived Serialize impl")
    }
}
