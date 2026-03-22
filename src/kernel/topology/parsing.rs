use std::collections::HashSet;
use std::env;

use serde_json::Value;

use crate::workspace::HARNESS_PREFIX;

use super::{ClusterMember, ClusterMode, ClusterSpec, HelmSetting, Platform};

impl ClusterMember {
    pub(super) fn from_value(value: &Value) -> Result<Self, String> {
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
}

pub(super) fn kubeconfig_for_cluster(cluster: &str) -> String {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    format!("{home}/.kube/k3d-{cluster}.yaml")
}

pub(super) fn parse_string_vec(value: Option<&Value>) -> Vec<String> {
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

pub(super) fn parse_helm_settings(obj: &serde_json::Map<String, Value>) -> Vec<HelmSetting> {
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
