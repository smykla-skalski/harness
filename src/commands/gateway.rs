use std::path::Path;
use std::sync::LazyLock;
use std::{env, fs};

use regex::Regex;

use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec::{kubectl, run_command};
use crate::io::ensure_dir;

const GATEWAY_CLASS_CRD: &str = "gatewayclasses.gateway.networking.k8s.io";

static GATEWAY_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"sigs\.k8s\.io/gateway-api\s+v([^\s]+)").unwrap());

fn detect_version(root: &Path) -> Result<String, CliError> {
    let go_mod = root.join("go.mod");
    let text = fs::read_to_string(&go_mod).map_err(|_| {
        CliError::from(CliErrorKind::MissingFile {
            path: go_mod.display().to_string().into(),
        })
    })?;
    // The capture group excludes the leading `v`, so cap[1] is e.g. "0.8.0".
    let cap = GATEWAY_RE
        .captures(&text)
        .ok_or(CliErrorKind::GatewayVersionMissing)?;
    Ok(format!("v{}", &cap[1]))
}

fn install_url(version: &str) -> String {
    format!(
        "https://github.com/kubernetes-sigs/gateway-api/releases/download/{version}/standard-install.yaml"
    )
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
    // `Path::new` borrows from the caller's `&str` — no heap allocation needed.
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
    ensure_dir(&tmp_dir).map_err(|e| CliErrorKind::Io {
        detail: cow!("could not create temp dir {}: {e}", tmp_dir.display()),
    })?;

    let temp_manifest = tmp_dir.join(format!("gateway-api-{version}.yaml"));
    let temp_str = temp_manifest.to_string_lossy().into_owned();
    let url = install_url(&version);

    run_command(&["curl", "-sL", "-o", &temp_str, &url], None, None, &[0])?;

    // Distinguish "file missing after download" from "download produced an empty file".
    let file_len = fs::metadata(&temp_manifest)
        .map_err(|_| {
            CliError::from(CliErrorKind::MissingFile {
                path: temp_str.clone().into(),
            })
        })?
        .len();
    if file_len == 0 {
        return Err(CliErrorKind::GatewayDownloadEmpty {
            path: temp_str.into(),
        }
        .into());
    }

    kubectl(kc, &["apply", "-f", &temp_str], &[0])?;
    println!("Gateway API {version} CRDs installed");
    Ok(0)
}

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
        assert_eq!(detect_version(dir.path()).unwrap(), "v1.2.1");
    }

    #[test]
    fn detect_version_strips_no_extra_v_prefix() {
        // Ensure we don't produce "vv1.2.1" — the regex captures after the `v`.
        let dir = TempDir::new().unwrap();
        write_go_mod(&dir, "require sigs.k8s.io/gateway-api v0.8.0 // indirect\n");
        let version = detect_version(dir.path()).unwrap();
        assert_eq!(version, "v0.8.0");
        assert!(!version.starts_with("vv"));
    }

    #[test]
    fn detect_version_errors_on_missing_go_mod() {
        let dir = TempDir::new().unwrap();
        let err = detect_version(dir.path()).unwrap_err();
        assert_eq!(err.code(), "KSRCLI014"); // MissingFile
    }

    #[test]
    fn detect_version_errors_when_pattern_absent() {
        let dir = TempDir::new().unwrap();
        write_go_mod(
            &dir,
            "module example.com/foo\n\nrequire (\n\tsome.other/dep v1.0.0\n)\n",
        );
        let err = detect_version(dir.path()).unwrap_err();
        assert_eq!(err.code(), "KSRCLI032"); // GatewayVersionMissing
    }

    #[test]
    fn install_url_contains_version_and_standard_path() {
        let url = install_url("v1.2.1");
        assert_eq!(
            url,
            "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
        );
    }

    #[test]
    fn install_url_embeds_arbitrary_version() {
        let url = install_url("v0.99.0-rc.1");
        assert!(url.contains("v0.99.0-rc.1"));
        assert!(url.ends_with("/standard-install.yaml"));
    }
}
