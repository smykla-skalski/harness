use std::env;
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

use clap::Args;
use regex::Regex;

use crate::app::command_context::{AppContext, Execute, resolve_repo_root};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::{kubectl, run_command};
use crate::infra::io::ensure_dir;
use crate::workspace::HARNESS_PREFIX;
use crate::workspace::sync_gateway_api_install_state;

impl Execute for GatewayArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        gateway(
            self.kubeconfig.as_deref(),
            self.repo_root.as_deref(),
            self.check_only,
            self.uninstall,
        )
    }
}

// =========================================================================
// gateway
// =========================================================================

const GATEWAY_CLASS_CRD: &str = "gatewayclasses.gateway.networking.k8s.io";

/// Arguments for `harness setup gateway`.
#[derive(Debug, Clone, Args)]
pub struct GatewayArgs {
    /// Use this kubeconfig for the target cluster.
    #[arg(long)]
    pub kubeconfig: Option<String>,
    /// Repo root to resolve the pinned Gateway API version.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Only check whether the Gateway API CRDs are already installed.
    #[arg(long)]
    pub check_only: bool,
    /// Uninstall the Gateway API CRDs previously installed by harness.
    #[arg(long)]
    pub uninstall: bool,
}

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
    let version = cap
        .get(1)
        .map(|m| m.as_str())
        .ok_or(CliErrorKind::GatewayVersionMissing)?;
    Ok(format!("v{version}"))
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
    uninstall: bool,
) -> Result<i32, CliError> {
    if check_only && uninstall {
        return Err(CliErrorKind::usage_error(
            "--check-only and --uninstall cannot be used together",
        )
        .into());
    }
    let root = resolve_repo_root(repo_root);
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

    let tmp_dir = env::temp_dir().join(format!("{HARNESS_PREFIX}gateway"));
    ensure_dir(&tmp_dir).map_err(|e| {
        CliErrorKind::io(format!(
            "could not create temp dir {}: {e}",
            tmp_dir.display()
        ))
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

    if uninstall {
        kubectl(kc, &["delete", "-f", &temp_str], &[0, 1])?;
        if let Some(kubeconfig) = kc {
            sync_gateway_api_install_state(&root, kubeconfig, false)?;
        }
        println!("Gateway API {version} CRDs uninstalled");
        return Ok(0);
    }

    kubectl(kc, &["apply", "-f", &temp_str], &[0])?;
    if let Some(kubeconfig) = kc {
        sync_gateway_api_install_state(&root, kubeconfig, true)?;
    }
    println!("Gateway API {version} CRDs installed");
    Ok(0)
}

#[cfg(test)]
mod tests;
