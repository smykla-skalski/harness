use std::borrow::Cow;
use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::current_deploy;
use super::{ClusterMember, ClusterMode, HelmSetting, Platform};

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
        current_deploy::to_json_dict(self, updated_at)
    }

    #[must_use]
    pub fn matches_deploy_dict(&self, payload: &Value) -> bool {
        current_deploy::matches_deploy_dict(self, payload)
    }
}
