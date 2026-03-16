use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::commands::{resolve_cp_addr, resolve_run_context};
use crate::errors::{CliError, CliErrorKind};
use crate::exec;

use super::kumactl::find_kumactl_binary;

/// Generate a dataplane token from the control plane.
///
/// Tries the REST API first, falls back to kumactl.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn token(
    kind: &str,
    name: &str,
    mesh: &str,
    cp_addr: Option<&str>,
    valid_for: &str,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let addr = if let Some(a) = cp_addr {
        a.to_string()
    } else {
        let ctx = resolve_run_context(run_dir_args)?;
        resolve_cp_addr(&ctx)?
    };

    // Try REST API first
    match token_via_api(&addr, kind, name, mesh, valid_for) {
        Ok(tok) => {
            println!("{tok}");
            return Ok(0);
        }
        Err(api_err) => {
            eprintln!("token: API failed ({api_err}), trying kumactl");
        }
    }

    // Fallback to kumactl
    let ctx = resolve_run_context(run_dir_args)?;
    let root = PathBuf::from(&ctx.metadata.repo_root);
    let binary = find_kumactl_binary(&root)?;

    let mut args = vec!["generate", "dataplane-token"];
    args.extend_from_slice(&["--name", name]);
    args.extend_from_slice(&["--mesh", mesh]);
    args.extend_from_slice(&["--type", kind]);
    args.extend_from_slice(&["--valid-for", valid_for]);

    let result = exec::kumactl_run(&binary, &addr, &args, &[0])?;
    let tok = result.stdout.trim();
    println!("{tok}");
    Ok(0)
}

pub(crate) fn token_via_api(
    addr: &str,
    kind: &str,
    name: &str,
    mesh: &str,
    valid_for: &str,
) -> Result<String, CliError> {
    let body = serde_json::json!({
        "name": name,
        "mesh": mesh,
        "type": kind,
        "validFor": valid_for,
    });
    let resp = exec::cp_api_post(addr, "/tokens/dataplane", &body)?;
    resp.as_str()
        .map(String::from)
        .ok_or_else(|| CliErrorKind::token_generation_failed("unexpected response format").into())
}
