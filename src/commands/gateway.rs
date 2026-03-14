use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::{env, fs};

use regex::Regex;

use crate::errors::{self, CliError};
use crate::exec::{kubectl, run_command};
use crate::io::ensure_dir;

static GATEWAY_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"sigs\.k8s\.io/gateway-api\s+v([^\s]+)").unwrap());

fn detect_version(root: &Path) -> Result<String, CliError> {
    let go_mod = root.join("go.mod");
    let text = fs::read_to_string(&go_mod).map_err(|_| {
        errors::cli_err(
            &errors::MISSING_FILE,
            &[("path", &go_mod.display().to_string())],
        )
    })?;
    let cap = GATEWAY_RE
        .captures(&text)
        .ok_or_else(|| errors::cli_err(&errors::GATEWAY_VERSION_MISSING, &[]))?;
    let version = cap[1].trim_start_matches('v');
    Ok(format!("v{version}"))
}

/// Check or install Gateway API CRDs.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(
    kubeconfig: Option<&str>,
    repo_root: Option<&str>,
    check_only: bool,
) -> Result<i32, CliError> {
    let root = super::resolve_repo_root(repo_root);
    let version = detect_version(&root)?;
    let kc = kubeconfig.map(PathBuf::from);

    if check_only {
        let result = kubectl(
            kc.as_deref(),
            &["get", "crd", "gatewayclasses.gateway.networking.k8s.io"],
            &[0, 1],
        )?;
        if result.returncode != 0 {
            return Err(errors::cli_err(&errors::GATEWAY_CRDS_MISSING, &[]));
        }
        println!("Gateway API CRDs are installed");
        return Ok(0);
    }

    let url = format!(
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/{version}/standard-install.yaml"
    );
    let tmp_dir = env::temp_dir().join("harness-gateway");
    ensure_dir(&tmp_dir).ok();
    let temp_manifest = tmp_dir.join(format!("gateway-api-{version}.yaml"));
    let temp_str = temp_manifest.to_string_lossy().to_string();

    run_command(&["curl", "-sL", "-o", &temp_str, &url], None, None, &[0])?;

    // Verify the download produced a non-empty file before applying.
    let metadata = fs::metadata(&temp_manifest)
        .map_err(|_| errors::cli_err(&errors::GATEWAY_DOWNLOAD_EMPTY, &[("path", &temp_str)]))?;
    if metadata.len() == 0 {
        return Err(errors::cli_err(
            &errors::GATEWAY_DOWNLOAD_EMPTY,
            &[("path", &temp_str)],
        ));
    }

    kubectl(kc.as_deref(), &["apply", "-f", &temp_str], &[0])?;
    println!("{}", temp_manifest.display());
    Ok(0)
}
