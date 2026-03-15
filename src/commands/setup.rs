use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

use crate::bootstrap;
use crate::cluster::{ClusterSpec, HelmSetting};
use crate::compact;
use crate::compact::{build_compact_handoff, save_compact_handoff};
use crate::context::CurrentRunRecord;
use crate::core_defs::{current_run_context_path, resolve_build_info, utc_now};
use crate::ephemeral_metallb;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec::{cluster_exists, kubectl, run_command};
use crate::io::ensure_dir;
use crate::session_hook::SessionStartHookOutput;

// =========================================================================
// bootstrap
// =========================================================================

/// Install or refresh the repo-aware harness wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn bootstrap(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = super::resolve_project_dir(project_dir);
    let path_env = env::var("PATH").unwrap_or_default();
    bootstrap::main(&dir, &path_env)
}

// =========================================================================
// cluster
// =========================================================================

fn make_target(root: &Path, target: &str, env: &HashMap<String, String>) -> Result<(), CliError> {
    run_command(&["make", target], Some(root), Some(env), &[0])?;
    Ok(())
}

/// Manage disposable local k3d clusters.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn cluster(
    mode: &str,
    cluster_name: &str,
    extra_cluster_names: &[String],
    repo_root: Option<&str>,
    _run_dir: Option<&str>,
    helm_setting: &[String],
    restart_namespace: &[String],
) -> Result<i32, CliError> {
    let mut all_names = vec![cluster_name.to_string()];
    all_names.extend(extra_cluster_names.iter().cloned());

    let root = super::resolve_repo_root(repo_root);
    let build_info = resolve_build_info(&root)?;
    let mut base_env = build_info.env();

    let helm_settings: Vec<HelmSetting> = helm_setting
        .iter()
        .filter_map(|s| HelmSetting::from_cli_arg(s).ok())
        .collect();

    let spec = ClusterSpec::from_mode(
        mode,
        &all_names,
        &root.to_string_lossy(),
        helm_settings.clone(),
        restart_namespace.to_vec(),
    )
    .map_err(|e| CliError::from(CliErrorKind::cluster_error(e)))?;
    let validated_args = &spec.mode_args;

    if !helm_settings.is_empty() {
        let settings_str: Vec<String> = helm_settings.iter().map(HelmSetting::to_cli_arg).collect();
        base_env.insert(
            "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
            settings_str.join(" "),
        );
    }

    eprintln!(
        "{} cluster: starting {mode} for {}",
        utc_now(),
        validated_args.join(" ")
    );

    match mode {
        "single-up" => single_up(&root, &base_env, validated_args)?,
        "single-down" => single_down(&root, &base_env, validated_args)?,
        "global-zone-up" => global_zone_up(&root, &base_env, validated_args)?,
        "global-zone-down" => global_zone_down(&root, &base_env, validated_args)?,
        "global-two-zones-up" => global_two_zones_up(&root, &base_env, validated_args)?,
        "global-two-zones-down" => global_two_zones_down(&root, &base_env, validated_args)?,
        _ => {
            return Err(
                CliErrorKind::cluster_error(cow!("unsupported cluster mode: {mode}")).into(),
            );
        }
    }

    println!("{mode} completed");
    Ok(0)
}

fn start_and_deploy(
    root: &Path,
    base_env: &HashMap<String, String>,
    cluster_name: &str,
    kuma_mode: &str,
    extra_settings: &[String],
) -> Result<(), CliError> {
    let mut env = base_env.clone();
    env.insert("KIND_CLUSTER_NAME".to_string(), cluster_name.to_string());
    if !cluster_exists(cluster_name)? {
        eprintln!("{} cluster: starting k3d cluster {cluster_name}", utc_now());
        make_target(root, "k3d/start", &env)?;
    }
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let kubeconfig = format!("{home}/.kube/kind-{cluster_name}-config");
    env.insert("KUBECONFIG".to_string(), kubeconfig);
    env.insert("K3D_HELM_DEPLOY_NO_CNI".to_string(), "true".to_string());
    env.insert("KUMA_MODE".to_string(), kuma_mode.to_string());
    if !extra_settings.is_empty() {
        let existing = env
            .get("K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS")
            .cloned()
            .unwrap_or_default();
        let mut all: Vec<String> = if existing.is_empty() {
            vec![]
        } else {
            existing.split_whitespace().map(String::from).collect()
        };
        all.extend(extra_settings.iter().cloned());
        env.insert(
            "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
            all.join(" "),
        );
    }
    eprintln!(
        "{} cluster: deploying Kuma to {cluster_name} ({kuma_mode})",
        utc_now()
    );
    make_target(root, "k3d/deploy/helm", &env)?;
    Ok(())
}

fn cluster_stop(
    root: &Path,
    base_env: &HashMap<String, String>,
    cluster_name: &str,
) -> Result<(), CliError> {
    if !cluster_exists(cluster_name)? {
        println!("cluster {cluster_name} is already absent");
        return Ok(());
    }
    let mut env = base_env.clone();
    env.insert("KIND_CLUSTER_NAME".to_string(), cluster_name.to_string());
    make_target(root, "k3d/stop", &env)?;
    Ok(())
}

fn single_up(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    start_and_deploy(root, base_env, &names[0], "zone", &[])
}

fn single_down(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    cluster_stop(root, base_env, &names[0])
}

fn global_zone_up(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    let global_settings: Vec<String> = vec![
        "controlPlane.mode=global".into(),
        "controlPlane.globalZoneSyncService.type=NodePort".into(),
    ];
    start_and_deploy(root, base_env, &names[0], "global", &global_settings)?;
    let zone_settings = vec![
        "controlPlane.mode=zone".into(),
        format!("controlPlane.zone={}", names[2]),
        "controlPlane.tls.kdsZoneClient.skipVerify=true".into(),
    ];
    start_and_deploy(root, base_env, &names[1], "zone", &zone_settings)
}

fn global_zone_down(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    cluster_stop(root, base_env, &names[1])?;
    cluster_stop(root, base_env, &names[0])
}

fn global_two_zones_up(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    let global_settings: Vec<String> = vec![
        "controlPlane.mode=global".into(),
        "controlPlane.globalZoneSyncService.type=NodePort".into(),
    ];
    start_and_deploy(root, base_env, &names[0], "global", &global_settings)?;
    for (zone_cluster, zone_name) in [(&names[1], &names[3]), (&names[2], &names[4])] {
        let zone_settings = vec![
            "controlPlane.mode=zone".into(),
            format!("controlPlane.zone={zone_name}"),
            "controlPlane.tls.kdsZoneClient.skipVerify=true".into(),
        ];
        start_and_deploy(root, base_env, zone_cluster, "zone", &zone_settings)?;
    }
    Ok(())
}

fn global_two_zones_down(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    cluster_stop(root, base_env, &names[2])?;
    cluster_stop(root, base_env, &names[1])?;
    cluster_stop(root, base_env, &names[0])
}

// =========================================================================
// gateway
// =========================================================================

const GATEWAY_CLASS_CRD: &str = "gatewayclasses.gateway.networking.k8s.io";

static GATEWAY_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"sigs\.k8s\.io/gateway-api\s+v([^\s]+)").unwrap());

fn detect_gateway_version(root: &Path) -> Result<String, CliError> {
    let go_mod = root.join("go.mod");
    let text = fs::read_to_string(&go_mod)
        .map_err(|_| CliError::from(CliErrorKind::missing_file(go_mod.display().to_string())))?;
    // The capture group excludes the leading `v`, so cap[1] is e.g. "0.8.0".
    let cap = GATEWAY_RE
        .captures(&text)
        .ok_or(CliErrorKind::GatewayVersionMissing)?;
    Ok(format!("v{}", &cap[1]))
}

fn gateway_install_url(version: &str) -> String {
    format!(
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/{version}/standard-install.yaml"
    )
}

/// Check or install Gateway API CRDs.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn gateway(
    kubeconfig: Option<&str>,
    repo_root: Option<&str>,
    check_only: bool,
) -> Result<i32, CliError> {
    let root = super::resolve_repo_root(repo_root);
    let version = detect_gateway_version(&root)?;
    // `Path::new` borrows from the caller's `&str` - no heap allocation needed.
    let kc = kubeconfig.map(Path::new);

    if check_only {
        let result = kubectl(kc, &["get", "crd", GATEWAY_CLASS_CRD], &[0, 1])?;
        if result.returncode != 0 {
            return Err(CliErrorKind::GatewayCrdsMissing.into());
        }
        println!("Gateway API CRDs are installed");
        return Ok(0);
    }

    let tmp_dir = env::temp_dir().join("harness-gateway");
    ensure_dir(&tmp_dir).map_err(|e| {
        CliErrorKind::io(cow!("could not create temp dir {}: {e}", tmp_dir.display()))
    })?;

    let temp_manifest = tmp_dir.join(format!("gateway-api-{version}.yaml"));
    let temp_str = temp_manifest.to_string_lossy().into_owned();
    let url = gateway_install_url(&version);

    run_command(&["curl", "-sL", "-o", &temp_str, &url], None, None, &[0])?;

    // Distinguish "file missing after download" from "download produced an empty file".
    let file_len = fs::metadata(&temp_manifest)
        .map_err(|_| CliError::from(CliErrorKind::missing_file(temp_str.clone())))?
        .len();
    if file_len == 0 {
        return Err(CliErrorKind::gateway_download_empty(temp_str).into());
    }

    kubectl(kc, &["apply", "-f", &temp_str], &[0])?;
    println!("Gateway API {version} CRDs installed");
    Ok(0)
}

// =========================================================================
// session_start
// =========================================================================

/// Handle session start hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn session_start(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = super::resolve_project_dir(project_dir);

    // Bootstrap the project wrapper
    let path_env = env::var("PATH").unwrap_or_default();
    if let Err(e) = bootstrap::main(&dir, &path_env) {
        eprintln!("warning: bootstrap failed: {e}");
    }

    // Check for a pending compact handoff to restore
    let handoff = compact::pending_compact_handoff(&dir);
    if let Some(h) = handoff {
        let diverged = compact::verify_fingerprints(&h);
        let context = compact::render_hydration_context(&h, &diverged);
        if let Err(e) = compact::consume_compact_handoff(&dir, h) {
            eprintln!("warning: compact handoff consume failed: {e}");
        }
        let output = SessionStartHookOutput::from_additional_context(&context);
        if let Ok(json) = output.to_json() {
            print!("{json}");
        }
        return Ok(0);
    }

    Ok(0)
}

// =========================================================================
// session_stop
// =========================================================================

/// Handle session stop cleanup.
///
/// Reads the current run pointer, cleans up ephemeral `MetalLB` templates
/// for that run, and removes the pointer file. All steps degrade
/// gracefully - a missing or stale pointer is not an error.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn session_stop(_project_dir: Option<&str>) -> Result<i32, CliError> {
    let ctx_path = current_run_context_path();
    let Ok(text) = fs::read_to_string(&ctx_path) else {
        return Ok(0);
    };
    let Ok(record) = serde_json::from_str::<CurrentRunRecord>(&text) else {
        let _ = fs::remove_file(&ctx_path);
        return Ok(0);
    };

    let run_dir = record.layout.run_dir();
    if run_dir.is_dir() {
        let _ = ephemeral_metallb::cleanup_templates(&run_dir);
    }

    let _ = fs::remove_file(&ctx_path);
    Ok(0)
}

// =========================================================================
// pre_compact
// =========================================================================

/// Save compact handoff before compaction.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn pre_compact(project_dir: Option<&str>) -> Result<i32, CliError> {
    let dir = super::resolve_project_dir(project_dir);
    let handoff = build_compact_handoff(&dir)?;
    save_compact_handoff(&dir, &handoff)?;
    Ok(0)
}

// =========================================================================
// Tests
// =========================================================================

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;

    use super::*;

    fn write_go_mod(dir: &TempDir, content: &str) {
        fs::write(dir.path().join("go.mod"), content).unwrap();
    }

    #[test]
    fn detect_version_parses_standard_entry() {
        let dir = TempDir::new().unwrap();
        write_go_mod(
            &dir,
            "module example.com/foo\n\nrequire (\n\tsigs.k8s.io/gateway-api v1.2.1\n)\n",
        );
        assert_eq!(detect_gateway_version(dir.path()).unwrap(), "v1.2.1");
    }

    #[test]
    fn detect_version_strips_no_extra_v_prefix() {
        // Ensure we don't produce "vv1.2.1" - the regex captures after the `v`.
        let dir = TempDir::new().unwrap();
        write_go_mod(&dir, "require sigs.k8s.io/gateway-api v0.8.0 // indirect\n");
        let version = detect_gateway_version(dir.path()).unwrap();
        assert_eq!(version, "v0.8.0");
        assert!(!version.starts_with("vv"));
    }

    #[test]
    fn detect_version_errors_on_missing_go_mod() {
        let dir = TempDir::new().unwrap();
        let err = detect_gateway_version(dir.path()).unwrap_err();
        assert_eq!(err.code(), "KSRCLI014"); // MissingFile
    }

    #[test]
    fn detect_version_errors_when_pattern_absent() {
        let dir = TempDir::new().unwrap();
        write_go_mod(
            &dir,
            "module example.com/foo\n\nrequire (\n\tsome.other/dep v1.0.0\n)\n",
        );
        let err = detect_gateway_version(dir.path()).unwrap_err();
        assert_eq!(err.code(), "KSRCLI032"); // GatewayVersionMissing
    }

    #[test]
    fn install_url_contains_version_and_standard_path() {
        let url = gateway_install_url("v1.2.1");
        assert_eq!(
            url,
            "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
        );
    }

    #[test]
    fn install_url_embeds_arbitrary_version() {
        let url = gateway_install_url("v0.99.0-rc.1");
        assert!(url.contains("v0.99.0-rc.1"));
        assert!(url.ends_with("/standard-install.yaml"));
    }
}
