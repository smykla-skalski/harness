use std::collections::HashMap;
use std::path::Path;

use crate::app::command_context::resolve_repo_root;
use crate::errors::{CliError, CliErrorKind};
use crate::kernel::topology::{ClusterProvider, ClusterSpec, HelmSetting, Platform};
use crate::setup::build_info::resolve_build_info;
use crate::setup::cluster::ClusterArgs;
use crate::setup::services::cluster::persist_cluster_spec;

use super::modes::{dispatch_k8s_mode, restart_cluster_namespaces};
use super::remote::cluster_remote_k8s;

pub(crate) fn cluster_k8s(args: &ClusterArgs) -> Result<i32, CliError> {
    let mode = &args.mode;
    let all_names = cluster_names(args);
    let root = resolve_repo_root(args.repo_root.as_deref());
    let build_info = resolve_build_info(&root)?;
    let mut base_env = build_info.env();
    let provider = parse_kubernetes_provider(args)?;
    apply_build_flags(args, &mut base_env);
    let helm_settings = parse_helm_settings(&args.helm_setting)?;
    ensure_kubernetes_provider_is_valid(provider, args)?;
    apply_k3d_helm_settings(provider, &helm_settings, &mut base_env);
    let spec = build_kubernetes_spec(args, mode, &all_names, &root, provider, &helm_settings)?;
    let spec = execute_kubernetes_provider(provider, args, &root, &base_env, spec, &helm_settings)?;
    restart_kubernetes_namespaces_if_needed(&spec)?;
    persist_kubernetes_spec_if_needed(&spec)?;

    println!("{mode} completed");
    Ok(0)
}

fn cluster_names(args: &ClusterArgs) -> Vec<String> {
    let mut all_names = vec![args.cluster_name.clone()];
    all_names.extend(args.extra_cluster_names.iter().cloned());
    all_names
}

fn parse_kubernetes_provider(args: &ClusterArgs) -> Result<ClusterProvider, CliError> {
    args.provider
        .as_deref()
        .unwrap_or("k3d")
        .parse()
        .map_err(|error: String| CliError::from(CliErrorKind::usage_error(error)))
}

fn apply_build_flags(args: &ClusterArgs, base_env: &mut HashMap<String, String>) {
    if args.no_build {
        base_env.insert("HARNESS_BUILD_IMAGES".into(), "0".into());
    }
    if args.no_load {
        base_env.insert("HARNESS_LOAD_IMAGES".into(), "0".into());
    }
}

fn parse_helm_settings(values: &[String]) -> Result<Vec<HelmSetting>, CliError> {
    let mut bad_settings = Vec::new();
    let helm_settings = values
        .iter()
        .filter_map(|value| match HelmSetting::from_cli_arg(value) {
            Ok(setting) => Some(setting),
            Err(error) => {
                bad_settings.push(error);
                None
            }
        })
        .collect::<Vec<_>>();
    if bad_settings.is_empty() {
        return Ok(helm_settings);
    }
    Err(CliErrorKind::usage_error(bad_settings.join("; ")).into())
}

fn build_kubernetes_spec(
    args: &ClusterArgs,
    mode: &str,
    all_names: &[String],
    root: &Path,
    provider: ClusterProvider,
    helm_settings: &[HelmSetting],
) -> Result<ClusterSpec, CliError> {
    ClusterSpec::from_mode_with_platform_and_provider(
        mode,
        all_names,
        &root.to_string_lossy(),
        helm_settings.to_vec(),
        args.restart_namespace.clone(),
        Platform::Kubernetes,
        provider,
    )
    .map_err(|error| CliError::from(CliErrorKind::cluster_error(error)))
}

fn ensure_kubernetes_provider_is_valid(
    provider: ClusterProvider,
    args: &ClusterArgs,
) -> Result<(), CliError> {
    if provider == ClusterProvider::Remote && args.platform == "universal" {
        return Err(CliError::from(CliErrorKind::usage_error(
            "--provider is only valid for kubernetes",
        )));
    }
    Ok(())
}

fn apply_k3d_helm_settings(
    provider: ClusterProvider,
    helm_settings: &[HelmSetting],
    base_env: &mut HashMap<String, String>,
) {
    if provider != ClusterProvider::K3d || helm_settings.is_empty() {
        return;
    }
    let settings_str: Vec<String> = helm_settings.iter().map(HelmSetting::to_cli_arg).collect();
    base_env.insert(
        "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
        settings_str.join(" "),
    );
}

fn execute_kubernetes_provider(
    provider: ClusterProvider,
    args: &ClusterArgs,
    root: &Path,
    base_env: &HashMap<String, String>,
    spec: ClusterSpec,
    helm_settings: &[HelmSetting],
) -> Result<ClusterSpec, CliError> {
    match provider {
        ClusterProvider::K3d => {
            dispatch_k8s_mode(spec.mode, root, base_env, &spec.mode_args)?;
            Ok(spec)
        }
        ClusterProvider::Remote => cluster_remote_k8s(args, root, base_env, spec, helm_settings),
        ClusterProvider::Compose => Err(CliError::from(CliErrorKind::usage_error(
            "compose provider is not valid for kubernetes",
        ))),
    }
}

fn restart_kubernetes_namespaces_if_needed(spec: &ClusterSpec) -> Result<(), CliError> {
    if spec.mode.is_up() && !spec.restart_namespaces.is_empty() {
        restart_cluster_namespaces(spec)?;
    }
    Ok(())
}

fn persist_kubernetes_spec_if_needed(spec: &ClusterSpec) -> Result<(), CliError> {
    if spec.mode.is_up() {
        persist_cluster_spec(spec)?;
    }
    Ok(())
}
