use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::KubernetesRuntime;
use crate::kernel::topology::{ClusterMode, ClusterSpec, HelmSetting};
use crate::workspace::RemoteKubernetesInstallState;

use super::InstallMemberPlan;
use super::members::{install_member, resolve_remote_kds_address, state_member, uninstall_member};

pub(super) fn execute_remote_up(
    kubernetes: &dyn KubernetesRuntime,
    root: &Path,
    spec: &ClusterSpec,
    state: &mut RemoteKubernetesInstallState,
    push_prefix: &str,
    push_tag: &str,
    helm_settings: &[HelmSetting],
) -> Result<(), CliError> {
    match spec.mode {
        ClusterMode::SingleUp => install_member(
            kubernetes,
            root,
            state,
            spec.primary_member().name.as_str(),
            &InstallMemberPlan {
                push_prefix,
                push_tag,
                helm_settings,
                mode_settings: &[],
            },
        ),
        ClusterMode::GlobalZoneUp => execute_remote_global_zone_up(
            kubernetes,
            root,
            spec,
            state,
            push_prefix,
            push_tag,
            helm_settings,
        ),
        ClusterMode::GlobalTwoZonesUp => execute_remote_global_two_zones_up(
            kubernetes,
            root,
            spec,
            state,
            push_prefix,
            push_tag,
            helm_settings,
        ),
        ClusterMode::SingleDown | ClusterMode::GlobalZoneDown | ClusterMode::GlobalTwoZonesDown => {
            Err(CliErrorKind::cluster_error("remote up flow called for down mode").into())
        }
    }
}

fn execute_remote_global_zone_up(
    kubernetes: &dyn KubernetesRuntime,
    root: &Path,
    spec: &ClusterSpec,
    state: &mut RemoteKubernetesInstallState,
    push_prefix: &str,
    push_tag: &str,
    helm_settings: &[HelmSetting],
) -> Result<(), CliError> {
    let global = spec.members[0].name.as_str();
    install_member(
        kubernetes,
        root,
        state,
        global,
        &InstallMemberPlan {
            push_prefix,
            push_tag,
            helm_settings,
            mode_settings: &[
                "controlPlane.mode=global".to_string(),
                "controlPlane.globalZoneSyncService.type=NodePort".to_string(),
            ],
        },
    )?;
    let global_state = state_member(state, global)?;
    let kds_address = resolve_remote_kds_address(kubernetes, global_state)?;
    let zone = spec.members[1].name.as_str();
    let zone_name = spec.members[1].zone_name.as_deref().unwrap_or(zone);
    install_member(
        kubernetes,
        root,
        state,
        zone,
        &InstallMemberPlan {
            push_prefix,
            push_tag,
            helm_settings,
            mode_settings: &[
                "controlPlane.mode=zone".to_string(),
                format!("controlPlane.zone={zone_name}"),
                format!("controlPlane.kdsGlobalAddress={kds_address}"),
                "controlPlane.tls.kdsZoneClient.skipVerify=true".to_string(),
            ],
        },
    )
}

fn execute_remote_global_two_zones_up(
    kubernetes: &dyn KubernetesRuntime,
    root: &Path,
    spec: &ClusterSpec,
    state: &mut RemoteKubernetesInstallState,
    push_prefix: &str,
    push_tag: &str,
    helm_settings: &[HelmSetting],
) -> Result<(), CliError> {
    let global = spec.members[0].name.as_str();
    install_member(
        kubernetes,
        root,
        state,
        global,
        &InstallMemberPlan {
            push_prefix,
            push_tag,
            helm_settings,
            mode_settings: &[
                "controlPlane.mode=global".to_string(),
                "controlPlane.globalZoneSyncService.type=NodePort".to_string(),
            ],
        },
    )?;
    let global_state = state_member(state, global)?;
    let kds_address = resolve_remote_kds_address(kubernetes, global_state)?;
    for zone_index in [1usize, 2usize] {
        let zone = spec.members[zone_index].name.as_str();
        let zone_name = spec.members[zone_index]
            .zone_name
            .as_deref()
            .unwrap_or(zone);
        install_member(
            kubernetes,
            root,
            state,
            zone,
            &InstallMemberPlan {
                push_prefix,
                push_tag,
                helm_settings,
                mode_settings: &[
                    "controlPlane.mode=zone".to_string(),
                    format!("controlPlane.zone={zone_name}"),
                    format!("controlPlane.kdsGlobalAddress={kds_address}"),
                    "controlPlane.tls.kdsZoneClient.skipVerify=true".to_string(),
                ],
            },
        )?;
    }
    Ok(())
}

pub(super) fn execute_remote_down(
    kubernetes: &dyn KubernetesRuntime,
    root: &Path,
    spec: &ClusterSpec,
    state: &RemoteKubernetesInstallState,
) -> Result<(), CliError> {
    match spec.mode {
        ClusterMode::SingleDown => uninstall_member(
            kubernetes,
            root,
            state_member(state, spec.primary_member().name.as_str())?,
        ),
        ClusterMode::GlobalZoneDown => {
            uninstall_member(
                kubernetes,
                root,
                state_member(state, spec.members[1].name.as_str())?,
            )?;
            uninstall_member(
                kubernetes,
                root,
                state_member(state, spec.members[0].name.as_str())?,
            )
        }
        ClusterMode::GlobalTwoZonesDown => {
            uninstall_member(
                kubernetes,
                root,
                state_member(state, spec.members[2].name.as_str())?,
            )?;
            uninstall_member(
                kubernetes,
                root,
                state_member(state, spec.members[1].name.as_str())?,
            )?;
            uninstall_member(
                kubernetes,
                root,
                state_member(state, spec.members[0].name.as_str())?,
            )
        }
        ClusterMode::SingleUp | ClusterMode::GlobalZoneUp | ClusterMode::GlobalTwoZonesUp => {
            Err(CliErrorKind::cluster_error("remote down flow called for up mode").into())
        }
    }
}
