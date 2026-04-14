use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::repo::{
    REMOTE_IMAGE_BUILD_TARGET, REMOTE_IMAGE_MANIFEST_TARGET, REMOTE_IMAGE_PUSH_TARGET,
};
use crate::infra::blocks::{KubernetesRuntime, StdProcessExecutor, kubernetes_runtime_from_env};
use crate::infra::exec::run_command;
use crate::infra::io::write_text;
use crate::kernel::topology::{ClusterSpec, HelmSetting};
use crate::setup::cluster::{ClusterArgs, RemoteClusterTarget};
use crate::setup::services::cluster::make_target_live;
use crate::workspace::{
    RemoteKubernetesInstallMemberState, RemoteKubernetesInstallState, cleanup_remote_install_state,
    load_remote_install_state_for_spec, persist_remote_install_state,
    remote_install_state_path_for_spec, utc_now,
};

mod flows;
mod members;
#[cfg(test)]
mod tests;

use self::flows::{execute_remote_down, execute_remote_up};

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
