use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::repo::{
    REMOTE_IMAGE_BUILD_TARGET, REMOTE_IMAGE_MANIFEST_TARGET, REMOTE_IMAGE_PUSH_TARGET,
    helm_chart_path,
};
use crate::infra::blocks::{KubernetesRuntime, StdProcessExecutor, kubernetes_runtime_from_env};
use crate::infra::exec::{run_command, run_command_streaming};
use crate::infra::io::write_text;
use crate::kernel::topology::{ClusterMode, ClusterSpec, HelmSetting};
use crate::setup::cluster::{ClusterArgs, RemoteClusterTarget};
use crate::setup::gateway::gateway;
use crate::setup::services::cluster::make_target_live;
use crate::workspace::{
    RemoteKubernetesInstallMemberState, RemoteKubernetesInstallState, cleanup_remote_install_state,
    load_remote_install_state_for_spec, persist_remote_install_state,
    remote_install_state_path_for_spec, utc_now,
};

struct InstallMemberPlan<'a> {
    push_prefix: &'a str,
    push_tag: &'a str,
    helm_settings: &'a [HelmSetting],
    mode_settings: &'a [String],
}

pub(super) fn cluster_remote_k8s(
    args: &ClusterArgs,
    root: &Path,
    base_env: &HashMap<String, String>,
    mut spec: ClusterSpec,
    helm_settings: &[HelmSetting],
) -> Result<ClusterSpec, CliError> {
    let kubernetes = kubernetes_runtime_from_env(Arc::new(StdProcessExecutor))?;
    if args.no_load {
        return Err(
            CliErrorKind::usage_error("--no-load is not valid with --provider remote").into(),
        );
    }

    if spec.mode.is_up() {
        let mut state = build_install_state(args, &spec)?;
        materialize_generated_kubeconfigs(kubernetes.as_ref(), &state)?;
        apply_generated_kubeconfigs(&mut spec, &state);
        validate_cluster_reachability(kubernetes.as_ref(), &state)?;
        let push_prefix = args.push_prefix.as_deref().ok_or_else(|| {
            CliError::from(CliErrorKind::usage_error(
                "--push-prefix is required for --provider remote",
            ))
        })?;
        let push_tag = args.push_tag.as_deref().ok_or_else(|| {
            CliError::from(CliErrorKind::usage_error(
                "--push-tag is required for --provider remote",
            ))
        })?;
        let published_image_refs =
            publish_release_images(root, base_env, push_prefix, push_tag, args.no_build)?;
        for member in &mut state.members {
            member
                .published_image_refs
                .clone_from(&published_image_refs);
        }
        execute_remote_up(
            kubernetes.as_ref(),
            root,
            &spec,
            &mut state,
            push_prefix,
            push_tag,
            helm_settings,
        )?;
        persist_remote_install_state(&spec, &state)?;
        return Ok(spec);
    }

    let state = load_remote_install_state_for_spec(&spec)?.ok_or_else(|| {
        CliError::from(CliErrorKind::cluster_error(
            "remote cluster teardown requires saved install state from a prior remote setup",
        ))
    })?;
    apply_generated_kubeconfigs(&mut spec, &state);
    execute_remote_down(kubernetes.as_ref(), root, &spec, &state)?;
    cleanup_remote_install_state(&spec, &state)?;
    Ok(spec)
}

fn build_install_state(
    args: &ClusterArgs,
    spec: &ClusterSpec,
) -> Result<RemoteKubernetesInstallState, CliError> {
    let mapping = validate_remote_targets(spec, &args.remote)?;
    let state_dir = remote_install_state_path_for_spec(spec)
        .parent()
        .expect("remote install state path should have a parent")
        .to_path_buf();

    let members = spec
        .members
        .iter()
        .map(|member| {
            let target = mapping
                .get(member.name.as_str())
                .expect("validated mapping covers all members");
            let generated_kubeconfig = state_dir.join(format!("{}.yaml", member.name));
            RemoteKubernetesInstallMemberState {
                name: member.name.clone(),
                source_kubeconfig: target.kubeconfig.clone(),
                source_context: target.context.clone(),
                generated_kubeconfig: generated_kubeconfig.display().to_string(),
                namespace: args.namespace.clone(),
                release_name: args.release_name.clone(),
                namespace_created_by_harness: false,
                gateway_api_installed: false,
                published_image_refs: vec![],
            }
        })
        .collect();

    Ok(RemoteKubernetesInstallState {
        mode: spec.mode,
        repo_root: spec.repo_root.clone(),
        push_prefix: args.push_prefix.clone(),
        push_tag: args.push_tag.clone(),
        updated_at_utc: utc_now(),
        members,
    })
}

fn validate_remote_targets<'a>(
    spec: &ClusterSpec,
    targets: &'a [RemoteClusterTarget],
) -> Result<BTreeMap<&'a str, &'a RemoteClusterTarget>, CliError> {
    if targets.is_empty() {
        return Err(CliErrorKind::usage_error(
            "--provider remote requires at least one --remote mapping",
        )
        .into());
    }

    let expected = spec
        .members
        .iter()
        .map(|member| member.name.as_str())
        .collect::<HashSet<_>>();
    let mut seen = HashSet::new();
    let mut by_name = BTreeMap::new();

    for target in targets {
        if !seen.insert(target.name.as_str()) {
            return Err(CliErrorKind::usage_error(format!(
                "duplicate --remote mapping for cluster `{}`",
                target.name
            ))
            .into());
        }
        if !expected.contains(target.name.as_str()) {
            return Err(CliErrorKind::usage_error(format!(
                "unexpected --remote cluster `{}` for mode {}",
                target.name, spec.mode
            ))
            .into());
        }
        by_name.insert(target.name.as_str(), target);
    }

    if seen.len() != expected.len() {
        let missing = expected
            .difference(&seen)
            .copied()
            .collect::<Vec<_>>()
            .join(", ");
        return Err(CliErrorKind::usage_error(format!(
            "missing --remote mappings for cluster(s): {missing}"
        ))
        .into());
    }

    Ok(by_name)
}

fn materialize_generated_kubeconfigs(
    kubernetes: &dyn KubernetesRuntime,
    state: &RemoteKubernetesInstallState,
) -> Result<(), CliError> {
    for member in &state.members {
        materialize_generated_kubeconfig(kubernetes, member)?;
    }
    Ok(())
}

fn materialize_generated_kubeconfig(
    kubernetes: &dyn KubernetesRuntime,
    member: &RemoteKubernetesInstallMemberState,
) -> Result<(), CliError> {
    let flattened = kubernetes.flatten_kubeconfig(
        Path::new(&member.source_kubeconfig),
        member.source_context.as_deref(),
    )?;
    if flattened.trim().is_empty() {
        return Err(CliErrorKind::cluster_error(format!(
            "flattened kubeconfig for `{}` is empty",
            member.name
        ))
        .into());
    }
    write_text(Path::new(&member.generated_kubeconfig), &flattened)?;
    Ok(())
}

fn apply_generated_kubeconfigs(spec: &mut ClusterSpec, state: &RemoteKubernetesInstallState) {
    let generated = state
        .members
        .iter()
        .map(|member| (member.name.as_str(), member.generated_kubeconfig.as_str()))
        .collect::<BTreeMap<_, _>>();

    for member in &mut spec.members {
        if let Some(path) = generated.get(member.name.as_str()) {
            member.kubeconfig = (*path).to_string();
        }
    }
}

fn validate_cluster_reachability(
    kubernetes: &dyn KubernetesRuntime,
    state: &RemoteKubernetesInstallState,
) -> Result<(), CliError> {
    for member in &state.members {
        kubernetes.probe_cluster(Path::new(&member.generated_kubeconfig))?;
    }
    Ok(())
}

fn publish_release_images(
    root: &Path,
    base_env: &HashMap<String, String>,
    push_prefix: &str,
    push_tag: &str,
    skip_build: bool,
) -> Result<Vec<String>, CliError> {
    let mut env = base_env.clone();
    env.insert("DOCKER_REGISTRY".into(), push_prefix.to_string());
    env.insert("BUILD_INFO_VERSION".into(), push_tag.to_string());

    if !skip_build {
        make_target_live(root, REMOTE_IMAGE_BUILD_TARGET, &env)?;
    }
    make_target_live(root, REMOTE_IMAGE_PUSH_TARGET, &env)?;
    make_target_live(root, "docker/manifest", &env)?;

    let manifest = run_command(
        &["make", REMOTE_IMAGE_MANIFEST_TARGET],
        Some(root),
        Some(&env),
        &[0],
    )?;
    serde_json::from_str::<Vec<String>>(manifest.stdout.trim()).map_err(|error| {
        CliErrorKind::cluster_error(format!("remote image manifest json: {error}")).into()
    })
}

fn execute_remote_up(
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
            spec,
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
        spec,
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
        spec,
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
        spec,
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
            spec,
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

fn execute_remote_down(
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

fn state_member<'a>(
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

fn install_member(
    kubernetes: &dyn KubernetesRuntime,
    root: &Path,
    _spec: &ClusterSpec,
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
    settings.extend(plan.helm_settings.iter().map(HelmSetting::to_cli_arg));
    settings
}

fn uninstall_member(
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

fn resolve_remote_kds_address(
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::topology::{ClusterProvider, Platform};
    use fs_err as fs;

    #[test]
    fn remote_install_state_path_is_stable_across_sessions() {
        let tmp = tempfile::tempdir().unwrap();
        let xdg_data = tmp.path().join("xdg-data");
        let repo_root = tmp.path().join("repo");
        fs::create_dir_all(&repo_root).unwrap();

        let path_a = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(xdg_data.to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("session-a")),
            ],
            || {
                let spec = ClusterSpec::from_mode_with_platform_and_provider(
                    "single-up",
                    &[String::from("kuma-1")],
                    &repo_root.to_string_lossy(),
                    vec![],
                    vec![],
                    Platform::Kubernetes,
                    ClusterProvider::Remote,
                )
                .unwrap();
                remote_install_state_path_for_spec(&spec)
            },
        );

        let path_b = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(xdg_data.to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("session-b")),
            ],
            || {
                let spec = ClusterSpec::from_mode_with_platform_and_provider(
                    "single-up",
                    &[String::from("kuma-1")],
                    &repo_root.to_string_lossy(),
                    vec![],
                    vec![],
                    Platform::Kubernetes,
                    ClusterProvider::Remote,
                )
                .unwrap();
                remote_install_state_path_for_spec(&spec)
            },
        );

        assert_eq!(path_a, path_b);
        assert!(path_a.to_string_lossy().contains("/projects/project-"));
        assert!(path_a.to_string_lossy().contains("/remote-kubernetes/"));
        assert!(!path_a.to_string_lossy().contains("contexts/session-"));
    }
}
