use std::collections::HashMap;
use std::path::Path;
use std::thread;
use std::time::Duration;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::repo::helm_chart_path;
use crate::infra::blocks::KubernetesRuntime;
use crate::infra::exec::{run_command, run_command_streaming};
use crate::setup::gateway::gateway;
use crate::workspace::{RemoteKubernetesInstallMemberState, RemoteKubernetesInstallState};

use super::InstallMemberPlan;

pub(super) fn state_member<'a>(
    state: &'a RemoteKubernetesInstallState,
    name: &str,
) -> Result<&'a RemoteKubernetesInstallMemberState, CliError> {
    state
        .members
        .iter()
        .find(|member| member.name == name)
        .ok_or_else(|| {
            CliErrorKind::cluster_error(format!("missing remote install state for `{name}`")).into()
        })
}

fn state_member_mut<'a>(
    state: &'a mut RemoteKubernetesInstallState,
    name: &str,
) -> Result<&'a mut RemoteKubernetesInstallMemberState, CliError> {
    state
        .members
        .iter_mut()
        .find(|member| member.name == name)
        .ok_or_else(|| {
            CliErrorKind::cluster_error(format!("missing remote install state for `{name}`")).into()
        })
}

pub(super) fn install_member(
    kubernetes: &dyn KubernetesRuntime,
    root: &Path,
    state: &mut RemoteKubernetesInstallState,
    cluster_name: &str,
    plan: &InstallMemberPlan<'_>,
) -> Result<(), CliError> {
    let member = state_member_mut(state, cluster_name)?;
    prepare_member_namespace(kubernetes, member)?;
    let settings = install_member_settings(plan);
    install_member_release(root, kubernetes, member, &settings)
}

fn prepare_member_namespace(
    kubernetes: &dyn KubernetesRuntime,
    member: &mut RemoteKubernetesInstallMemberState,
) -> Result<(), CliError> {
    member.namespace_created_by_harness = member_requires_namespace_creation(kubernetes, member)?;
    Ok(())
}

fn member_requires_namespace_creation(
    kubernetes: &dyn KubernetesRuntime,
    member: &RemoteKubernetesInstallMemberState,
) -> Result<bool, CliError> {
    namespace_exists(
        kubernetes,
        Path::new(&member.generated_kubeconfig),
        &member.namespace,
    )
    .map(|exists| !exists)
}

fn install_member_release(
    root: &Path,
    kubernetes: &dyn KubernetesRuntime,
    member: &RemoteKubernetesInstallMemberState,
    settings: &[String],
) -> Result<(), CliError> {
    run_helm_upgrade(
        root,
        Path::new(&member.generated_kubeconfig),
        &member.namespace,
        &member.release_name,
        settings,
    )?;
    wait_for_control_plane(
        kubernetes,
        Path::new(&member.generated_kubeconfig),
        &member.namespace,
        &member.release_name,
    )
}

fn install_member_settings(plan: &InstallMemberPlan<'_>) -> Vec<String> {
    let mut settings = vec![
        format!("global.image.registry={}", plan.push_prefix),
        format!("controlPlane.image.tag={}", plan.push_tag),
        format!("cni.image.tag={}", plan.push_tag),
        format!("dataPlane.image.tag={}", plan.push_tag),
        format!("dataPlane.initImage.tag={}", plan.push_tag),
        format!("kumactl.image.tag={}", plan.push_tag),
    ];
    settings.extend(plan.mode_settings.iter().cloned());
    settings.extend(plan.helm_settings.iter().map(|setting| setting.to_cli_arg()));
    settings
}

pub(super) fn uninstall_member(
    kubernetes: &dyn KubernetesRuntime,
    root: &Path,
    member: &RemoteKubernetesInstallMemberState,
) -> Result<(), CliError> {
    run_helm_uninstall(
        Path::new(&member.generated_kubeconfig),
        &member.namespace,
        &member.release_name,
    )?;
    if member.gateway_api_installed {
        gateway(
            Some(member.generated_kubeconfig.as_str()),
            Some(root.to_string_lossy().as_ref()),
            false,
            true,
        )?;
    }
    if member.namespace_created_by_harness {
        kubernetes.delete_namespace(
            Path::new(&member.generated_kubeconfig),
            &member.namespace,
            false,
            true,
        )?;
    }
    Ok(())
}

fn namespace_exists(
    kubernetes: &dyn KubernetesRuntime,
    kubeconfig: &Path,
    namespace: &str,
) -> Result<bool, CliError> {
    kubernetes
        .namespace_exists(kubeconfig, namespace)
        .map_err(Into::into)
}

pub(super) fn resolve_remote_kds_address(
    kubernetes: &dyn KubernetesRuntime,
    global_member: &RemoteKubernetesInstallMemberState,
) -> Result<String, CliError> {
    let kubeconfig = Path::new(&global_member.generated_kubeconfig);
    let host = host_from_server(&kubernetes.cluster_server(kubeconfig)?)?;
    let service_name = format!("{}-global-zone-sync", global_member.release_name);
    let node_port = kubernetes
        .service_node_port(
            kubeconfig,
            global_member.namespace.as_str(),
            service_name.as_str(),
            "global-zone-sync",
        )?
        .map(|port| port.to_string())
        .unwrap_or_default();
    if node_port.is_empty() {
        return Err(CliErrorKind::cluster_error(format!(
            "could not resolve KDS NodePort for remote cluster `{}`",
            global_member.name
        ))
        .into());
    }
    Ok(format!("grpcs://{host}:{node_port}"))
}

fn host_from_server(server: &str) -> Result<String, CliError> {
    let without_scheme = server.split_once("://").map_or(server, |(_, value)| value);
    let authority = without_scheme.split('/').next().unwrap_or(without_scheme);
    if authority.is_empty() {
        return Err(CliErrorKind::cluster_error("kubeconfig server URL is empty").into());
    }
    if authority.starts_with('[') {
        let end = authority.find(']').ok_or_else(|| {
            CliError::from(CliErrorKind::cluster_error(format!(
                "invalid IPv6 kubeconfig server URL: {server}"
            )))
        })?;
        return Ok(authority[..=end].to_string());
    }
    Ok(authority.split(':').next().unwrap_or(authority).to_string())
}

fn run_helm_upgrade(
    root: &Path,
    kubeconfig: &Path,
    namespace: &str,
    release_name: &str,
    settings: &[String],
) -> Result<(), CliError> {
    let kubeconfig_owned = kubeconfig.to_string_lossy().into_owned();
    let chart_path = helm_chart_path(root);
    let chart_owned = chart_path.to_string_lossy().into_owned();
    let mut args = vec![
        "helm".to_string(),
        "upgrade".to_string(),
        release_name.to_string(),
        chart_owned,
        "--install".to_string(),
        "--create-namespace".to_string(),
        "--namespace".to_string(),
        namespace.to_string(),
        "--kubeconfig".to_string(),
        kubeconfig_owned,
    ];
    for setting in settings {
        args.push("--set".to_string());
        args.push(setting.clone());
    }
    run_owned_command_streaming(&args, Some(root), None, &[0])?;
    Ok(())
}

fn run_helm_uninstall(
    kubeconfig: &Path,
    namespace: &str,
    release_name: &str,
) -> Result<(), CliError> {
    let kubeconfig_owned = kubeconfig.to_string_lossy().into_owned();
    let args = vec![
        "helm".to_string(),
        "uninstall".to_string(),
        release_name.to_string(),
        "--namespace".to_string(),
        namespace.to_string(),
        "--kubeconfig".to_string(),
        kubeconfig_owned,
        "--ignore-not-found".to_string(),
    ];
    run_owned_command(&args, None, None, &[0])?;
    Ok(())
}

fn wait_for_control_plane(
    kubernetes: &dyn KubernetesRuntime,
    kubeconfig: &Path,
    namespace: &str,
    release_name: &str,
) -> Result<(), CliError> {
    let app_label = format!("app={release_name}-control-plane");
    kubernetes.wait_for_deployments_available(
        kubeconfig,
        namespace,
        app_label.as_str(),
        Duration::from_mins(1),
    )?;
    kubernetes.wait_for_pods_ready(
        kubeconfig,
        namespace,
        app_label.as_str(),
        Duration::from_mins(1),
    )?;

    for _ in 0..60 {
        if kubernetes.resource_exists(kubeconfig, None, "kuma.io/v1alpha1", "Mesh", "default")? {
            return Ok(());
        }
        thread::sleep(Duration::from_secs(1));
    }

    Err(CliErrorKind::cluster_error("default mesh was not created in time").into())
}

fn run_owned_command(
    args: &[String],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
    ok_exit_codes: &[i32],
) -> Result<(), CliError> {
    let borrowed = args.iter().map(String::as_str).collect::<Vec<_>>();
    run_command(&borrowed, cwd, env, ok_exit_codes)?;
    Ok(())
}

fn run_owned_command_streaming(
    args: &[String],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
    ok_exit_codes: &[i32],
) -> Result<(), CliError> {
    let borrowed = args.iter().map(String::as_str).collect::<Vec<_>>();
    run_command_streaming(&borrowed, cwd, env, ok_exit_codes)?;
    Ok(())
}
