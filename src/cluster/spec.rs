use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    dedup_preserving_order, members_for_mode, universal_members_for_mode, ClusterMode, Platform,
};
use crate::core_defs::HARNESS_PREFIX;

use super::deploy::CurrentDeployPayload;
use super::record::ClusterRecordPayload;

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
    #[serde(default)]
    pub platform: Platform,
    pub members: Vec<super::ClusterMember>,
    pub mode_args: Vec<String>,
    pub helm_settings: Vec<HelmSetting>,
    pub restart_namespaces: Vec<String>,
    pub repo_root: String,
    /// Docker network name (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub docker_network: Option<String>,
    /// Store backend type: "memory" or "postgres" (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub store_type: Option<String>,
    /// CP container image (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp_image: Option<String>,
    /// Admin user token extracted from CP (universal mode only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub admin_token: Option<String>,
}

impl ClusterSpec {
    /// Parse from a JSON value.
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
        Self::from_mode_with_platform(
            mode,
            mode_args,
            repo_root,
            helm_settings,
            restart_namespaces,
            Platform::Kubernetes,
        )
    }

    /// Build from mode, arguments, and platform, auto-generating members.
    ///
    /// # Errors
    /// Returns an error if the mode/args combination is invalid.
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
        let mut sorted_helm = helm_settings;
        sorted_helm.sort_by(|a, b| a.key.cmp(&b.key));
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
            helm_settings: sorted_helm,
            restart_namespaces: dedup_preserving_order(restart_namespaces),
            repo_root: repo_root.into(),
            docker_network,
            store_type: None,
            cp_image: None,
            admin_token: None,
        })
    }

    /// Returns the CP API URL for universal mode, `None` for Kubernetes.
    #[must_use]
    pub fn primary_api_url(&self) -> Option<String> {
        if self.platform != Platform::Universal {
            return None;
        }
        let member = self.primary_member();
        let ip = member.container_ip.as_deref()?;
        let port = member.cp_api_port.unwrap_or(5681);
        Some(format!("http://{ip}:{port}"))
    }

    /// Returns the admin token for universal mode, `None` for Kubernetes.
    #[must_use]
    pub fn admin_token(&self) -> Option<&str> {
        self.admin_token.as_deref()
    }

    #[must_use]
    pub fn primary_member(&self) -> &super::ClusterMember {
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

    /// Whether this topology requires Docker Compose (multi-zone or postgres store).
    #[must_use]
    pub fn is_compose_managed(&self) -> bool {
        self.members.len() > 1 || self.store_type.as_deref().is_some_and(|s| s == "postgres")
    }

    #[must_use]
    pub fn kubeconfigs(&self) -> HashMap<&str, &str> {
        self.members
            .iter()
            .map(|m| (m.name.as_str(), m.kubeconfig.as_str()))
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
