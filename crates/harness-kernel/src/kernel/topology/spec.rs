use std::borrow::Cow;
use std::collections::HashMap;

use serde::de::Deserializer;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::current_deploy;
use super::{
    ClusterMember, ClusterMode, ClusterProvider, HelmSetting, Platform, UNIVERSAL_PUBLISHED_HOST,
};

/// Full cluster specification describing a deployment topology.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ClusterSpec {
    pub mode: ClusterMode,
    #[serde(default)]
    pub platform: Platform,
    #[serde(default)]
    pub provider: ClusterProvider,
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

#[derive(Debug, Clone, PartialEq, Deserialize)]
struct ClusterSpecSerde {
    pub mode: ClusterMode,
    #[serde(default)]
    pub platform: Platform,
    #[serde(default)]
    pub provider: Option<ClusterProvider>,
    pub members: Vec<ClusterMember>,
    #[serde(default)]
    pub mode_args: Vec<String>,
    #[serde(default)]
    pub helm_settings: Vec<HelmSetting>,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
    #[serde(default)]
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

impl<'de> Deserialize<'de> for ClusterSpec {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = ClusterSpecSerde::deserialize(deserializer)?;
        Ok(Self {
            mode: raw.mode,
            platform: raw.platform,
            provider: raw
                .provider
                .unwrap_or_else(|| ClusterProvider::default_for_platform(raw.platform)),
            members: raw.members,
            mode_args: raw.mode_args,
            helm_settings: raw.helm_settings,
            restart_namespaces: raw.restart_namespaces,
            repo_root: raw.repo_root,
            docker_network: raw.docker_network,
            store_type: raw.store_type,
            cp_image: raw.cp_image,
            admin_token: raw.admin_token,
        })
    }
}

impl ClusterSpec {
    #[must_use]
    pub fn primary_api_url(&self) -> Option<String> {
        if self.platform != Platform::Universal {
            return None;
        }
        let member = self.primary_member();
        member.container_ip.as_deref()?;
        Some(format!(
            "http://{UNIVERSAL_PUBLISHED_HOST}:{}",
            member.cp_api_port.unwrap_or(5681)
        ))
    }

    #[must_use]
    pub fn primary_api_parts(&self) -> Option<(&str, u16)> {
        if self.platform != Platform::Universal {
            return None;
        }
        let member = self.primary_member();
        member.container_ip.as_deref()?;
        Some((UNIVERSAL_PUBLISHED_HOST, member.cp_api_port.unwrap_or(5681)))
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
        self.provider == ClusterProvider::Compose
            && (!self.mode.is_single() || self.store_type.as_deref() == Some("postgres"))
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
