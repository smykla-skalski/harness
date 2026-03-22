use tracing::info;

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
    let mut all_names = vec![args.cluster_name.clone()];
    all_names.extend(args.extra_cluster_names.iter().cloned());

    let root = resolve_repo_root(args.repo_root.as_deref());
    let build_info = resolve_build_info(&root)?;
    let mut base_env = build_info.env();
    let provider: ClusterProvider = args
        .provider
        .as_deref()
        .unwrap_or("k3d")
        .parse()
        .map_err(|error: String| CliError::from(CliErrorKind::usage_error(error)))?;

    if args.no_build {
        base_env.insert("HARNESS_BUILD_IMAGES".into(), "0".into());
    }

    if args.no_load {
        base_env.insert("HARNESS_LOAD_IMAGES".into(), "0".into());
    }

    let mut bad_settings = Vec::new();
    let helm_settings: Vec<HelmSetting> = args
        .helm_setting
        .iter()
        .filter_map(|s| match HelmSetting::from_cli_arg(s) {
            Ok(h) => Some(h),
            Err(e) => {
                bad_settings.push(e);
                None
            }
        })
        .collect();

    if !bad_settings.is_empty() {
        return Err(CliErrorKind::usage_error(bad_settings.join("; ")).into());
    }

    let spec = ClusterSpec::from_mode_with_platform_and_provider(
        mode,
        &all_names,
        &root.to_string_lossy(),
        helm_settings.clone(),
        args.restart_namespace.clone(),
        Platform::Kubernetes,
        provider,
    )
    .map_err(|e| CliError::from(CliErrorKind::cluster_error(e)))?;

    let validated_args = &spec.mode_args;

    if provider == ClusterProvider::Remote && args.platform == "universal" {
        return Err(CliError::from(CliErrorKind::usage_error(
            "--provider is only valid for kubernetes",
        )));
    }

    if provider == ClusterProvider::K3d && !helm_settings.is_empty() {
        let settings_str: Vec<String> = helm_settings.iter().map(HelmSetting::to_cli_arg).collect();
        base_env.insert(
            "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
            settings_str.join(" "),
        );
    }

    info!(
        %mode,
        provider = %provider,
        names = %validated_args.join(" "),
        "starting cluster"
    );
    let spec = match provider {
        ClusterProvider::K3d => {
            dispatch_k8s_mode(spec.mode, &root, &base_env, validated_args)?;
            spec
        }
        ClusterProvider::Remote => {
            cluster_remote_k8s(args, &root, &base_env, spec, &helm_settings)?
        }
        ClusterProvider::Compose => {
            return Err(CliError::from(CliErrorKind::usage_error(
                "compose provider is not valid for kubernetes",
            )));
        }
    };

    if spec.mode.is_up() && !spec.restart_namespaces.is_empty() {
        restart_cluster_namespaces(&spec)?;
    }

    if spec.mode.is_up() {
        persist_cluster_spec(&spec)?;
    }

    println!("{mode} completed");
    Ok(0)
}
